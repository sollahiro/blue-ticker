#!/usr/bin/env python3
"""Overview mock (spike).

有報「企業の概況」の「事業の内容」（XBRL `DescriptionOfBusinessTextBlock`）から
短い会社説明を OpenRouter で生成する。50〜80 字は目安。情報量が少なければ無理に足さない。
公開 REST / ingest / iOS 製品面には載せない。Filing texts キーは増やさない。

Key: `OPENROUTER_MOCK_KEY`（未設定なら `OPENROUTER_API_KEY`）。
Model: `OPENROUTER_MODEL`（既定 `google/gemini-2.5-flash`）。
XBRL 取得: `BLT_EDINET_API_KEY`（`tmp_cache/overview-mock/` に ZIP を置く）。

Examples:
  python3 smoke/overview_mock.py fetch-sources --out /tmp/overview_sources.json
  python3 smoke/overview_mock.py generate --sources /tmp/overview_sources.json
  python3 smoke/overview_mock.py self-check
"""

from __future__ import annotations

import argparse
import html as htmlmod
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any

SMOKE_DIR = Path(__file__).resolve().parent
REPO_DIR = SMOKE_DIR.parent
DEFAULT_OUT = SMOKE_DIR / "overview_mock_expected.json"
CACHE_DIR = REPO_DIR / "tmp_cache" / "overview-mock"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
EDINET_DOCUMENT_URL = "https://api.edinet-fsa.go.jp/api/v2/documents/{doc_id}"
DEFAULT_MODEL = "google/gemini-2.5-flash"
INPUT_KEY = "description_of_business"
SECTION_TITLE = "事業の内容"
XBRL_TAG = "DescriptionOfBusinessTextBlock"
MIN_CHARS = 50
MAX_CHARS = 80
MAX_INPUT_CHARS = 6000
SCHEMA_VERSION = 1
INPUT_THIN_CHARS = 80

COMPANIES: list[dict[str, str]] = [
    {"code": "7203", "name": "トヨタ自動車株式会社", "sector": "輸送用機器", "doc_id": "S100Y8NY"},
    {"code": "8306", "name": "株式会社三菱ＵＦＪフィナンシャル・グループ", "sector": "銀行業", "doc_id": "S100YJQO"},
    {"code": "6758", "name": "ソニーグループ株式会社", "sector": "電気機器", "doc_id": "S100YE2C"},
    {"code": "2802", "name": "味の素株式会社", "sector": "食料品", "doc_id": "S100Y992"},
    {"code": "7751", "name": "キヤノン株式会社", "sector": "電気機器", "doc_id": "S100XTLJ"},
    {"code": "4901", "name": "富士フイルムホールディングス株式会社", "sector": "化学", "doc_id": "S100YIBH"},
    {"code": "6098", "name": "株式会社リクルートホールディングス", "sector": "サービス業", "doc_id": "S100YDHL"},
]

SYSTEM_PROMPT = """あなたは日本の有価証券報告書「企業の概況」の「事業の内容」だけを材料に、銘柄ヘッダ用の短い会社説明を書く。
ルール:
- 入力テキストに書かれている主力事業・主な製品・サービスだけを使う。社名や業種欄から補わない。一般知識で足さない。
- 会計基準の前置き、子会社数、セグメント注記への参照、沿革、関係会社一覧、事業系統図の会社名羅列は使わない。
- 複数事業があるときは主要なものを2〜3個までに絞る。
- 入力が空、または事業内容が全く読めないときは applicable を false にし overview を空文字にする。
- 日本語。1〜2文。長さの目安は50〜80字（句読点・空白を含む。Python の len と同じ文字数）。必要な主力の製品・サービスが揃っていれば、情報量が少ないときに無理に足して長くしない。80字を超えたら失敗。
- 「何をしている会社か」だけ。金額・件数・比率・成長率・目標・年度を書かない。
- 買い推奨・投資判断・銘柄コードを書かない。
- 社名は必要なら一度だけ。株式会社は付けない。
- 文体はだ・である調。です・ます・でした・ましたは使わない。
- 終止は「する」「行う」「手がける」「である」のほか、「を提供。」「を手がける。」のような言い切りでよい。どちらも可。
出力は JSON のみ。"""

JSON_SCHEMA: dict[str, Any] = {
    "name": "company_overview",
    "strict": True,
    "schema": {
        "type": "object",
        "properties": {
            "applicable": {"type": "boolean"},
            "overview": {"type": "string"},
            "char_count": {"type": "integer"},
            "reason": {"type": "string"},
        },
        "required": ["applicable", "overview", "char_count", "reason"],
        "additionalProperties": False,
    },
}

AMOUNT_RE = re.compile(
    r"(?:\d[\d,\.]*)\s*(?:円|億円|兆円|百万円|千万円|%|％|倍|人|件|社)"
    r"|(?:売上|営業利益|純利益|時価総額)\s*\d"
)
BUY_RE = re.compile(r"買い推奨|買い判断|割安|投資せよ|おすすめ銘柄|投資判断")
DESUMASU_RE = re.compile(r"です|ます|でした|ました|ません|でしょう|ください")
YEAR_RE = re.compile(r"(?:19|20)\d{2}\s*年|令和|平成|年度")
GOAL_RE = re.compile(r"中計|目標を|目指し")
COMPANY_SUFFIX_RE = re.compile(r"株式会社")
SENTENCE_END_RE = re.compile(r"[。！？]")
IX_BLOCK_RE = re.compile(
    rf"<ix:nonNumeric\b[^>]*\bname=['\"][^'\"]*{re.escape(XBRL_TAG)}['\"][^>]*>(.*?)</ix:nonNumeric>",
    re.DOTALL | re.IGNORECASE,
)
HEADING_RE = re.compile(r"【事業の内容】")
NEXT_SECTION_RE = re.compile(r"【(?:関係会社の状況|従業員の状況)】")
EXTRACT_FIXTURE = """<div>
<ix:nonNumeric contextRef="FilingDateInstant" name="jpcrp_cor:DescriptionOfBusinessTextBlock" escape="true">
<h3>３ 【事業の内容】</h3>
<p>当社は自動車の設計、製造および販売を行っています。</p>
</ix:nonNumeric>
<h3>４ 【関係会社の状況】</h3>
<p>子会社の一覧。</p>
</div>"""
EXTRACT_FIXTURE_ESCAPED = """<div>
<ix:nonNumeric contextRef="FilingDateInstant" name="jpcrp_cor:DescriptionOfBusinessTextBlock" escape="true">
&lt;h3&gt;３ 【事業の内容】&lt;/h3&gt;&lt;p&gt;当社は自動車の設計、製造および販売を行っています。&lt;/p&gt;
</ix:nonNumeric>
</div>"""


def api_key() -> str:
    key = os.environ.get("OPENROUTER_MOCK_KEY") or os.environ.get("OPENROUTER_API_KEY") or ""
    key = key.strip()
    if not key:
        raise SystemExit("OPENROUTER_MOCK_KEY または OPENROUTER_API_KEY が未設定です")
    return key


def edinet_key() -> str:
    key = (os.environ.get("BLT_EDINET_API_KEY") or "").strip()
    if not key:
        raise SystemExit("BLT_EDINET_API_KEY が未設定です")
    return key


def model_name() -> str:
    return os.environ.get("OPENROUTER_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL


def html_to_text(raw: str) -> str:
    raw = htmlmod.unescape(raw)
    raw = re.sub(r"(?is)<script[^>]*>.*?</script>", " ", raw)
    raw = re.sub(r"(?is)<style[^>]*>.*?</style>", " ", raw)
    raw = re.sub(r"(?i)<br\s*/?>", "\n", raw)
    raw = re.sub(r"(?i)</(p|h[1-6]|tr|div|li|table)>", "\n", raw)
    raw = re.sub(r"(?s)<[^>]+>", " ", raw)
    raw = htmlmod.unescape(raw)
    raw = raw.replace("\xa0", " ").replace("\u3000", " ")
    raw = re.sub(r"[ \t]+", " ", raw)
    raw = re.sub(r"\n[ \t]+", "\n", raw)
    raw = re.sub(r"\n{2,}", "\n", raw)
    return raw.strip()


def extract_description_of_business(html: str) -> str:
    match = IX_BLOCK_RE.search(html)
    if match:
        text = html_to_text(match.group(1))
        if text:
            return text
    heading = HEADING_RE.search(html)
    if not heading:
        return ""
    rest = html[heading.start() :]
    nxt = NEXT_SECTION_RE.search(rest)
    chunk = rest[: nxt.start()] if nxt else rest
    return html_to_text(chunk)


def extract_from_zip(zip_path: Path) -> str:
    with zipfile.ZipFile(zip_path) as zf:
        names = [
            name
            for name in zf.namelist()
            if name.startswith("XBRL/PublicDoc/") and name.lower().endswith((".htm", ".html"))
        ]
        names.sort(key=lambda name: (0 if "0101010" in name else 1, name))
        for name in names:
            text = extract_description_of_business(zf.read(name).decode("utf-8", errors="replace"))
            if text:
                return text
    return ""


def cached_zip_ok(path: Path) -> bool:
    if not path.exists() or path.stat().st_size < 1000:
        return False
    if not zipfile.is_zipfile(path):
        return False
    try:
        with zipfile.ZipFile(path) as zf:
            if zf.testzip() is not None:
                return False
    except zipfile.BadZipFile:
        return False
    return True


def download_edinet_zip(doc_id: str) -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    dest = CACHE_DIR / f"{doc_id}.zip"
    if cached_zip_ok(dest):
        return dest
    if dest.exists():
        dest.unlink()
    query = urllib.parse.urlencode({"type": "1", "Subscription-Key": edinet_key()})
    url = EDINET_DOCUMENT_URL.format(doc_id=doc_id) + "?" + query
    last_error: Exception | None = None
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
            if len(data) < 1000:
                raise RuntimeError(f"{doc_id}: EDINET 応答が小さすぎます ({len(data)} bytes)")
            dest.write_bytes(data)
            if not cached_zip_ok(dest):
                dest.unlink(missing_ok=True)
                raise RuntimeError(f"{doc_id}: ZIP ではない応答")
            return dest
        except Exception as exc:  # noqa: BLE001 — retry network/EDINET flakes
            last_error = exc
            time.sleep(2 ** attempt)
    raise SystemExit(f"EDINET 取得失敗 {doc_id}: {last_error}") from last_error


def fetch_company_source(company: dict[str, str]) -> dict[str, Any]:
    zip_path = download_edinet_zip(company["doc_id"])
    text = extract_from_zip(zip_path)
    return {
        **company,
        "input_key": INPUT_KEY,
        "section_title": SECTION_TITLE,
        "xbrl_tag": XBRL_TAG,
        "text": text,
    }


def complete(messages: list[dict[str, str]]) -> tuple[dict[str, Any], dict[str, Any], str]:
    body = {
        "model": model_name(),
        "messages": messages,
        "temperature": 0,
        "max_tokens": 200,
        "response_format": {"type": "json_schema", "json_schema": JSON_SCHEMA},
    }
    req = urllib.request.Request(
        OPENROUTER_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key()}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/sollahiro/blue-ticker",
            "X-OpenRouter-Title": "BLUE TICKER Overview mock",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"OpenRouter HTTP {exc.code}: {detail[:1200]}") from exc
    content = payload["choices"][0]["message"]["content"]
    parsed = json.loads(content)
    usage = payload.get("usage") or {}
    return parsed, usage, payload.get("model") or model_name()


def user_prompt(company: dict[str, Any], text: str, repair: str | None = None) -> str:
    extra = f"\n前回の出力は長さまたは内容が不適です。直し: {repair}\n" if repair else ""
    return (
        f"銘柄コード {company['code']} / 社名 {company['name']} / 業種 {company['sector']}\n"
        f"入力キー: {company.get('input_key', INPUT_KEY)}\n"
        f"見出し: 企業の概況 / {SECTION_TITLE}\n"
        f"{extra}"
        "----- 有報テキスト -----\n"
        f"{text}\n"
        "----- ここまで -----"
    )


def overview_ok(parsed: dict[str, Any]) -> tuple[bool, str]:
    if not parsed.get("applicable"):
        if parsed.get("overview"):
            return False, "applicable=false なのに overview が空でない"
        return True, ""
    text = str(parsed.get("overview") or "").strip()
    n = len(text)
    if not text:
        return False, "applicable=true なのに overview が空"
    if n > MAX_CHARS:
        return False, f"字数 {n} が目安上限 {MAX_CHARS} を超えている"
    if AMOUNT_RE.search(text):
        return False, "金額・件数・比率らしい数字が入っている"
    if BUY_RE.search(text):
        return False, "買い推奨が混ざっている"
    if DESUMASU_RE.search(text):
        return False, "ですます調になっている"
    if YEAR_RE.search(text):
        return False, "年度が入っている"
    if GOAL_RE.search(text):
        return False, "目標・中計が入っている"
    if COMPANY_SUFFIX_RE.search(text):
        return False, "株式会社が残っている"
    sentences = [part for part in SENTENCE_END_RE.split(text) if part.strip()]
    if not SENTENCE_END_RE.fullmatch(text[-1:]):
        return False, "言い切りの句点がない"
    if len(sentences) > 2:
        return False, f"文が{len(sentences)}つある"
    return True, ""


def clip_overview(text: str) -> str | None:
    text = text.strip()
    if len(text) <= MAX_CHARS:
        return text
    window = text[:MAX_CHARS]
    for sep in ("。", "！", "？"):
        idx = window.rfind(sep)
        if idx >= 0:
            clipped = window[: idx + 1]
            ok, _ = overview_ok({"applicable": True, "overview": clipped})
            if ok:
                return clipped
    return None


def empty_result(company: dict[str, Any], raw: str, reason: str) -> dict[str, Any]:
    return {
        "code": company["code"],
        "name": company["name"],
        "display_name": company["name"].replace("株式会社", "").strip(),
        "sector": company["sector"],
        "doc_id": company.get("doc_id"),
        "input_key": company.get("input_key", INPUT_KEY),
        "input_chars_total": len(raw),
        "input_chars_used": 0,
        "input_thin": True,
        "applicable": False,
        "overview": "",
        "char_count": 0,
        "reason": reason,
        "ok": True,
        "ok_detail": "",
        "clipped": False,
        "attempts": 0,
        "model": model_name(),
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "cost_usd": 0.0,
    }


def generate_one(company: dict[str, Any]) -> dict[str, Any]:
    raw = company.get("text") or ""
    text = raw[:MAX_INPUT_CHARS]
    if not raw.strip():
        return empty_result(company, raw, "入力が空")
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt(company, text)},
    ]
    parsed, usage, resolved_model = complete(messages)
    attempts = 1
    parsed["overview"] = str(parsed.get("overview") or "").strip()
    parsed["char_count"] = len(parsed["overview"])
    ok, why = overview_ok(parsed)
    while not ok and attempts < 3 and parsed.get("applicable"):
        attempts += 1
        n = len(parsed["overview"])
        style = (
            "文体はだ・である調。です・ます・でした・ましたは使わない。"
            "「を提供。」「を手がける。」の言い切りも可。applicable は true のまま。"
        )
        if DESUMASU_RE.search(parsed["overview"]):
            repair = (
                f"{style} 長さは変えず、新しい事実は足さない。情報量が少なければ無理に長くしない。\n"
                f"{parsed['overview']}"
            )
        elif n > MAX_CHARS:
            repair = (
                f"次の日本語は{n}字。句読点込みで{MAX_CHARS}字以下に短縮する。"
                f"{style} 新しい事業を足さず、数字・年度・目標は残さない。情報量が少なければ無理に長くしない。\n"
                f"{parsed['overview']}"
            )
        else:
            repair = (
                f"内容が不適です。直し: {why}。{style} 新しい事実は足さない。"
                "情報量が少なければ無理に長くしない。\n"
                f"{parsed['overview']}"
            )
        previous = parsed
        candidate, extra, resolved_model = complete(
            [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": repair},
            ]
        )
        usage = {
            "prompt_tokens": int(usage.get("prompt_tokens") or 0) + int(extra.get("prompt_tokens") or 0),
            "completion_tokens": int(usage.get("completion_tokens") or 0)
            + int(extra.get("completion_tokens") or 0),
            "cost": float(usage.get("cost") or 0) + float(extra.get("cost") or 0),
        }
        candidate["overview"] = str(candidate.get("overview") or "").strip()
        candidate["char_count"] = len(candidate["overview"])
        if not candidate.get("applicable"):
            parsed = previous
            ok, why = overview_ok(parsed)
            continue
        parsed = candidate
        ok, why = overview_ok(parsed)

    overview = str(parsed.get("overview") or "").strip()
    clipped = False
    if parsed.get("applicable") and not ok:
        n = len(overview)
        clipped_text = None
        if n > MAX_CHARS:
            clipped_text = clip_overview(overview)
        elif why == "言い切りの句点がない":
            clipped_text = overview + "。"
        if clipped_text:
            parsed["overview"] = clipped_text
            parsed["char_count"] = len(clipped_text)
            ok, why = overview_ok(parsed)
            if ok:
                overview = clipped_text
                clipped = True
    return {
        "code": company["code"],
        "name": company["name"],
        "display_name": company["name"].replace("株式会社", "").strip(),
        "sector": company["sector"],
        "doc_id": company.get("doc_id"),
        "input_key": company.get("input_key", INPUT_KEY),
        "input_chars_total": len(raw),
        "input_chars_used": len(text),
        "input_thin": len(raw.strip()) < INPUT_THIN_CHARS,
        "applicable": bool(parsed.get("applicable")),
        "overview": overview,
        "char_count": len(overview),
        "reason": str(parsed.get("reason") or ""),
        "ok": ok,
        "ok_detail": why,
        "clipped": clipped,
        "attempts": attempts,
        "model": resolved_model,
        "prompt_tokens": int(usage.get("prompt_tokens") or 0),
        "completion_tokens": int(usage.get("completion_tokens") or 0),
        "cost_usd": round(float(usage.get("cost") or 0), 7),
    }


def listed_universe_estimate(per_company_usd: float, n: int = 4000) -> dict[str, Any]:
    per = round(per_company_usd, 6)
    return {
        "assumed_listed_count": n,
        "per_company_usd": per,
        "universe_usd": round(per * n, 4),
    }


def findings() -> list[str]:
    return [
        "公開 REST・ingest・iOS 製品面には載せない（空枠のまま。ニュースと同じ）",
        "入力は有報「企業の概況」の「事業の内容」（XBRL DescriptionOfBusinessTextBlock）。Filing texts キーは増やさない",
        "management_policy（経営方針）だと理念・中計になり、事業内容にならない。8306 は方針が前置きだけで空だった",
        "google/gemini-2.5-flash-lite は日本語字数を守りにくい。flash は概ね 50〜80 字。50〜80 は目安で、情報量が少なければ短くてよい",
        "会社説明の文体はだ・である調。ですますは使わない。「を提供。」「を手がける。」の言い切りも可",
        "1 社あたりコストは OpenRouter usage.cost の平均。上場 4000 社は概算",
    ]


def cmd_fetch_sources(args: argparse.Namespace) -> int:
    rows = []
    for company in COMPANIES:
        print(f"fetch {company['code']} {company['doc_id']}", file=sys.stderr)
        row = fetch_company_source(company)
        print(f"  chars={len(row['text'])}", file=sys.stderr)
        if not row["text"]:
            print(f"  WARN empty {SECTION_TITLE}", file=sys.stderr)
        rows.append(row)
    payload = {
        "input_key": INPUT_KEY,
        "section_title": SECTION_TITLE,
        "xbrl_tag": XBRL_TAG,
        "companies": rows,
    }
    out = Path(args.out)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(out)
    return 0 if all(row["text"] for row in rows) else 1


def cmd_generate(args: argparse.Namespace) -> int:
    sources = json.loads(Path(args.sources).read_text(encoding="utf-8"))
    companies = sources["companies"] if isinstance(sources, dict) else sources
    rows = []
    for company in companies:
        print(f"generate {company['code']} {company['name']}", file=sys.stderr)
        rows.append(generate_one(company))
    costs = [row["cost_usd"] for row in rows if row["cost_usd"] > 0]
    mean = sum(costs) / len(costs) if costs else 0.0
    payload = {
        "schema_version": SCHEMA_VERSION,
        "title": "Overview mock",
        "product_path": False,
        "provider": "openrouter",
        "model": model_name(),
        "input_key": INPUT_KEY,
        "section_title": SECTION_TITLE,
        "xbrl_tag": XBRL_TAG,
        "char_range": [MIN_CHARS, MAX_CHARS],
        "max_input_chars": MAX_INPUT_CHARS,
        "cost": listed_universe_estimate(round(mean, 6)),
        "findings": findings(),
        "companies": rows,
    }
    out = Path(args.out)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(out)
    return 0 if all(row["ok"] for row in rows) else 1


def cmd_self_check(_args: argparse.Namespace) -> int:
    errors: list[str] = []
    extracted = extract_description_of_business(EXTRACT_FIXTURE)
    if "自動車の設計、製造および販売" not in extracted:
        errors.append(f"extract fixture: {extracted!r}")
    if "子会社の一覧" in extracted:
        errors.append("extract leaked next section")
    escaped = extract_description_of_business(EXTRACT_FIXTURE_ESCAPED)
    if "自動車の設計、製造および販売" not in escaped:
        errors.append(f"escaped fixture: {escaped!r}")

    style_ok = [
        "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスなどを国内海外で提供。",
        "銀行業務、信託銀行業務、証券業務を中心に、カード・リース・資産運用などの幅広い金融サービスを手がける。",
    ]
    for sample in style_ok:
        ok, why = overview_ok(
            {"applicable": True, "overview": sample, "char_count": len(sample), "reason": ""}
        )
        if not ok:
            errors.append(f"style ok rejected ({len(sample)}字): {sample!r} {why}")
    polite = (
        "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスなどを国内海外で提供しています。"
    )
    ok, why = overview_ok(
        {"applicable": True, "overview": polite, "char_count": len(polite), "reason": ""}
    )
    if ok:
        errors.append("style ng accepted ですます")

    short = "デジタルソフトウェア・アドオンコンテンツの制作・販売、家庭用ゲーム機、音楽制作を手がける。"
    if len(short) != 45:
        errors.append(f"short fixture length {len(short)}")
    ok, why = overview_ok({"applicable": True, "overview": short})
    if not ok:
        errors.append(f"short complete sentence rejected: {why}")
    ok, _ = overview_ok({"applicable": True, "overview": ""})
    if ok:
        errors.append("empty applicable overview accepted")

    empty = generate_one(
        {"code": "0000", "name": "空株式会社", "sector": "その他", "doc_id": "X", "text": "  "}
    )
    if empty["applicable"] or empty["overview"] or empty["attempts"] != 0 or empty["cost_usd"] != 0:
        errors.append("empty input must skip model")

    year = "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスを2026年に提供。"
    ok, _ = overview_ok({"applicable": True, "overview": year})
    if ok:
        errors.append("year accepted")
    corp = "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスを提供する株式会社。"
    ok, _ = overview_ok({"applicable": True, "overview": corp})
    if ok:
        errors.append("company suffix accepted")
    many = "調味料と冷凍食品などを国内外で提供。医薬用アミノ酸を製造販売する。バイオファーマサービスも手がける。"
    ok, _ = overview_ok({"applicable": True, "overview": many})
    if ok:
        errors.append("three sentences accepted")
    unfinished = "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸などを提供。バイオファーマサービスも手がける"
    ok, _ = overview_ok({"applicable": True, "overview": unfinished})
    if ok:
        errors.append("unfinished tail accepted")
    if clip_overview("あ" * 90) is not None:
        errors.append("mid-word clip accepted")
    cost = listed_universe_estimate(0.000561)
    if cost["universe_usd"] != 2.244 or cost["per_company_usd"] != 0.000561:
        errors.append(f"cost rounding {cost}")
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as handle:
        bad_zip = Path(handle.name)
        handle.write(b"not-a-zip" + b"x" * 2000)
    try:
        if cached_zip_ok(bad_zip):
            errors.append("corrupt zip accepted")
    finally:
        bad_zip.unlink(missing_ok=True)

    payload = json.loads(DEFAULT_OUT.read_text(encoding="utf-8"))
    if payload.get("title") != "Overview mock":
        errors.append("title")
    if re.search(r"BLT-\d+", json.dumps(payload, ensure_ascii=False)):
        errors.append("linear id in expected json")
    if payload.get("schema_version") != SCHEMA_VERSION:
        errors.append("schema_version")
    if payload.get("product_path") is not False:
        errors.append("product_path must be false")
    if payload.get("provider") != "openrouter":
        errors.append("provider")
    if payload.get("input_key") != INPUT_KEY:
        errors.append("input_key")
    if payload.get("section_title") != SECTION_TITLE:
        errors.append("section_title")
    if payload.get("xbrl_tag") != XBRL_TAG:
        errors.append("xbrl_tag")
    if not payload.get("findings"):
        errors.append("findings")
    for row in payload["companies"]:
        parsed = {
            "applicable": row["applicable"],
            "overview": row["overview"],
            "char_count": row["char_count"],
            "reason": row.get("reason") or "",
        }
        ok, why = overview_ok(parsed)
        if not ok:
            errors.append(f"{row['code']}: {why}")
        if row["char_count"] != len(row["overview"]):
            errors.append(f"{row['code']}: char_count mismatch")
        if row.get("input_key") != INPUT_KEY:
            errors.append(f"{row['code']}: input_key")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("ok", len(payload["companies"]), "companies")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    fetch = sub.add_parser("fetch-sources")
    fetch.add_argument("--out", default="/tmp/overview_sources.json")
    gen = sub.add_parser("generate")
    gen.add_argument("--sources", required=True)
    gen.add_argument("--out", default=str(DEFAULT_OUT))
    sub.add_parser("self-check")
    args = parser.parse_args()
    if args.cmd == "fetch-sources":
        return cmd_fetch_sources(args)
    if args.cmd == "generate":
        return cmd_generate(args)
    return cmd_self_check(args)


if __name__ == "__main__":
    raise SystemExit(main())
