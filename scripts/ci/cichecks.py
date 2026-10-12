#!/usr/bin/env python3
"""Required CI checks for blue-ticker as plain, locally runnable scripts.

Subcommands (wrapped by scripts/ci/*.sh):
  golden-files            list golden paths tracked at HEAD
  golden-filter           print the swift test --filter regex for golden suites
  verify-checksums        verify smoke/smoke_expected/.checksums.json
  flags                   new-occurrence flags in base..head (hard fail)
  baseline                regenerate scripts/ci/flags-baseline.tsv from the tree
  golden-rules            golden-change rule check for base..head
  structure               structural-change heuristic (never fails the build)

Base/head come from --base/--head, else $CI_BASE_SHA/$CI_HEAD_SHA, else
merge-base(origin/main, HEAD)..HEAD. Docs: docs/ci-checks.md.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
BASELINE = "scripts/ci/flags-baseline.tsv"
CHECKSUMS = "smoke/smoke_expected/.checksums.json"

# ---------------------------------------------------------------- golden set
GOLDEN_GLOBS = (
    "smoke/smoke_expected/*.json",
    "smoke/smoke_expected/.checksums.json",
    "smoke/breakdown_*_expected.json",
    "smoke/breakdown_expected.json",
    "smoke/statement_notes_*_expected.json",
    "SwiftTests/BlueTickerTests/*GoldenTests.swift",
    "SwiftTests/BlueTickerTests/Spec/Oracle/**",
)
NOT_GOLDEN_PREFIXES = ("workers/feed-rss/test-fixtures/",)


def is_golden(path: str) -> bool:
    if path.startswith(NOT_GOLDEN_PREFIXES):
        return False
    for g in GOLDEN_GLOBS:
        if g.endswith("/**"):
            if path.startswith(g[:-2]):
                return True
        elif fnmatch.fnmatchcase(path, g) and path.count("/") == g.count("/"):
            return True
    return False


def is_golden_data(path: str) -> bool:
    return is_golden(path) and path.endswith(".json") and not path.endswith(".checksums.json")


# ---------------------------------------------------------------- git helpers
def git(*args: str, check: bool = True) -> str:
    r = subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True)
    if check and r.returncode != 0:
        sys.exit(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


def resolve_range(ns) -> tuple[str, str]:
    head = ns.head or os.environ.get("CI_HEAD_SHA") or "HEAD"
    base = ns.base or os.environ.get("CI_BASE_SHA")
    if not base:
        ref = "origin/main" if git("rev-parse", "--verify", "-q", "origin/main", check=False).strip() else "main"
        base = git("merge-base", ref, head).strip()
    else:
        # PR base sha may be ahead of the fork point; diff from the merge base.
        mb = git("merge-base", base, head, check=False).strip()
        base = mb or base
    return base, head


def changed_files(base: str, head: str) -> list[tuple[str, str, str]]:
    """(status, old_path, new_path) with rename detection."""
    out = git("diff", "--name-status", "-M", "-z", base, head)
    parts = out.split("\0")
    res, i = [], 0
    while i < len(parts) and parts[i]:
        st = parts[i]
        if st[0] in "RC":
            res.append((st[0], parts[i + 1], parts[i + 2]))
            i += 3
        else:
            res.append((st[0], parts[i + 1], parts[i + 1]))
            i += 2
    return res


HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def added_lines(base: str, head: str, paths: list[str] | None = None) -> list[tuple[str, int, str]]:
    """(path, new_lineno, text) for every added line, renames detected."""
    args = ["diff", "-M", "-U0", "--no-color", "--no-ext-diff", base, head]
    if paths:
        args += ["--", *paths]
    res, path, ln = [], None, 0
    for line in git(*args).splitlines():
        if line.startswith("+++ "):
            p = line[4:]
            path = None if p == "/dev/null" else p[2:] if p.startswith("b/") else p
        elif line.startswith("@@"):
            m = HUNK.match(line)
            ln = int(m.group(3)) if m else 0
        elif line.startswith("+") and path is not None:
            res.append((path, ln, line[1:]))
            ln += 1
    return res


def diff_counts(base: str, head: str, path_old: str, path_new: str) -> tuple[int, int]:
    out = git("diff", "-M", "--numstat", base, head, "--", path_old, path_new).split("\n")
    a = d = 0
    for row in out:
        f = row.split("\t")
        if len(f) >= 3 and f[0] != "-":
            a += int(f[0]); d += int(f[1])
    return a, d


def show(rev: str, path: str) -> str | None:
    r = subprocess.run(["git", "show", f"{rev}:{path}"], cwd=ROOT, capture_output=True)
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace")


def tracked_files(rev: str) -> list[str]:
    return [p for p in git("ls-tree", "-r", "--name-only", "-z", rev).split("\0") if p]


# ---------------------------------------------------------------- golden suite
def cmd_golden_files(ns) -> int:
    for p in tracked_files("HEAD"):
        if is_golden(p):
            print(p)
    return 0


def golden_suite_names() -> list[str]:
    names = set()
    decl = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+|public\s+|internal\s+)*(?:struct|class)\s+(\w+Tests)\b")
    for p in tracked_files("HEAD"):
        if is_golden(p) and p.endswith(".swift"):
            for line in (ROOT / p).read_text(encoding="utf-8").splitlines():
                m = decl.match(line)
                if m:
                    names.add(m.group(1))
    return sorted(names)


def cmd_golden_filter(ns) -> int:
    names = golden_suite_names()
    if not names:
        sys.exit("no golden test suites found")
    # Same plain-alternation form the existing CI uses (--filter 'SmokeTests|SegmentParityTests').
    print("|".join(names))
    return 0


def verify_checksums(rev: str | None = None) -> list[str]:
    errors = []
    read = (lambda p: show(rev, p)) if rev else (lambda p: (ROOT / p).read_text(encoding="utf-8") if (ROOT / p).exists() else None)
    raw = read(CHECKSUMS)
    if raw is None:
        return [f"{CHECKSUMS} missing"]
    manifest = json.loads(raw)
    files = tracked_files(rev or "HEAD")
    present = {Path(p).name for p in files if p.startswith("smoke/smoke_expected/") and p.endswith(".json") and not p.endswith(".checksums.json")}
    listed = {k for k in manifest if not k.startswith("_")}
    for missing in sorted(present - listed):
        errors.append(f"{missing}: not listed in {CHECKSUMS}")
    for stale in sorted(listed - present):
        errors.append(f"{stale}: listed in {CHECKSUMS} but file is missing")
    for name in sorted(present & listed):
        p = f"smoke/smoke_expected/{name}"
        if rev:
            data = subprocess.run(["git", "show", f"{rev}:{p}"], cwd=ROOT, capture_output=True).stdout
        else:
            data = (ROOT / p).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != manifest[name]:
            errors.append(f"{name}: sha256 {digest} != manifest {manifest[name]}")
    return errors


def cmd_verify_checksums(ns) -> int:
    errors = verify_checksums()
    for e in errors:
        print(f"::error::golden checksum: {e}")
    if errors:
        return 1
    print(f"OK: {CHECKSUMS} matches all golden fixtures")
    return 0


# ---------------------------------------------------------------- flags
CODE_EXT = (".swift", ".py", ".js", ".mjs", ".cjs", ".ts")
# Assembled so this file does not itself contain the strings it forbids.
TRACKER_RE = re.compile(r"\b" + "B" + "LT" + r"-\d+\b|" + "linear" + r"\.app\b", re.I)

NAME_RECV = r"(?:\w*(?:co|company|corp|corporation|filer|issuer|entity)_?name\w*|issuer\w*)"
CODE_RECV = r"(?:\w*(?:sec|edinet|stock|security|securities|ticker)_?code\w*|ticker\w*|code)"
ISSUER_RECV = rf"(?:{NAME_RECV}|{CODE_RECV})"
STR_LIT = r"(?:\"(?:[^\"\\]|\\.)+\"|'(?:[^'\\]|\\.)+')"
CODE_LIT = r"[\"'](?:\d{3}[0-9A-Z]0?|E\d{5})[\"']"
CONTAINS_METHODS = r"(?:contains|localizedCaseInsensitiveContains|localizedStandardContains|hasPrefix|hasSuffix|startsWith|endsWith|includes|startswith|endswith|range\(of:)"
ISSUER_RES = [
    # coName.contains("トヨタ") / filerName.includes('…'): any literal on an issuer-name receiver
    re.compile(rf"(?i)\b{NAME_RECV}\s*[?!]?\s*\.\s*{CONTAINS_METHODS}\s*\(?\s*{STR_LIT}"),
    # secCode.contains("7203") / code.hasPrefix("E01234"): code receivers only with a code-shaped literal
    re.compile(rf"(?i)\b{CODE_RECV}\s*[?!]?\s*\.\s*{CONTAINS_METHODS}\s*\(?\s*{CODE_LIT}"),
    # ["7203", "8604"].contains(code) / {"7203"}.includes(secCode)
    re.compile(rf"(?i)[\[{{]\s*{CODE_LIT}(?:\s*,\s*{CODE_LIT})*\s*,?\s*[\]}}]\s*\.\s*(?:contains|includes|has)\s*\(\s*(?:\$0\.)?{ISSUER_RECV}\b"),
    # Python: "トヨタ" in company_name / "7203" in code
    re.compile(rf"(?i){STR_LIT}\s+in\s+(?:\w+\.)?{NAME_RECV}\b"),
    re.compile(rf"(?i){CODE_LIT}\s+in\s+(?:\w+\.)?{CODE_RECV}\b"),
]
FILTERING = re.compile(r"\.(?:filter|limit|range|first|group|join|sort\([^)]*\)\.limit|paginate)\s*\(")
ALL_CALL = re.compile(r"\.all\(\s*\)")
QUERY_START = re.compile(r"\.query\(\s*on:")


def is_comment(text: str) -> bool:
    s = text.lstrip()
    return s.startswith(("//", "/*", "*", "#"))


def full_table_all(lines: list[str], idx: int) -> bool:
    """lines[idx] contains .all(); walk back the Fluent chain to .query(on:)."""
    line = lines[idx]
    if not ALL_CALL.search(line) or is_comment(line):
        return False
    chain = line[: ALL_CALL.search(line).start()]
    j = idx
    while not QUERY_START.search(chain):
        j -= 1
        if j < 0 or idx - j > 12:
            return False
        prev = lines[j].rstrip()
        if not prev or is_comment(prev):
            continue
        chain = prev + "\n" + chain
        if QUERY_START.search(prev):
            break
        if not (lines[j + 1].lstrip().startswith(".") or prev.endswith((".", "("))):
            return False
    tail = chain[QUERY_START.search(chain).start():]
    return not FILTERING.search(tail)


def issuer_match(text: str) -> bool:
    if is_comment(text):
        return False
    return any(r.search(text) for r in ISSUER_RES)


def norm(text: str) -> str:
    return hashlib.sha256(" ".join(text.split()).encode()).hexdigest()[:16]


def scan_lines(path: str, lines: list[str], idxs) -> list[tuple[str, int, str]]:
    hits = []
    code = path.endswith(CODE_EXT) and path != "scripts/ci/cichecks.py"
    for i in idxs:
        t = lines[i]
        if code and issuer_match(t):
            hits.append(("issuer-contains", i + 1, t))
        if code and path.endswith(".swift") and full_table_all(lines, i):
            hits.append(("full-table-all", i + 1, t))
        if path != BASELINE and TRACKER_RE.search(t):
            hits.append(("tracker-ref", i + 1, t))
    return hits


def load_baseline(text: str | None) -> Counter:
    c = Counter()
    for row in (text or "").splitlines():
        if row and not row.startswith("#"):
            f = row.split("\t")
            c[(f[0], f[2])] += 1
    return c


def is_text(rev: str, path: str) -> str | None:
    content = show(rev, path)
    if content is None or "\0" in content[:8000]:
        return None
    return content


def generate_baseline(rev: str) -> list[str]:
    rows = []
    for p in tracked_files(rev):
        if p == BASELINE:
            continue
        content = is_text(rev, p)
        if content is None:
            continue
        lines = content.splitlines()
        for flag, ln, t in scan_lines(p, lines, range(len(lines))):
            rows.append(f"{flag}\t{p}\t{norm(t)}")
    return sorted(rows)


BASELINE_HEADER = (
    "# Pre-existing occurrences allowed by scripts/ci/flags.sh. Generated once; may only shrink.\n"
    "# flag<TAB>path<TAB>sha256(whitespace-normalised line)[:16]. Text is hashed, never stored.\n"
)


def cmd_baseline(ns) -> int:
    rows = generate_baseline(ns.rev)
    out = BASELINE_HEADER + "".join(r + "\n" for r in rows)
    if ns.stdout:
        sys.stdout.write(out)
    else:
        (ROOT / BASELINE).write_text(out)
        print(f"wrote {BASELINE}: {Counter(r.split(chr(9))[0] for r in rows)}")
    return 0


def cmd_flags(ns) -> int:
    base, head = resolve_range(ns)
    failures = []
    base_bl = show(base, BASELINE)
    head_bl = show(head, BASELINE)
    allowed = load_baseline(head_bl)

    # 1) baseline may only shrink
    if base_bl is None:
        if head_bl is not None:
            expected = BASELINE_HEADER + "".join(r + "\n" for r in generate_baseline(base))
            if head_bl != expected:
                failures.append(f"{BASELINE}: bootstrap baseline must equal the occurrences already on base {base[:10]} (run scripts/ci/flags.sh --baseline --rev {base[:10]})")
    else:
        for path, ln, t in added_lines(base, head, [BASELINE]):
            if path == BASELINE and t.strip() and not t.startswith("#"):
                failures.append(f"{BASELINE}:{ln}: baseline may only shrink; added entry {t.strip()!r}")

    # 2) new occurrences in the diff
    per_file: dict[str, list[int]] = {}
    for path, ln, _ in added_lines(base, head):
        per_file.setdefault(path, []).append(ln - 1)
    for path, idxs in sorted(per_file.items()):
        content = is_text(head, path)
        if content is None:
            continue
        lines = content.splitlines()
        idxs = [i for i in idxs if i < len(lines)]
        for flag, ln, t in scan_lines(path, lines, idxs):
            key = (flag, norm(t))
            if base_bl is not None and allowed[key] > 0:
                allowed[key] -= 1  # moved/re-indented pre-existing line
                continue
            failures.append(f"{path}:{ln}: [{flag}] {t.strip()[:160]}")

    # 3) tracker strings in commit messages base..head
    for sha in git("rev-list", "--no-merges", f"{base}..{head}").split():
        msg = git("log", "-1", "--format=%B", sha)
        for ln, t in enumerate(msg.splitlines(), 1):
            if TRACKER_RE.search(t):
                failures.append(f"commit {sha[:10]} message line {ln}: [tracker-ref] {TRACKER_RE.sub('<redacted>', t.strip())[:160]}")

    for f in failures:
        print(f"::error::flags: {f}")
    if failures:
        print(f"FAIL: {len(failures)} new flagged occurrence(s). See docs/ci-checks.md.")
        return 1
    print(f"OK: no new issuer-contains / full-table-all / tracker-ref occurrences in {base[:10]}..{head[:10]}")
    return 0


# ---------------------------------------------------------------- golden rules
NOTE_KEYS = {
    "code": re.compile(r"(?i)\bcode\s*[=:]\s*\d{3}[0-9A-Z]\b"),
    "fy_end": re.compile(r"(?i)\bfy_?end\s*[=:]\s*\d{4}-\d{2}-\d{2}\b"),
    "doc_id": re.compile(r"(?i)\bdoc_?id\s*[=:]\s*S100[0-9A-Z]{4}\b"),
    "pdf_page": re.compile(r"(?i)\b(?:pdf_?)?page\s*[=:]\s*\d+\b"),
    "field": re.compile(r"(?i)\b(?:field|row)\s*[=:]\s*\S+"),
}
BULK_MAX_LINES = int(os.environ.get("GOLDEN_BULK_MAX_LINES", "400"))
BULK_MAX_FILES = int(os.environ.get("GOLDEN_BULK_MAX_FILES", "8"))


def has_source_note(text: str) -> bool:
    for chunk in re.split(r"\n\s*\n|\n(?=\S*source\s*:)", text):
        if all(r.search(chunk) for r in NOTE_KEYS.values()):
            return True
    return False


def cmd_golden_rules(ns) -> int:
    base, head = resolve_range(ns)
    touched = [(s, o, n) for s, o, n in changed_files(base, head) if is_golden(n) or is_golden(o)]
    if not touched:
        print("OK: no golden files touched")
        return 0
    failures = []
    paths = {n for _, _, n in touched}

    # commit messages per file
    notes_in_commits = set()
    for sha in git("rev-list", "--no-merges", f"{base}..{head}").split():
        if has_source_note(git("log", "-1", "--format=%B", sha)):
            for p in git("diff-tree", "--no-commit-id", "--name-only", "-r", "-M", sha).split("\n"):
                notes_in_commits.add(p)
    added = {}
    for path, ln, t in added_lines(base, head, sorted(paths)):
        added.setdefault(path, []).append(t)

    smoke_changed = False
    total_lines = 0
    data_files = 0
    for s, o, n in touched:
        if n == CHECKSUMS:
            continue
        if n.startswith("smoke/smoke_expected/"):
            smoke_changed = True
        if s == "D":
            continue
        if not (n in notes_in_commits or has_source_note("\n".join(added.get(n, [])))):
            failures.append(f"{n}: no source note (code=, fy_end=, doc_id=S100…, page=, field=) next to the change or in a commit message touching it")
        if is_golden_data(n):
            a, d = diff_counts(base, head, o, n)
            total_lines += a + d
            data_files += 1

    if smoke_changed:
        if CHECKSUMS not in paths:
            failures.append(f"smoke/smoke_expected changed but {CHECKSUMS} was not updated")
        for e in verify_checksums(head):
            failures.append(f"checksum: {e}")

    bulk_ok = os.environ.get("GOLDEN_BULK_APPROVED", "").lower() in ("1", "true", "yes")
    if total_lines > BULK_MAX_LINES or data_files > BULK_MAX_FILES:
        msg = f"bulk golden regeneration suspected: {total_lines} changed lines across {data_files} golden data files (limits {BULK_MAX_LINES} lines / {BULK_MAX_FILES} files)"
        if bulk_ok:
            print(f"::warning::golden-rules: {msg} — allowed by label golden-bulk-approved")
        else:
            failures.append(msg + "; split the change or have @sollahiro apply label golden-bulk-approved")

    for f in failures:
        print(f"::error::golden-rules: {f}")
    if failures:
        return 1
    print(f"OK: {len(touched)} golden file(s) touched, all rules satisfied ({total_lines} data lines changed)")
    return 0


# ---------------------------------------------------------------- structure
ROUTE_RE = re.compile(r"\b\w+\.(?:get|post|put|patch|delete|on|webSocket)\(\s*(?:\.\w+\s*,\s*)?\"[^\"]*\"")
WORKER_ROUTE_RE = re.compile(r"pathname\s*===?\s*[\"'`]/|\.(?:get|post|put|delete)\(\s*[\"'`]/")
SKILL_RE = re.compile(r"^\s*id:\s*\"[a-z0-9-]+\"\s*,")
PKG_RE = re.compile(r"\.(?:target|executableTarget|testTarget|library|executable|plugin|systemLibrary|binaryTarget|package)\(|\bproducts\s*:|\btargets\s*:")
MIGRATION_PATH = re.compile(r"(?i)(?:^|/)migrations?/|\.sql$|(?:^|/)schema[^/]*$")
MIGRATION_CODE = re.compile(r":\s*(?:Async)?Migration\b|\.schema\(\s*\"|CREATE\s+(?:TABLE|INDEX)|ALTER\s+TABLE|DROP\s+(?:TABLE|INDEX)")
MOVE_MIN = int(os.environ.get("STRUCTURE_MOVE_MIN_FILES", "15"))
MODULE_PARENTS = ("Sources/", "SwiftTests/", "workers/", "Apps/BlueTicker/", "scripts/")


def structural_reasons(base: str, head: str) -> list[str]:
    reasons = []
    base_files = tracked_files(base)
    base_top = {p.split("/")[0] for p in base_files}
    base_dirs = {"/".join(p.split("/")[:k]) for p in base_files for k in range(1, p.count("/") + 1)}
    files = changed_files(base, head)
    renames = 0
    for s, o, n in files:
        if s == "A":
            top = n.split("/")[0]
            if "/" in n and top not in base_top:
                reasons.append(f"new top-level directory {top}/")
                base_top.add(top)
            for parent in MODULE_PARENTS:
                if n.startswith(parent) and n.count("/") > parent.count("/"):
                    mod = parent + n[len(parent):].split("/")[0]
                    if mod not in base_dirs:
                        reasons.append(f"new module directory {mod}/")
                        base_dirs.add(mod)
        if s == "R":
            renames += 1
        if s in "AMR" and MIGRATION_PATH.search(n):
            reasons.append(f"schema/migration file {n}")
    if renames >= MOVE_MIN:
        reasons.append(f"large file move: {renames} renames (threshold {MOVE_MIN})")
    for path, ln, t in added_lines(base, head):
        if path == "Package.swift" and PKG_RE.search(t):
            reasons.append(f"Package.swift target/product change at line {ln}")
        elif path.endswith(".swift") and path.startswith("Sources/") and ROUTE_RE.search(t) and "Environment.get" not in t:
            reasons.append(f"new REST route {path}:{ln}")
        elif path.endswith("ApiSkills.swift") and SKILL_RE.search(t):
            reasons.append(f"new REST/MCP skill {path}:{ln}")
        elif path.startswith("workers/") and path.endswith((".js", ".ts")) and "/test" not in path and ".test." not in path and WORKER_ROUTE_RE.search(t):
            reasons.append(f"new worker route {path}:{ln}")
        elif path.endswith(".swift") and path.startswith("Sources/") and MIGRATION_CODE.search(t):
            reasons.append(f"schema/migration code {path}:{ln}")
    seen, uniq = set(), []
    for r in reasons:
        if r not in seen:
            seen.add(r); uniq.append(r)
    return uniq


def cmd_structure(ns) -> int:
    base, head = resolve_range(ns)
    reasons = structural_reasons(base, head)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"structural={'true' if reasons else 'false'}\n")
    if ns.json:
        print(json.dumps({"structural": bool(reasons), "reasons": reasons}, ensure_ascii=False))
        return 0
    if reasons:
        print("STRUCTURAL change detected:")
        for r in reasons:
            print(f"  - {r}")
    else:
        print("not structural")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("flags", "golden-rules", "structure"):
        p = sub.add_parser(name)
        p.add_argument("--base"); p.add_argument("--head")
        if name == "structure":
            p.add_argument("--json", action="store_true")
    for name in ("golden-files", "golden-filter", "verify-checksums"):
        sub.add_parser(name)
    p = sub.add_parser("baseline")
    p.add_argument("--rev", default="HEAD"); p.add_argument("--stdout", action="store_true")
    ns = ap.parse_args()
    return {
        "flags": cmd_flags, "golden-rules": cmd_golden_rules, "structure": cmd_structure,
        "golden-files": cmd_golden_files, "golden-filter": cmd_golden_filter,
        "verify-checksums": cmd_verify_checksums, "baseline": cmd_baseline,
    }[ns.cmd](ns)


if __name__ == "__main__":
    sys.exit(main())
