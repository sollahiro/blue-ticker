#!/usr/bin/env python3
"""Read-only scan: company_breakdowns LLM rows whose yen scale would change
under header-first unit resolution.

SELECT only. No ingest, no R2 PUT. Connection must be passed as argv/env;
this script never writes.

Usage:
  DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" python3 scripts/scan-breakdown-header-unit.py \\
      --out /opt/cursor/artifacts/breakdown-header-unit-scan.json
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
from typing import Any

LLM_SOURCES = (
    "revenue_recognition_llm",
    "segment_info_llm",
    "geography_llm",
)

SOURCE_TO_SECTION = {
    "revenue_recognition_llm": "revenue_recognition",
    "segment_info_llm": "segments",
    "geography_llm": "geography",
}

UNIT_CAPTION_RE = re.compile(r"単位[：:﹕︰]([^）)\\]\\】]{1,40})")
UNIT_TOKENS = (
    "百万ユーロ",
    "百万米ドル",
    "千米ドル",
    "千ユーロ",
    "十億円",
    "百万円",
    "千円",
    "億円",
)


def yen_scale(token: str | None) -> float | None:
    if not token:
        return None
    if "十億円" in token:
        return 1_000_000_000.0
    if "億円" in token:
        return 100_000_000.0
    if "百万円" in token:
        return 1_000_000.0
    if "千円" in token:
        return 1_000.0
    if token == "円":
        return 1.0
    return None


def parse_unit_caption(text: str | None) -> str | None:
    if not text:
        return None
    compact = (
        text.replace("\u00a0", "")
        .replace(" ", "")
        .replace("\u3000", "")
        .replace("\t", "")
        .replace("\n", "")
        .replace("\r", "")
    )
    if not compact:
        return None
    match = UNIT_CAPTION_RE.search(compact)
    if match:
        captured = match.group(1).strip("：: 　")
        if captured:
            return captured
    for token in UNIT_TOKENS:
        if token in compact:
            return token
    lower = compact.lower()
    if "million" in lower and ("yen" in lower or "jpy" in lower):
        return "百万円"
    if ("thousand" in lower or "thousands" in lower) and ("yen" in lower or "jpy" in lower):
        return "千円"
    if "単位" in compact and compact in (
        "（単位：円）",
        "(単位：円)",
        "単位：円",
        "単位:円",
        "(単位:円)",
    ):
        return "円"
    return None


def declared_nominal(unit: str | None) -> float | None:
    if unit == "yen":
        return 1.0
    if unit == "million_yen":
        return 1_000_000.0
    return None


def closer_to_unity(a: float, b: float) -> bool:
    def dist(x: float) -> float:
        import math

        return abs(math.log10(max(x, sys.float_info.min)))

    return dist(a) < dist(b)


def million_yen_multiplier(raw_amounts: list[float], sales: float | None) -> float:
    million = 1_000_000.0
    if not sales:
        return million
    raw_ref = max((abs(x) for x in raw_amounts), default=0.0)
    if raw_ref == 0:
        return million
    as_is = raw_ref / abs(sales)
    as_million = raw_ref * million / abs(sales)
    if closer_to_unity(as_is, as_million):
        return 1.0
    return million


def legacy_multiplier(declared: str | None, raw_amounts: list[float], sales: float | None) -> float:
    if declared == "yen":
        return 1.0
    if declared == "million_yen":
        return million_yen_multiplier(raw_amounts, sales)
    return 1.0


def scale_toward_yen(proposed: float, raw_amounts: list[float], sales: float | None) -> float:
    if proposed == 1.0:
        return 1.0
    if not sales:
        return proposed
    raw_ref = max((abs(x) for x in raw_amounts), default=0.0)
    if raw_ref == 0:
        return proposed
    as_is = raw_ref / abs(sales)
    as_scaled = raw_ref * proposed / abs(sales)
    if closer_to_unity(as_is, as_scaled):
        return 1.0
    return proposed


def new_multiplier(
    header_token: str | None, declared: str | None, raw_amounts: list[float], sales: float | None
) -> tuple[float, bool, bool]:
    """Returns (multiplier, unresolved, mismatch). Matches BreakdownLLMAmountScale.resolve."""
    declared_nom = declared_nominal(declared)
    header_scale = yen_scale(header_token)
    if header_token:
        if header_scale is not None:
            mismatch = declared_nom is not None and declared_nom != header_scale
            applied = scale_toward_yen(header_scale, raw_amounts, sales)
            return applied, False, mismatch
        return 1.0, True, declared_nom is not None
    if declared in ("yen", "million_yen"):
        return legacy_multiplier(declared, raw_amounts, sales), False, False
    return 1.0, True, False


def psql_json(url: str, sql: str) -> list[dict[str, Any]]:
    result = subprocess.run(
        ["psql", url, "-v", "ON_ERROR_STOP=1", "-At", "-c", sql],
        check=True,
        capture_output=True,
        text=True,
    )
    rows: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def header_token_from_table(table: dict[str, Any]) -> str | None:
    for source in (table.get("unitCaption"), table.get("markdown"), table.get("heading")):
        token = parse_unit_caption(source if isinstance(source, str) else None)
        if token:
            return token
    return None


def header_token_from_tables(tables: list[dict[str, Any]], source_table_index: int | None) -> str | None:
    if not tables:
        return None
    if source_table_index is not None and 0 <= source_table_index < len(tables):
        token = header_token_from_table(tables[source_table_index])
        if token:
            return token
    tokens = [t for t in (header_token_from_table(table) for table in tables) if t]
    if len(set(tokens)) == 1:
        return tokens[0]
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out",
        default="breakdown-header-unit-scan.json",
        help="JSON artifact path",
    )
    parser.add_argument(
        "--csv",
        default="breakdown-header-unit-scan.csv",
        help="CSV artifact path",
    )
    parser.add_argument(
        "--dump-llm-rows",
        default="",
        help="Write lightweight LLM row list for the Swift R2 rescan",
    )
    args = parser.parse_args()
    url = os.environ.get("DATABASE_URL") or os.environ.get("BLT_NEON_WRITE_DATABASE_URL")
    if not url or not url.startswith("postgres"):
        print("ERROR: postgres DATABASE_URL or BLT_NEON_WRITE_DATABASE_URL required", file=sys.stderr)
        return 1

    if args.dump_llm_rows:
        dump_sql = r"""
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
FROM (
  SELECT
    b.code,
    b.doc_id,
    b.source,
    COALESCE(b.payload->>'sourceKind', b.payload->>'source_kind') AS source_kind,
    COALESCE(b.llm_audit->>'unit', 'other') AS llm_unit,
    COALESCE(NULLIF(b.llm_audit->>'sourceTableIndex',''), NULLIF(b.llm_audit->>'source_table_index',''))::int AS source_table_index,
    jsonb_array_length(COALESCE(b.payload->'rows', '[]'::jsonb)) AS row_count,
    (b.payload->>'denominator')::double precision AS denominator,
    (
      SELECT max((r->>'amount')::double precision)
      FROM jsonb_array_elements(COALESCE(b.payload->'rows', '[]'::jsonb)) r
    ) AS max_amount
  FROM company_breakdowns b
  WHERE b.source IN ('revenue_recognition_llm', 'segment_info_llm', 'geography_llm')
  ORDER BY b.code, b.doc_id, b.source
) t;
"""
        raw = subprocess.run(
            ["psql", url, "-v", "ON_ERROR_STOP=1", "-At", "-c", dump_sql],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        dumped = json.loads(raw or "[]")
        with open(args.dump_llm_rows, "w", encoding="utf-8") as fh:
            json.dump(dumped, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print(f"dumped {len(dumped)} LLM rows to {args.dump_llm_rows}", file=sys.stderr)
        if not os.environ.get("BLT_SCAN_FILING_SECTIONS"):
            return 0

    sql = r"""
SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
FROM (
  SELECT
    b.code,
    b.doc_id,
    b.source,
    b.axis,
    COALESCE(b.payload->>'sourceKind', b.payload->>'source_kind') AS source_kind,
    COALESCE(b.llm_audit->>'unit', 'other') AS llm_unit,
    COALESCE(NULLIF(b.llm_audit->>'sourceTableIndex',''), NULLIF(b.llm_audit->>'source_table_index',''))::int AS source_table_index,
    jsonb_array_length(COALESCE(b.payload->'rows', '[]'::jsonb)) AS row_count,
    b.payload->'warnings' AS warnings,
    b.needs_review,
    (b.payload->>'denominator')::double precision AS denominator,
    (
      SELECT max((r->>'amount')::double precision)
      FROM jsonb_array_elements(COALESCE(b.payload->'rows', '[]'::jsonb)) r
    ) AS max_amount,
    f.payload AS filing_payload
  FROM company_breakdowns b
  LEFT JOIN company_filing_sections f ON f.doc_id = b.doc_id
  WHERE b.source IN ('revenue_recognition_llm', 'segment_info_llm', 'geography_llm')
  ORDER BY b.code, b.doc_id, b.source
) t;
"""
    raw = subprocess.run(
        ["psql", url, "-v", "ON_ERROR_STOP=1", "-At", "-c", sql],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    rows = json.loads(raw or "[]")

    changed: list[dict[str, Any]] = []
    skipped_no_tables = 0
    for row in rows:
        source = row.get("source") or ""
        section = SOURCE_TO_SECTION.get(source)
        filing = row.get("filing_payload") or {}
        specials = filing.get("specials") or {}
        extracted = specials.get(section) or {}
        tables = extracted.get("tables") or []
        header = header_token_from_tables(tables, row.get("source_table_index"))
        declared = row.get("llm_unit") or "other"
        sales = row.get("denominator")
        max_amount = row.get("max_amount")
        # Stored amounts are already scaled. Reverse raw ≈ stored / old_mult.
        # Use markdown numbers when present; otherwise invert with legacy scale of display-sized guess.
        raw_amounts: list[float] = []
        if tables:
            idx = row.get("source_table_index") or 0
            if not (0 <= idx < len(tables)):
                idx = 0
            markdown = tables[idx].get("markdown") or ""
            for num in re.findall(r"[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+", markdown):
                try:
                    raw_amounts.append(float(num.replace(",", "")))
                except ValueError:
                    pass
        if not raw_amounts and max_amount is not None:
            guess_old = legacy_multiplier(declared, [max_amount], sales)
            # If stored looks like yen and declared million_yen, raw is stored/1e6 or stored.
            if declared == "million_yen" and sales:
                as_million_raw = max_amount / 1_000_000.0
                raw_amounts = [as_million_raw if as_million_raw > 0 else max_amount]
            else:
                raw_amounts = [max_amount / guess_old if guess_old else max_amount]

        old_m = legacy_multiplier(declared, raw_amounts, sales)
        new_m, unresolved, mismatch = new_multiplier(header, declared, raw_amounts, sales)
        ratio = (new_m / old_m) if old_m else None
        would_change = ratio is not None and abs(ratio - 1.0) > 1e-9
        if not tables:
            skipped_no_tables += 1
        if would_change:
            changed.append(
                {
                    "code": row.get("code"),
                    "doc_id": row.get("doc_id"),
                    "source_kind": row.get("source_kind") or source,
                    "source": source,
                    "row_count": row.get("row_count"),
                    "llm_unit": declared,
                    "header_unit": header,
                    "old_multiplier": old_m,
                    "new_multiplier": new_m,
                    "amount_ratio_new_over_old": ratio,
                    "unresolved": unresolved,
                    "header_llm_mismatch": mismatch,
                    "needs_review": row.get("needs_review"),
                    "max_amount": max_amount,
                    "denominator": sales,
                }
            )

    summary = {
        "llm_row_count": len(rows),
        "changed_count": len(changed),
        "skipped_missing_filing_tables": skipped_no_tables,
        "by_source_kind": {},
        "by_ratio": {},
        "codes": sorted({c["code"] for c in changed if c.get("code")}),
    }
    for item in changed:
        kind = item["source_kind"]
        summary["by_source_kind"][kind] = summary["by_source_kind"].get(kind, 0) + 1
        ratio = item["amount_ratio_new_over_old"]
        key = f"{ratio:g}" if ratio is not None else "none"
        summary["by_ratio"][key] = summary["by_ratio"].get(key, 0) + 1

    artifact = {"summary": summary, "changed": changed}
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(artifact, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    with open(args.csv, "w", encoding="utf-8", newline="") as fh:
        fields = [
            "code",
            "doc_id",
            "source_kind",
            "row_count",
            "llm_unit",
            "header_unit",
            "old_multiplier",
            "new_multiplier",
            "amount_ratio_new_over_old",
            "header_llm_mismatch",
        ]
        writer = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(changed)

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"wrote {args.out} ({len(changed)} would-change rows)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
