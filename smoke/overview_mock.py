#!/usr/bin/env python3
"""BLT-58 Overview mock (spike).

有報 `management_policy` から 50〜80 字の会社説明を OpenRouter で生成する。
公開 REST / ingest / iOS 製品面には載せない。Sankey smoke prototype と同じ層。

Key: `OPENROUTER_MOCK_KEY`（未設定なら `OPENROUTER_API_KEY`）。
Model: `OPENROUTER_MODEL`（既定 `google/gemini-2.5-flash-lite`）。

Examples:
  python3 smoke/overview_mock.py generate --sources /tmp/overview_sources.json
  python3 smoke/overview_mock.py self-check
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

SMOKE_DIR = Path(__file__).resolve().parent
DEFAULT_OUT = SMOKE_DIR / "overview_mock_expected.json"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
DEFAULT_MODEL = "google/gemini-2.5-flash"
MIN_CHARS = 50
MAX_CHARS = 80
MAX_INPUT_CHARS = 6000
SCHEMA_VERSION = 1

SYSTEM_PROMPT = """あなたは日本の有価証券報告書だけを材料に、銘柄ヘッダ用の短い会社説明を書く。
ルール:
- 入力テキストに書かれている事業内容・事業領域・商品・サービス・独自技術の語だけを使う。社名や業種欄から補わない。一般知識で「銀行」「食品メーカー」等を足さない。
- 経営方針や理念の文章でも、クルマ・モビリティ・印刷・人材マッチング・アミノサイエンス等の事業領域語があれば applicable=true。
- 入力が将来見通しの前置きだけ、空、事業領域の語が全く無いときは applicable を false にし overview を空文字にする。
- 日本語。1〜2文。全体で50字以上80字以下（句読点・空白を含む。Python の len と同じ文字数。80を1字でも超えたら失敗。49字以下も失敗）。
- 「何をしている会社か」だけ。金額・件数・比率・成長率・目標・年度を書かない。
- 買い推奨・投資判断・銘柄コードを書かない。
- 社名は必要なら一度だけ。株式会社は付けない。
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
BUY_RE = re.compile(r"買い推奨|買い判断|割安|投資せよ|おすすめ銘柄")


def api_key() -> str:
    key = os.environ.get("OPENROUTER_MOCK_KEY") or os.environ.get("OPENROUTER_API_KEY") or ""
    key = key.strip()
    if not key:
        raise SystemExit("OPENROUTER_MOCK_KEY または OPENROUTER_API_KEY が未設定です")
    return key


def model_name() -> str:
    return os.environ.get("OPENROUTER_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL


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
        f"入力キー: {company.get('input_key', 'management_policy')}\n"
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
    if n < MIN_CHARS or n > MAX_CHARS:
        return False, f"字数 {n} が {MIN_CHARS}〜{MAX_CHARS} の外"
    if AMOUNT_RE.search(text):
        return False, "金額・件数・比率らしい数字が入っている"
    if BUY_RE.search(text):
        return False, "買い推奨が混ざっている"
    return True, ""


def clip_overview(text: str) -> str:
    text = text.strip()
    if len(text) <= MAX_CHARS:
        return text
    window = text[:MAX_CHARS]
    for sep in ("。", "！", "？", "、"):
        idx = window.rfind(sep)
        if idx + 1 >= MIN_CHARS:
            return window[: idx + 1]
    return window


def generate_one(company: dict[str, Any]) -> dict[str, Any]:
    raw = company.get("text") or ""
    text = raw[:MAX_INPUT_CHARS]
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
        parsed, extra, resolved_model = complete(
            [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": (
                        f"次の日本語は{n}字です。句読点込みで{MIN_CHARS}字以上{MAX_CHARS}字以下に短縮してください。"
                        "新しい事業を足さず、数字・年度・目標は残さない。applicable は true のまま。\n"
                        f"{parsed['overview']}"
                    ),
                },
            ]
        )
        parsed["overview"] = str(parsed.get("overview") or "").strip()
        parsed["char_count"] = len(parsed["overview"])
        usage = {
            "prompt_tokens": int(usage.get("prompt_tokens") or 0) + int(extra.get("prompt_tokens") or 0),
            "completion_tokens": int(usage.get("completion_tokens") or 0)
            + int(extra.get("completion_tokens") or 0),
            "cost": float(usage.get("cost") or 0) + float(extra.get("cost") or 0),
        }
        ok, why = overview_ok(parsed)

    overview = str(parsed.get("overview") or "").strip()
    clipped = False
    if parsed.get("applicable") and not ok:
        n = len(overview)
        if n > MAX_CHARS:
            clipped_text = clip_overview(overview)
        elif n < MIN_CHARS and n >= MIN_CHARS - 2:
            clipped_text = overview + "。"
        else:
            clipped_text = overview
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
        "input_key": company.get("input_key", "management_policy"),
        "input_chars_total": len(raw),
        "input_chars_used": len(text),
        "input_thin": len(raw.strip()) < 80,
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
        "cost_usd": float(usage.get("cost") or 0),
    }


def listed_universe_estimate(per_company_usd: float, n: int = 4000) -> dict[str, Any]:
    return {
        "assumed_listed_count": n,
        "per_company_usd": round(per_company_usd, 6),
        "universe_usd": round(per_company_usd * n, 4),
    }


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
        "title": "BLT-58 Overview mock",
        "product_path": False,
        "provider": "openrouter",
        "model": model_name(),
        "input_key": "management_policy",
        "char_range": [MIN_CHARS, MAX_CHARS],
        "max_input_chars": MAX_INPUT_CHARS,
        "cost": listed_universe_estimate(round(mean, 6)),
        "findings": [
            "公開 REST・ingest・iOS 製品面には載せない（空枠のまま。ニュースと同じ）",
            "入力は既存 Filing texts の management_policy。新キーも別 EP も出さない",
            "management_policy が将来見通しの前置きだけだと applicable=false（例: 8306）",
            "google/gemini-2.5-flash-lite は日本語字数を守りにくい。flash は概ね 50〜80 字",
            "1 社あたりコストは OpenRouter usage.cost の平均。上場 4000 社は概算",
        ],
        "companies": rows,
    }
    out = Path(args.out)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(out)
    return 0 if all(row["ok"] for row in rows) else 1


def cmd_self_check(_args: argparse.Namespace) -> int:
    payload = json.loads(DEFAULT_OUT.read_text(encoding="utf-8"))
    errors: list[str] = []
    if payload.get("schema_version") != SCHEMA_VERSION:
        errors.append("schema_version")
    if payload.get("product_path") is not False:
        errors.append("product_path must be false")
    if payload.get("provider") != "openrouter":
        errors.append("provider")
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
        if row.get("input_key") != "management_policy":
            errors.append(f"{row['code']}: input_key")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("ok", len(payload["companies"]), "companies")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--sources", required=True)
    gen.add_argument("--out", default=str(DEFAULT_OUT))
    sub.add_parser("self-check")
    args = parser.parse_args()
    if args.cmd == "generate":
        return cmd_generate(args)
    return cmd_self_check(args)


if __name__ == "__main__":
    raise SystemExit(main())
