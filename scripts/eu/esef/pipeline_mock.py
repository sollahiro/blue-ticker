#!/usr/bin/env python3
"""EU / ESEF pipeline mock (script-level).

Monorepo naming: Region JP↔EU, Source EDINET↔ESEF
(see `docs/architecture.md` § Region × Source, `.agents/rules/regions.md`).

Mirrors JP/EDINET BlueTicker stages at a coarse grain:

  EDINET discovery/download  →  filings.xbrl.org API + xBRL-JSON
  XBRLUtils.collect*Facts    →  FactIndex from xBRL-JSON
  detectAccountingStandard   →  detect_framework (ESEF / IFRS namespaces)
  FieldSet + resolveItem     →  period-normalized summary resolve
  Statement (presentation)   →  undimensional primary-line dump (no linkbase walk yet)

Stdlib-only exploration. Does not touch Swift targets, DB, REST, or MCP.

API docs: https://filings.xbrl.org/docs/api
ESEF taxonomy overview (ESMA): esma32-60-417 ESEF XBRL taxonomy documentation

Examples:
  python3 scripts/eu/esef/pipeline_mock.py discover --country NL --limit 5
  python3 scripts/eu/esef/pipeline_mock.py summary --country NL --limit 1
  python3 scripts/eu/esef/pipeline_mock.py summary --fxo-id 7245009QH646WM76PR25-2025-12-31-ESEF-NL-0
  python3 scripts/eu/esef/pipeline_mock.py package-tree --fxo-id 7245009QH646WM76PR25-2025-12-31-ESEF-NL-0
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import asdict, dataclass, field
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Iterable, Optional

API_BASE = "https://filings.xbrl.org/api"
FILES_BASE = "https://filings.xbrl.org"
USER_AGENT = "BlueTicker-EU-ESEF-mock/0.1 (+https://github.com/sollahiro/blue-ticker)"
DEFAULT_CACHE = Path("tmp_cache/eu/esef")

# ---------------------------------------------------------------------------
# IFRS-full priority lists (EU/ESEF analogue of Constants/Xbrl.swift tag lists)
# Local names only; namespace prefix is normalized away (ifrs-full:Revenue → Revenue).
# ---------------------------------------------------------------------------

REVENUE_TAGS = [
    "Revenue",
    "RevenueFromContractsWithCustomers",
    "RevenueFromSaleOfGoods",
    "RevenueFromRenderingOfServices",
]

PROFIT_ATTRIBUTABLE_TAGS = [
    "ProfitLossAttributableToOwnersOfParent",
    "ProfitLossFromContinuingOperationsAttributableToOwnersOfParent",
    "ProfitLoss",
]

OPERATING_PROFIT_TAGS = [
    "ProfitLossFromOperatingActivities",
    "OperatingProfitLoss",
]

ASSETS_TAGS = ["Assets"]
EQUITY_TAGS = [
    "Equity",
    "EquityAttributableToOwnersOfParent",
]
LIABILITIES_TAGS = ["Liabilities"]
CURRENT_ASSETS_TAGS = ["CurrentAssets"]
NONCURRENT_ASSETS_TAGS = ["NoncurrentAssets", "NonCurrentAssets"]
CASH_TAGS = [
    "CashAndCashEquivalents",
    "CashAndCashEquivalentsIfDifferentFromStatementOfFinancialPosition",
]
BASIC_EPS_TAGS = ["BasicEarningsLossPerShare", "BasicEarningsPerShare"]
DILUTED_EPS_TAGS = ["DilutedEarningsLossPerShare", "DilutedEarningsPerShare"]

# Coarse statement buckets for the mock "statement" dump (not presentation-link driven).
STATEMENT_BUCKETS: dict[str, list[str]] = {
    "income_statement": [
        "Revenue",
        "CostOfSales",
        "GrossProfit",
        "ProfitLossFromOperatingActivities",
        "FinanceIncome",
        "FinanceCosts",
        "ProfitLossBeforeTax",
        "IncomeTaxExpenseContinuingOperations",
        "ProfitLoss",
        "ProfitLossAttributableToOwnersOfParent",
        "ProfitLossAttributableToNoncontrollingInterests",
        "BasicEarningsLossPerShare",
        "DilutedEarningsLossPerShare",
    ],
    "statement_of_financial_position": [
        "Assets",
        "CurrentAssets",
        "NoncurrentAssets",
        "CashAndCashEquivalents",
        "Goodwill",
        "IntangibleAssetsOtherThanGoodwill",
        "PropertyPlantAndEquipment",
        "Liabilities",
        "CurrentLiabilities",
        "NoncurrentLiabilities",
        "Equity",
        "EquityAttributableToOwnersOfParent",
        "NoncontrollingInterests",
    ],
    "cash_flow": [
        "CashFlowsFromUsedInOperatingActivities",
        "CashFlowsFromUsedInInvestingActivities",
        "CashFlowsFromUsedInFinancingActivities",
        "IncreaseDecreaseInCashAndCashEquivalents",
        "CashAndCashEquivalents",
    ],
}


# ---------------------------------------------------------------------------
# HTTP / cache
# ---------------------------------------------------------------------------


def http_get(url: str, *, timeout: float = 60.0) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def abs_filings_url(path_or_url: Optional[str]) -> Optional[str]:
    if not path_or_url:
        return None
    if path_or_url.startswith("http://") or path_or_url.startswith("https://"):
        return path_or_url
    return FILES_BASE + path_or_url


def cache_path(cache_dir: Path, *parts: str) -> Path:
    p = cache_dir.joinpath(*parts)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def fetch_cached(url: str, dest: Path, *, force: bool = False) -> Path:
    if dest.exists() and not force and dest.stat().st_size > 0:
        return dest
    dest.write_bytes(http_get(url))
    return dest


# ---------------------------------------------------------------------------
# Stage 1 — discover (EdinetDiscovery analogue)
# ---------------------------------------------------------------------------


@dataclass
class FilingRef:
    api_id: str
    fxo_id: str
    country: str
    period_end: str
    entity_name: Optional[str]
    entity_identifier: Optional[str]  # usually LEI
    json_url: Optional[str]
    package_url: Optional[str]
    report_url: Optional[str]
    viewer_url: Optional[str]
    sha256: Optional[str]
    error_count: int = 0

    @property
    def period_end_date(self) -> date:
        return date.fromisoformat(self.period_end)


def api_get_json(path: str, params: dict[str, Any]) -> dict[str, Any]:
    # JSON:API uses page[size] etc.; quote via urlencode with safe brackets.
    query = urllib.parse.urlencode(params, safe="[]")
    url = f"{API_BASE}{path}?{query}"
    return json.loads(http_get(url).decode("utf-8"))


def discover_filings(
    *,
    country: Optional[str] = None,
    fxo_id: Optional[str] = None,
    lei: Optional[str] = None,
    limit: int = 10,
    page_size: int = 50,
) -> list[FilingRef]:
    """List filings from filings.xbrl.org (newest processed first)."""
    params: dict[str, Any] = {
        "page[size]": min(page_size, max(limit, 1)),
        "page[number]": 1,
        "include": "entity",
        "sort": "-processed",
    }
    if country:
        params["filter[country]"] = country.upper()
    if fxo_id:
        params["filter[fxo_id]"] = fxo_id

    payload = api_get_json("/filings", params)
    entities = {
        inc["id"]: inc.get("attributes", {})
        for inc in payload.get("included", [])
        if inc.get("type") == "entity"
    }

    out: list[FilingRef] = []
    for row in payload.get("data", []):
        attrs = row.get("attributes", {})
        ent_rel = (
            row.get("relationships", {})
            .get("entity", {})
            .get("data", {})
        )
        ent = entities.get(ent_rel.get("id"), {}) if ent_rel else {}
        identifier = ent.get("identifier")
        if lei and identifier and identifier.upper() != lei.upper():
            continue
        out.append(
            FilingRef(
                api_id=str(row.get("id")),
                fxo_id=attrs.get("fxo_id") or "",
                country=attrs.get("country") or "",
                period_end=attrs.get("period_end") or "",
                entity_name=ent.get("name"),
                entity_identifier=identifier,
                json_url=abs_filings_url(attrs.get("json_url")),
                package_url=abs_filings_url(attrs.get("package_url")),
                report_url=abs_filings_url(attrs.get("report_url")),
                viewer_url=abs_filings_url(attrs.get("viewer_url")),
                sha256=attrs.get("sha256"),
                error_count=int(attrs.get("error_count") or 0),
            )
        )
        if len(out) >= limit:
            break
    return out


# ---------------------------------------------------------------------------
# Stage 2 — acquire (EdinetAPIClient.downloadDocument analogue)
# ---------------------------------------------------------------------------


def acquire_xbrl_json(filing: FilingRef, cache_dir: Path, *, force: bool = False) -> Path:
    if not filing.json_url:
        raise RuntimeError(f"filing {filing.fxo_id} has no json_url (xBRL-JSON)")
    safe = filing.fxo_id.replace("/", "_")
    dest = cache_path(cache_dir, safe, "facts.json")
    return fetch_cached(filing.json_url, dest, force=force)


def acquire_package(filing: FilingRef, cache_dir: Path, *, force: bool = False) -> Path:
    if not filing.package_url:
        raise RuntimeError(f"filing {filing.fxo_id} has no package_url")
    safe = filing.fxo_id.replace("/", "_")
    dest = cache_path(cache_dir, safe, "package.zip")
    return fetch_cached(filing.package_url, dest, force=force)


# ---------------------------------------------------------------------------
# Stage 3 — collect facts (XBRLUtils.collectAllNumericFacts analogue)
# ---------------------------------------------------------------------------


@dataclass
class Fact:
    concept: str  # prefixed QName, e.g. ifrs-full:Revenue
    local_name: str
    value: Optional[float]
    raw_value: Any
    period: str
    unit: Optional[str]
    entity: Optional[str]
    dimensions: dict[str, str] = field(default_factory=dict)
    decimals: Optional[str] = None

    @property
    def is_undimensional(self) -> bool:
        # Only core dims: concept/entity/period/unit/language
        return not any(
            k
            for k in self.dimensions
            if k
            not in {
                "concept",
                "entity",
                "period",
                "unit",
                "language",
            }
        )


def local_name(qname: str) -> str:
    if ":" in qname:
        return qname.split(":", 1)[1]
    return qname


def parse_numeric(value: Any) -> Optional[float]:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        s = value.strip().replace(",", "")
        if s in {"", "nil", "None"}:
            return None
        try:
            return float(s)
        except ValueError:
            return None
    return None


def collect_facts_from_xbrl_json(doc: dict[str, Any]) -> list[Fact]:
    facts_obj = doc.get("facts") or {}
    out: list[Fact] = []
    for _fid, raw in facts_obj.items():
        dims = dict(raw.get("dimensions") or {})
        concept = dims.get("concept")
        if not concept:
            continue
        out.append(
            Fact(
                concept=concept,
                local_name=local_name(concept),
                value=parse_numeric(raw.get("value")),
                raw_value=raw.get("value"),
                period=dims.get("period") or "",
                unit=dims.get("unit"),
                entity=dims.get("entity"),
                dimensions=dims,
                decimals=str(raw["decimals"]) if "decimals" in raw else None,
            )
        )
    return out


def detect_framework(
    doc: dict[str, Any],
    facts: Iterable[Fact],
    *,
    fxo_id: str = "",
) -> str:
    """Parallel to detectAccountingStandard — namespace / concept prefix based."""
    namespaces = (doc.get("documentInfo") or {}).get("namespaces") or {}
    ns_blob = " ".join(f"{k}={v}" for k, v in namespaces.items()).lower()
    concepts = " ".join(f.concept for f in facts).lower()
    blob = f"{fxo_id} {ns_blob} {concepts}".lower()
    if "esef" in blob or "esma" in blob:
        return "ESEF-IFRS"
    if "ifrs" in blob:
        return "IFRS"
    if "us-gaap" in blob or "usgaap" in blob:
        return "US-GAAP"
    return "UNKNOWN"


# ---------------------------------------------------------------------------
# Stage 4 — context normalize (FieldSet builders analogue; ESEF periods ≠ EDINET ids)
# ---------------------------------------------------------------------------


def _parse_iso_datetime_date(token: str) -> Optional[date]:
    token = token.strip()
    if not token:
        return None
    # xBRL-JSON uses e.g. 2025-01-01T00:00:00
    if "T" in token:
        token = token.split("T", 1)[0]
    try:
        return date.fromisoformat(token)
    except ValueError:
        return None


def period_kind(period: str) -> str:
    if "/" in period:
        return "duration"
    if period:
        return "instant"
    return "none"


def period_end_of(period: str) -> Optional[date]:
    if "/" in period:
        _start, end = period.split("/", 1)
        return _parse_iso_datetime_date(end)
    return _parse_iso_datetime_date(period)


def period_start_of(period: str) -> Optional[date]:
    if "/" in period:
        start, _end = period.split("/", 1)
        return _parse_iso_datetime_date(start)
    return None


@dataclass
class PeriodSlots:
    """Current / prior slots inferred from filing period_end.

    ESEF/xBRL-JSON typically uses exclusive end dates:
      FY ending 2025-12-31 → duration .../2026-01-01, instant 2026-01-01
    EDINET uses symbolic ids (CurrentYearDuration); here we match by calendar.
    """

    period_end: date
    current_instant: set[date] = field(default_factory=set)
    prior_instant: set[date] = field(default_factory=set)
    current_duration_end: set[date] = field(default_factory=set)
    prior_duration_end: set[date] = field(default_factory=set)

    @classmethod
    def from_period_end(cls, period_end: date) -> "PeriodSlots":
        # Exclusive-end candidates (+1 day) and inclusive period_end itself.
        cur_i = {period_end, period_end + timedelta(days=1)}
        try:
            prior_end = period_end.replace(year=period_end.year - 1)
        except ValueError:
            # Feb 29 → Feb 28
            prior_end = period_end.replace(year=period_end.year - 1, day=28)
        prior_i = {prior_end, prior_end + timedelta(days=1)}
        return cls(
            period_end=period_end,
            current_instant=cur_i,
            prior_instant=prior_i,
            current_duration_end=cur_i,
            prior_duration_end=prior_i,
        )


@dataclass
class FieldValue:
    current: Optional[float] = None
    prior: Optional[float] = None
    current_concept: Optional[str] = None
    prior_concept: Optional[str] = None
    unit: Optional[str] = None


def build_fieldset(
    facts: Iterable[Fact],
    slots: PeriodSlots,
    *,
    undimensional_only: bool = True,
) -> dict[str, FieldValue]:
    """Map local concept → current/prior numeric values (JP FieldSet analogue)."""
    fieldset: dict[str, FieldValue] = {}

    def slot_for(fact: Fact) -> Optional[str]:
        end = period_end_of(fact.period)
        if end is None:
            return None
        kind = period_kind(fact.period)
        if kind == "instant":
            if end in slots.current_instant:
                return "current"
            if end in slots.prior_instant:
                return "prior"
        elif kind == "duration":
            if end in slots.current_duration_end:
                return "current"
            if end in slots.prior_duration_end:
                return "prior"
        return None

    for fact in facts:
        if fact.value is None:
            continue
        if undimensional_only and not fact.is_undimensional:
            continue
        which = slot_for(fact)
        if which is None:
            continue
        fv = fieldset.setdefault(fact.local_name, FieldValue(unit=fact.unit))
        if fv.unit is None:
            fv.unit = fact.unit
        if which == "current" and fv.current is None:
            fv.current = fact.value
            fv.current_concept = fact.concept
        elif which == "prior" and fv.prior is None:
            fv.prior = fact.value
            fv.prior_concept = fact.concept
    return fieldset


@dataclass
class ResolvedItem:
    field: str
    tag: Optional[str]
    current: Optional[float]
    prior: Optional[float]
    unit: Optional[str]


def resolve_item(fieldset: dict[str, FieldValue], field: str, tags: list[str]) -> ResolvedItem:
    """First matching tag with any current/prior value (JP resolveItem analogue)."""
    for tag in tags:
        fv = fieldset.get(tag)
        if fv is None:
            continue
        if fv.current is None and fv.prior is None:
            continue
        return ResolvedItem(
            field=field,
            tag=fv.current_concept or fv.prior_concept or tag,
            current=fv.current,
            prior=fv.prior,
            unit=fv.unit,
        )
    return ResolvedItem(field=field, tag=None, current=None, prior=None, unit=None)


def resolve_summary(fieldset: dict[str, FieldValue]) -> list[ResolvedItem]:
    specs = [
        ("revenue", REVENUE_TAGS),
        ("operating_profit", OPERATING_PROFIT_TAGS),
        ("profit_attributable", PROFIT_ATTRIBUTABLE_TAGS),
        ("assets", ASSETS_TAGS),
        ("current_assets", CURRENT_ASSETS_TAGS),
        ("noncurrent_assets", NONCURRENT_ASSETS_TAGS),
        ("liabilities", LIABILITIES_TAGS),
        ("equity", EQUITY_TAGS),
        ("cash", CASH_TAGS),
        ("basic_eps", BASIC_EPS_TAGS),
        ("diluted_eps", DILUTED_EPS_TAGS),
    ]
    return [resolve_item(fieldset, name, tags) for name, tags in specs]


# ---------------------------------------------------------------------------
# Stage 5 — statement-ish dump (presentation walk is future work)
# ---------------------------------------------------------------------------


def statement_lines(
    fieldset: dict[str, FieldValue],
) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {}
    for bucket, tags in STATEMENT_BUCKETS.items():
        lines = []
        for tag in tags:
            fv = fieldset.get(tag)
            if fv is None or (fv.current is None and fv.prior is None):
                continue
            lines.append(
                {
                    "concept": fv.current_concept or fv.prior_concept or tag,
                    "local_name": tag,
                    "current": fv.current,
                    "prior": fv.prior,
                    "unit": fv.unit,
                }
            )
        out[bucket] = lines
    return out


# ---------------------------------------------------------------------------
# Orchestration / CLI
# ---------------------------------------------------------------------------


def jp_vs_esef_notes() -> dict[str, str]:
    return {
        "identity": "JP uses EDINET code / docID; EU index uses LEI + fxo_id.",
        "package": (
            "JP: PublicDoc/*.xbrl instance + many ixbrl.htm sections. "
            "ESEF: Report Package (META-INF + reports/*.xhtml + extension taxonomy linkbases)."
        ),
        "facts_source": (
            "JP Core reads .xbrl via XBRLUtils; this mock prefers filings.xbrl.org xBRL-JSON "
            "(same facts, already normalized)."
        ),
        "contexts": (
            "JP: symbolic CurrentYearDuration / CurrentYearInstant. "
            "ESEF: ISO period strings; instant often exclusive end (= period_end + 1 day)."
        ),
        "taxonomy": (
            "JP: EDINET J-GAAP / IFRS / US-GAAP local names (*IFRS suffix). "
            "ESEF: IFRS-full core + issuer extension concepts; anchoring is out of scope here."
        ),
        "dimensions": (
            "ESEF equity/segment axes are common; summary resolve keeps undimensional facts only "
            "(same spirit as preferring consolidated non-member contexts in JP)."
        ),
        "statement": (
            "JP StatementAnalyzer walks presentation/calculation linkbases. "
            "This mock only dumps a fixed IFRS-full concept checklist — not a real statement extract."
        ),
    }


def run_pipeline(
    filing: FilingRef,
    cache_dir: Path,
    *,
    force: bool = False,
) -> dict[str, Any]:
    json_path = acquire_xbrl_json(filing, cache_dir, force=force)
    doc = json.loads(json_path.read_text(encoding="utf-8"))
    facts = collect_facts_from_xbrl_json(doc)
    framework = detect_framework(doc, facts, fxo_id=filing.fxo_id)
    slots = PeriodSlots.from_period_end(filing.period_end_date)
    fieldset = build_fieldset(facts, slots, undimensional_only=True)
    summary = resolve_summary(fieldset)
    statements = statement_lines(fieldset)

    numeric_undim = sum(1 for f in facts if f.value is not None and f.is_undimensional)
    numeric_dim = sum(1 for f in facts if f.value is not None and not f.is_undimensional)

    return {
        "stage": "summary+statement_mock",
        "filing": asdict(filing),
        "framework": framework,
        "cache": {"xbrl_json": str(json_path)},
        "fact_stats": {
            "total_facts": len(facts),
            "numeric_undimensional": numeric_undim,
            "numeric_dimensional": numeric_dim,
            "fieldset_size": len(fieldset),
        },
        "period_slots": {
            "period_end": slots.period_end.isoformat(),
            "current_instant": sorted(d.isoformat() for d in slots.current_instant),
            "prior_instant": sorted(d.isoformat() for d in slots.prior_instant),
        },
        "summary": [asdict(x) for x in summary],
        "statements": statements,
        "jp_vs_esef": jp_vs_esef_notes(),
        "namespaces": (doc.get("documentInfo") or {}).get("namespaces"),
    }


def package_tree(zip_path: Path, limit: int = 40) -> dict[str, Any]:
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
    exts: dict[str, int] = {}
    for n in names:
        ext = n.rsplit(".", 1)[-1].lower() if "." in n.split("/")[-1] else "(none)"
        exts[ext] = exts.get(ext, 0) + 1
    return {
        "zip": str(zip_path),
        "entry_count": len(names),
        "extensions": dict(sorted(exts.items(), key=lambda kv: (-kv[1], kv[0]))),
        "sample_entries": names[:limit],
        "note": (
            "ESEF report package layout (reports/*.xhtml + extension taxonomy). "
            "JP EDINET packages instead expose PublicDoc/*.xbrl + section ixbrl.htm files."
        ),
    }


def pick_filings(args: argparse.Namespace) -> list[FilingRef]:
    filings = discover_filings(
        country=args.country,
        fxo_id=getattr(args, "fxo_id", None),
        lei=getattr(args, "lei", None),
        limit=args.limit,
    )
    if not filings:
        raise SystemExit("no filings matched filters")
    return filings


def cmd_discover(args: argparse.Namespace) -> int:
    filings = pick_filings(args)
    payload = {
        "count": len(filings),
        "filings": [asdict(f) for f in filings],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    cache_dir = Path(args.cache_dir)
    results = []
    for filing in pick_filings(args):
        if not filing.json_url:
            results.append({"fxo_id": filing.fxo_id, "error": "missing json_url"})
            continue
        results.append(run_pipeline(filing, cache_dir, force=args.force))
    out = results[0] if len(results) == 1 else {"results": results}
    text = json.dumps(out, ensure_ascii=False, indent=2)
    print(text)
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(text + "\n", encoding="utf-8")
    return 0


def cmd_package_tree(args: argparse.Namespace) -> int:
    cache_dir = Path(args.cache_dir)
    filing = pick_filings(args)[0]
    zip_path = acquire_package(filing, cache_dir, force=args.force)
    print(json.dumps(package_tree(zip_path), ensure_ascii=False, indent=2))
    return 0


def cmd_self_check(_args: argparse.Namespace) -> int:
    """Offline period / resolve sanity (no network)."""
    slots = PeriodSlots.from_period_end(date(2025, 12, 31))
    assert date(2026, 1, 1) in slots.current_instant
    assert date(2025, 1, 1) in slots.prior_instant
    facts = [
        Fact(
            concept="ifrs-full:Revenue",
            local_name="Revenue",
            value=10.0,
            raw_value="10",
            period="2025-01-01T00:00:00/2026-01-01T00:00:00",
            unit="iso4217:EUR",
            entity="e",
            dimensions={
                "concept": "ifrs-full:Revenue",
                "entity": "e",
                "period": "2025-01-01T00:00:00/2026-01-01T00:00:00",
                "unit": "iso4217:EUR",
            },
        ),
        Fact(
            concept="ifrs-full:Revenue",
            local_name="Revenue",
            value=9.0,
            raw_value="9",
            period="2024-01-01T00:00:00/2025-01-01T00:00:00",
            unit="iso4217:EUR",
            entity="e",
            dimensions={
                "concept": "ifrs-full:Revenue",
                "entity": "e",
                "period": "2024-01-01T00:00:00/2025-01-01T00:00:00",
                "unit": "iso4217:EUR",
            },
        ),
        Fact(
            concept="ifrs-full:Assets",
            local_name="Assets",
            value=100.0,
            raw_value="100",
            period="2026-01-01T00:00:00",
            unit="iso4217:EUR",
            entity="e",
            dimensions={
                "concept": "ifrs-full:Assets",
                "entity": "e",
                "period": "2026-01-01T00:00:00",
                "unit": "iso4217:EUR",
            },
        ),
        # Dimensional equity member must be ignored for summary fieldset
        Fact(
            concept="ifrs-full:Equity",
            local_name="Equity",
            value=1.0,
            raw_value="1",
            period="2026-01-01T00:00:00",
            unit="iso4217:EUR",
            entity="e",
            dimensions={
                "concept": "ifrs-full:Equity",
                "entity": "e",
                "period": "2026-01-01T00:00:00",
                "unit": "iso4217:EUR",
                "ifrs-full:ComponentsOfEquityAxis": "ifrs-full:IssuedCapitalMember",
            },
        ),
    ]
    fs = build_fieldset(facts, slots)
    assert fs["Revenue"].current == 10.0 and fs["Revenue"].prior == 9.0
    assert fs["Assets"].current == 100.0
    assert "Equity" not in fs  # dimensional only
    r = resolve_item(fs, "revenue", REVENUE_TAGS)
    assert r.tag == "ifrs-full:Revenue" and r.current == 10.0
    print(json.dumps({"ok": True, "checks": ["period_slots", "fieldset", "resolve", "undimensional"]}, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    p.add_argument(
        "--cache-dir",
        default=str(DEFAULT_CACHE),
        help="local cache root (default: tmp_cache/eu/esef)",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_filters(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--country", help="ISO country filter, e.g. NL / FR / GB")
        sp.add_argument("--fxo-id", help="exact filings.xbrl.org fxo_id")
        sp.add_argument("--lei", help="entity LEI / identifier filter")
        sp.add_argument("--limit", type=int, default=1, help="max filings (default 1)")
        sp.add_argument("--force", action="store_true", help="re-download cached files")

    sp = sub.add_parser("discover", help="list filings from filings.xbrl.org")
    add_filters(sp)
    sp.set_defaults(func=cmd_discover, limit=5)

    sp = sub.add_parser("summary", help="download xBRL-JSON and resolve IFRS summary fields")
    add_filters(sp)
    sp.add_argument("--out", help="also write JSON result to this path")
    sp.set_defaults(func=cmd_summary)

    sp = sub.add_parser("package-tree", help="download ESEF ZIP and print package layout")
    add_filters(sp)
    sp.set_defaults(func=cmd_package_tree)

    sp = sub.add_parser("self-check", help="offline period/resolve sanity checks")
    sp.set_defaults(func=cmd_self_check)

    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except urllib.error.HTTPError as e:
        print(f"HTTP error: {e.code} {e.reason}", file=sys.stderr)
        return 2
    except urllib.error.URLError as e:
        print(f"URL error: {e.reason}", file=sys.stderr)
        return 2
    except Exception as e:  # noqa: BLE001 — CLI boundary
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
