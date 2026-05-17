"""
EDINET-only スモークテスト用キャッシュ準備。

通常分析キャッシュは作らず、EDINET日次検索/年次インデックスとXBRL展開
キャッシュだけを用意する。
"""

from dataclasses import asdict, dataclass
from typing import Any

from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.utils.edinet_discovery import build_document_index_for_code


@dataclass(frozen=True)
class SmokeCompany:
    code: str
    name: str
    category: str


@dataclass(frozen=True)
class SmokeCacheEntry:
    code: str
    name: str
    category: str
    status: str
    doc_id: str | None = None
    fy_end: str | None = None
    xbrl_dir: str | None = None
    message: str | None = None

    def to_dict(self) -> dict[str, str | None]:
        return asdict(self)


@dataclass(frozen=True)
class SmokeCacheSummary:
    requested: int
    prepared: int
    skipped: int
    failed: int
    entries: list[SmokeCacheEntry]

    def to_dict(self) -> dict[str, int | list[dict[str, str | None]]]:
        return {
            "requested": self.requested,
            "prepared": self.prepared,
            "skipped": self.skipped,
            "failed": self.failed,
            "entries": [entry.to_dict() for entry in self.entries],
        }


DEFAULT_SMOKE_COMPANIES: tuple[SmokeCompany, ...] = (
    SmokeCompany("4901", "富士フイルム", "US-GAAP"),
    SmokeCompany("7751", "キヤノン", "US-GAAP/IFRS boundary"),
    SmokeCompany("8306", "三菱UFJ", "J-GAAP financial"),
    SmokeCompany("8316", "三井住友", "J-GAAP financial"),
    SmokeCompany("6103", "オークマ", "J-GAAP operating"),
    SmokeCompany("6326", "クボタ", "IFRS"),
    SmokeCompany("2802", "味の素", "IFRS"),
    SmokeCompany("7269", "スズキ", "IFRS/J-GAAP boundary"),
    SmokeCompany("7422", "東邦レマック", "J-GAAP nonconsolidated"),
    SmokeCompany("3490", "アズ企画設計", "J-GAAP nonconsolidated/consolidated boundary"),
)


def smoke_companies_from_codes(codes: list[str] | None) -> tuple[SmokeCompany, ...]:
    if not codes:
        return DEFAULT_SMOKE_COMPANIES
    known = {company.code: company for company in DEFAULT_SMOKE_COMPANIES}
    companies: list[SmokeCompany] = []
    for code in codes:
        normalized = code.strip()
        if not normalized:
            continue
        companies.append(known.get(normalized, SmokeCompany(normalized, normalized, "custom")))
    return tuple(companies)


async def prepare_edinet_smoke_cache(
    edinet_client: EdinetAPIClient,
    companies: tuple[SmokeCompany, ...] = DEFAULT_SMOKE_COMPANIES,
    *,
    initial_scan_days: int = 365,
) -> SmokeCacheSummary:
    entries: list[SmokeCacheEntry] = []

    for company in companies:
        try:
            docs, _ = await build_document_index_for_code(
                company.code,
                edinet_client,
                initial_scan_days=initial_scan_days,
                analysis_years=1,
            )
            doc = _latest_annual_doc(docs)
            if doc is None:
                entries.append(
                    SmokeCacheEntry(
                        code=company.code,
                        name=company.name,
                        category=company.category,
                        status="skipped",
                        message="annual report not found",
                    )
                )
                continue

            doc_id = str(doc["docID"])
            xbrl_dir = await edinet_client.download_document(doc_id, 1)
            if xbrl_dir is None:
                entries.append(
                    SmokeCacheEntry(
                        code=company.code,
                        name=company.name,
                        category=company.category,
                        status="failed",
                        doc_id=doc_id,
                        fy_end=_fy_end(doc),
                        message="XBRL download failed",
                    )
                )
                continue

            entries.append(
                SmokeCacheEntry(
                    code=company.code,
                    name=company.name,
                    category=company.category,
                    status="prepared",
                    doc_id=doc_id,
                    fy_end=_fy_end(doc),
                    xbrl_dir=str(xbrl_dir),
                )
            )
        except Exception as exc:
            entries.append(
                SmokeCacheEntry(
                    code=company.code,
                    name=company.name,
                    category=company.category,
                    status="failed",
                    message=str(exc),
                )
            )

    prepared = sum(1 for entry in entries if entry.status == "prepared")
    skipped = sum(1 for entry in entries if entry.status == "skipped")
    failed = sum(1 for entry in entries if entry.status == "failed")
    return SmokeCacheSummary(
        requested=len(companies),
        prepared=prepared,
        skipped=skipped,
        failed=failed,
        entries=entries,
    )


def _latest_annual_doc(docs: list[dict[str, Any]]) -> dict[str, Any] | None:
    annual = [
        doc for doc in docs
        if doc.get("docTypeCode") == "120" and not doc.get("_is_amendment") and doc.get("docID")
    ]
    if not annual:
        return None
    return sorted(annual, key=lambda doc: str(doc.get("submitDateTime") or ""), reverse=True)[0]


def _fy_end(doc: dict[str, Any]) -> str | None:
    value = doc.get("edinet_fy_end") or doc.get("periodEnd")
    return str(value) if value is not None else None
