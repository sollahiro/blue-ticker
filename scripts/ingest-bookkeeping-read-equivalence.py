#!/usr/bin/env python3
"""Read-only prod equivalence: old hydrate selection vs SQL-scoped ingest bookkeeping.

SELECT only. Never INSERT/UPDATE/DELETE. Pass a Postgres URL with --url
or the process env slot blt-server already reads.

Usage:
  python3 scripts/ingest-bookkeeping-read-equivalence.py
  python3 scripts/ingest-bookkeeping-read-equivalence.py --codes 7203,6758

Exit 0 when every stage reports 0 set/count diff. Exit 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from typing import Any

ORDINANCE_010 = "010"
DOC_TYPE_120 = "120"
FRESHNESS_DOC_TYPES = ("120", "130")
FILING_YEARS = 6

VERSION_GATED_NOTE_SOURCES = {"xbrl_facts", "not_applicable"}
VERSION_GATED_BREAKDOWN_SOURCES = {
    "xbrl_facts",
    "stacked_segment_pnl",
    "not_applicable",
    "research_and_development_prose",
    "capex_prose",
    "segment_info_llm",
    "revenue_recognition_llm",
    "geography_llm",
}
BREAKDOWN_VERSION_PREFIXES = (
    "breakdown-product_service-v",
    "breakdown-business-v",
    "breakdown-geography-v",
    "breakdown-employees-v",
    "breakdown-research-and-development-v",
    "breakdown-goodwill-v",
    "breakdown-segment-assets-v",
    "breakdown-goodwill-amortization-v",
    "breakdown-equity-method-investments-v",
    "breakdown-capital-expenditures-v",
    "breakdown-capital-expenditures-overview-v",
    "breakdown-noncurrent-asset-additions-v",
    "breakdown-capex-v",
    "breakdown-interest-bearing-debt-v",
    "breakdown-v",
)


def psql_json(url: str, sql: str) -> list[Any]:
    result = subprocess.run(
        ["psql", url, "-v", "ON_ERROR_STOP=1", "-At", "-c", sql],
        check=True,
        capture_output=True,
        text=True,
    )
    rows: list[Any] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def sql_str_list(values: list[str]) -> str:
    return ", ".join("'" + v.replace("'", "''") + "'" for v in values)


def listed_code(sec_code: str | None) -> str | None:
    if not sec_code or len(sec_code) != 5 or not sec_code.endswith("0"):
        return None
    return sec_code[:4]


def note_version_number(version: str) -> int | None:
    idx = version.rfind("-v")
    if idx < 0:
        return None
    suffix = version[idx + 2 :]
    return int(suffix) if suffix.isdigit() else None


def is_servable_note(source: str, cache_version: str, note_type: str) -> bool:
    if source not in VERSION_GATED_NOTE_SOURCES:
        return True
    n = note_version_number(cache_version)
    return n is not None and n >= 1


def breakdown_version_number(version: str) -> int | None:
    for prefix in BREAKDOWN_VERSION_PREFIXES:
        if version.startswith(prefix):
            suffix = version[len(prefix) :]
            return int(suffix) if suffix.isdigit() else None
    return None


def is_servable_breakdown(source: str, cache_version: str, axis: str) -> bool:
    if source not in VERSION_GATED_BREAKDOWN_SOURCES:
        return True
    n = breakdown_version_number(cache_version)
    return n is not None and n >= 1


def diff_sets(old: set[str], new: set[str]) -> dict[str, Any]:
    only_old = sorted(old - new)
    only_new = sorted(new - old)
    return {
        "old_count": len(old),
        "new_count": len(new),
        "only_old": only_old[:20],
        "only_new": only_new[:20],
        "only_old_count": len(only_old),
        "only_new_count": len(only_new),
        "diff": len(only_old) + len(only_new),
    }


def stage_ok(result: dict[str, Any]) -> bool:
    if "diff" in result:
        return result["diff"] == 0
    if "stages" in result:
        return all(stage_ok(s) for s in result["stages"])
    return result.get("ok", False)


def annual_docs_stage(url: str) -> dict[str, Any]:
    old = psql_json(
        url,
        """
        SELECT json_build_object(
            'doc_id', doc_id,
            'doc_type_code', doc_type_code,
            'ordinance_code', ordinance_code
        )
        FROM edinet_documents
        """,
    )
    old_ids = {
        row["doc_id"]
        for row in old
        if row.get("doc_type_code") == DOC_TYPE_120 and row.get("ordinance_code") == ORDINANCE_010
    }
    new_ids = {
        row["doc_id"]
        for row in psql_json(
            url,
            f"""
            SELECT json_build_object('doc_id', doc_id)
            FROM edinet_documents
            WHERE doc_type_code = '{DOC_TYPE_120}' AND ordinance_code = '{ORDINANCE_010}'
            """,
        )
    }
    d = diff_sets(old_ids, new_ids)
    d.update(
        {
            "stage": "annual_report_disclosure_docs",
            "bytes_estimate": {
                "old_rows": len(old),
                "new_rows": len(new_ids),
                "note": "old hydrates every edinet_documents row then filters; new is WHERE doc_type=120 AND ordinance=010",
            },
        }
    )
    return d


def high_water_stage(url: str) -> dict[str, Any]:
    docs = psql_json(
        url,
        """
        SELECT json_build_object(
            'doc_id', doc_id,
            'sec_code', sec_code,
            'edinet_code', edinet_code,
            'doc_type_code', doc_type_code,
            'ordinance_code', ordinance_code,
            'submit_date_time', submit_date_time,
            'period_end', period_end
        )
        FROM edinet_documents
        """,
    )
    order: list[str] = []
    by_issuer: dict[str, dict[str, Any]] = {}
    for doc in docs:
        key = f"{doc.get('sec_code') or ''}\x1f{doc['edinet_code']}"
        row = by_issuer.get(key) or {
            "sec_code": doc.get("sec_code"),
            "edinet_code": doc["edinet_code"],
            "high_water": None,
            "newest_annual": None,
        }
        if key not in by_issuer:
            order.append(key)
        doc_type = doc.get("doc_type_code")
        if (
            doc_type in FRESHNESS_DOC_TYPES
            and doc.get("ordinance_code") == ORDINANCE_010
            and (doc.get("submit_date_time") or "") > (row["high_water"] or "")
        ):
            row["high_water"] = doc.get("submit_date_time")
        period_end = doc.get("period_end") or ""
        if (
            doc_type == DOC_TYPE_120
            and doc.get("ordinance_code") == ORDINANCE_010
            and period_end
        ):
            candidate = f"{period_end[:10]}|{doc['doc_id']}"
            if candidate > (row["newest_annual"] or ""):
                row["newest_annual"] = candidate
        by_issuer[key] = row
    old = {pack_issuer(by_issuer[k]) for k in order}
    new_rows = psql_json(
        url,
        f"""
        SELECT json_build_object(
            'sec_code', sec_code,
            'edinet_code', edinet_code,
            'high_water', MAX(CASE WHEN doc_type_code IN ({sql_str_list(list(FRESHNESS_DOC_TYPES))})
                AND ordinance_code = '{ORDINANCE_010}' THEN submit_date_time END),
            'newest_annual', MAX(CASE WHEN doc_type_code = '{DOC_TYPE_120}'
                AND ordinance_code = '{ORDINANCE_010}'
                AND period_end IS NOT NULL AND period_end <> ''
                THEN SUBSTR(period_end, 1, 10) || '|' || doc_id END)
        )
        FROM edinet_documents
        GROUP BY sec_code, edinet_code
        """,
    )
    new = {pack_issuer(row) for row in new_rows}
    d = diff_sets(old, new)
    d.update(
        {
            "stage": "issuer_high_water",
            "bytes_estimate": {
                "old_rows": len(docs),
                "new_rows": len(new_rows),
                "note": "old hydrates every listing row; new is GROUP BY issuer (one row per sec_code×edinet_code)",
            },
        }
    )
    return d


def pack_issuer(row: dict[str, Any]) -> str:
    return "|".join(
        [
            row.get("sec_code") or "",
            row.get("edinet_code") or "",
            row.get("high_water") or "",
            row.get("newest_annual") or "",
        ]
    )


def keep_doc_ids(url: str, codes: set[str] | None) -> set[str]:
    docs = psql_json(
        url,
        f"""
        SELECT json_build_object(
            'doc_id', doc_id,
            'sec_code', sec_code,
            'submit_date_time', submit_date_time
        )
        FROM edinet_documents
        WHERE doc_type_code = '{DOC_TYPE_120}' AND ordinance_code = '{ORDINANCE_010}'
        """,
    )
    by_code: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for doc in docs:
        code = listed_code(doc.get("sec_code"))
        if code is None:
            continue
        if codes is not None and code not in codes:
            continue
        by_code[code].append((doc["doc_id"], doc["submit_date_time"]))
    keep: set[str] = set()
    for items in by_code.values():
        items.sort(key=lambda pair: pair[1], reverse=True)
        for doc_id, _ in items[:FILING_YEARS]:
            keep.add(doc_id)
    return keep


def classify_stage(
    url: str,
    *,
    table: str,
    group_col: str,
    group_value: str,
    keep: set[str],
) -> dict[str, Any]:
    old_rows = psql_json(
        url,
        f"""
        SELECT json_build_object('id', id, 'doc_id', doc_id)
        FROM {table}
        WHERE {group_col} = '{group_value.replace("'", "''")}'
        """,
    )
    old_ids = {row["id"] for row in old_rows if row.get("doc_id") in keep}
    if not keep:
        new_ids: set[str] = set()
    else:
        new_ids = {
            row["id"]
            for row in psql_json(
                url,
                f"""
                SELECT json_build_object('id', id)
                FROM {table}
                WHERE {group_col} = '{group_value.replace("'", "''")}'
                  AND doc_id = ANY(ARRAY[{sql_str_list(sorted(keep))}]::text[])
                """,
            )
        }
    d = diff_sets(old_ids, new_ids)
    d.update(
        {
            "stage": f"{table}_classify:{group_value}",
            "keep_docs": len(keep),
            "bytes_estimate": {
                "old_rows": len(old_rows),
                "new_rows": len(new_ids),
                "note": f"old is all {group_col}={group_value} metadata rows; new is those rows with doc_id in keep ({len(keep)} docs)",
            },
        }
    )
    return d


def count_stage(
    url: str,
    *,
    table: str,
    group_col: str,
    is_servable,
) -> dict[str, Any]:
    old_rows = psql_json(
        url,
        f"""
        SELECT json_build_object(
            'source', source,
            'cache_version', cache_version,
            'grp', {group_col}
        )
        FROM {table}
        """,
    )
    old_servable = sum(
        1
        for row in old_rows
        if is_servable(row["source"], row["cache_version"], row["grp"])
    )
    old_unservable = len(old_rows) - old_servable
    groups = psql_json(
        url,
        f"""
        SELECT json_build_object(
            'source', source,
            'cache_version', cache_version,
            'grp', {group_col},
            'n', COUNT(*)::int
        )
        FROM {table}
        GROUP BY source, cache_version, {group_col}
        """,
    )
    new_servable = 0
    new_total = 0
    for row in groups:
        n = int(row["n"])
        new_total += n
        if is_servable(row["source"], row["cache_version"], row["grp"]):
            new_servable += n
    new_unservable = new_total - new_servable
    diff = abs(old_servable - new_servable) + abs(old_unservable - new_unservable)
    return {
        "stage": f"{table}_count_servable",
        "old": {"servable": old_servable, "unservable": old_unservable},
        "new": {"servable": new_servable, "unservable": new_unservable},
        "diff": diff,
        "bytes_estimate": {
            "old_rows": len(old_rows),
            "new_rows": len(groups),
            "note": "old hydrates source+cache_version+group per row; new is COUNT(*) GROUP BY those columns",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.environ.get("DATABASE_URL"))
    parser.add_argument(
        "--codes",
        default="",
        help="Optional 4-digit code subset (comma-separated), same meaning as ingest --codes",
    )
    args = parser.parse_args()
    if not args.url:
        print("ERROR: DATABASE_URL or --url required", file=sys.stderr)
        return 2
    codes = {c.strip() for c in args.codes.split(",") if c.strip()} or None

    note_types = [
        row["note_type"]
        for row in psql_json(
            args.url,
            "SELECT json_build_object('note_type', note_type) FROM (SELECT DISTINCT note_type FROM company_statement_notes) t",
        )
    ]
    axes = [
        row["axis"]
        for row in psql_json(
            args.url,
            "SELECT json_build_object('axis', axis) FROM (SELECT DISTINCT axis FROM company_breakdowns) t",
        )
    ]
    keep = keep_doc_ids(args.url, codes)

    results = [
        annual_docs_stage(args.url),
        high_water_stage(args.url),
        count_stage(
            args.url,
            table="company_statement_notes",
            group_col="note_type",
            is_servable=is_servable_note,
        ),
        count_stage(
            args.url,
            table="company_breakdowns",
            group_col="axis",
            is_servable=is_servable_breakdown,
        ),
    ]
    for note_type in note_types:
        results.append(
            classify_stage(
                args.url,
                table="company_statement_notes",
                group_col="note_type",
                group_value=note_type,
                keep=keep,
            )
        )
    for axis in axes:
        results.append(
            classify_stage(
                args.url,
                table="company_breakdowns",
                group_col="axis",
                group_value=axis,
                keep=keep,
            )
        )

    failed = [r for r in results if r.get("diff", 0) != 0]
    payload = {
        "ok": not failed,
        "keep_docs": len(keep),
        "codes": sorted(codes) if codes else None,
        "stages": results,
    }
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    if failed:
        print(f"FAIL: {len(failed)} stage(s) with non-zero diff", file=sys.stderr)
        return 1
    print("OK: 0 diff across facts/annual/high-water/notes/breakdown bookkeeping reads", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
