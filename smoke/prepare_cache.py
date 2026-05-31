"""
smoke/prepare_cache.py — smoke企業の最新XBRLを tmp_cache/edinet/ に展開する。

実行方法:
    poetry run python smoke/prepare_cache.py
"""
import asyncio
import json
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from blue_ticker.api.edinet_cache_store import EdinetCacheStore
from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.infrastructure.settings import SettingsStore as Settings
from blue_ticker.utils.edinet_discovery import build_document_index_for_code

SMOKE_CACHE_DIR = Path("tmp_cache/edinet")
SEARCH_JSON_PATH = SMOKE_CACHE_DIR / "search_smoke.json"


@dataclass(frozen=True)
class SmokeCompany:
    code: str
    name: str
    category: str


DEFAULT_SMOKE_COMPANIES: tuple[SmokeCompany, ...] = (
    SmokeCompany("4901", "富士フイルム",   "US-GAAP"),
    SmokeCompany("7751", "キヤノン",       "US-GAAP/IFRS boundary"),
    SmokeCompany("8306", "三菱UFJ",        "J-GAAP financial"),
    SmokeCompany("8316", "三井住友",       "J-GAAP financial"),
    SmokeCompany("6103", "オークマ",       "J-GAAP operating"),
    SmokeCompany("6326", "クボタ",         "IFRS"),
    SmokeCompany("2802", "味の素",         "IFRS"),
    SmokeCompany("7269", "スズキ",         "IFRS/J-GAAP boundary"),
    SmokeCompany("7422", "東邦レマック",   "J-GAAP nonconsolidated"),
    SmokeCompany("3490", "アズ企画設計",   "J-GAAP nonconsolidated/consolidated boundary"),
)


async def main(api_key: str) -> None:
    cache_store = EdinetCacheStore(cache_dir=SMOKE_CACHE_DIR)
    client = EdinetAPIClient(api_key=api_key, cache_store=cache_store)

    all_docs: list[dict] = []
    for company in DEFAULT_SMOKE_COMPANIES:
        print(f"\n[{company.code}] {company.name} ({company.category})")
        try:
            docs, _ = await build_document_index_for_code(
                company.code,
                client,
                initial_scan_days=400,
                analysis_years=2,
            )
            annual = [d for d in docs if d.get("docTypeCode") == "120" and not d.get("_is_amendment")]
            if not annual:
                print("  → 有価証券報告書が見つかりません")
                continue

            latest = sorted(annual, key=lambda d: str(d.get("submitDateTime") or ""), reverse=True)[0]
            doc_id = str(latest["docID"])
            fy_end = str(latest.get("periodEnd") or "")
            print(f"  → 最新: docID={doc_id}  期末={fy_end}")

            xbrl_path = await client.download_document(doc_id, doc_type=1, save_dir=SMOKE_CACHE_DIR)
            if xbrl_path:
                print(f"  → XBRL展開: {xbrl_path}")
            else:
                print("  → XBRLダウンロード失敗")

            all_docs.append(latest)
        except Exception as exc:
            print(f"  → エラー: {exc}")

    SEARCH_JSON_PATH.write_text(
        json.dumps(all_docs, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n検索キャッシュ保存: {SEARCH_JSON_PATH} ({len(all_docs)}件)")


if __name__ == "__main__":
    settings = Settings()
    api_key = settings.edinet_api_key
    if not api_key:
        print("EDINET APIキーが設定されていません。", file=sys.stderr)
        sys.exit(1)
    asyncio.run(main(api_key))
