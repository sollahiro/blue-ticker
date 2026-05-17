"""
smoke test 用 XBRL キャッシュ準備スクリプト。

tmp_cache/edinet/ に各社の最新有価証券報告書 XBRL を展開し、
search_smoke.json を更新する。APIキーはキーチェーンから取得する。
"""
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from blue_ticker.api.edinet_cache_store import EdinetCacheStore
from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.infrastructure.settings import SettingsStore as Settings
from blue_ticker.services.edinet_smoke_cache import DEFAULT_SMOKE_COMPANIES
from blue_ticker.utils.edinet_discovery import build_document_index_for_code

SMOKE_CACHE_DIR = Path("tmp_cache/edinet")
SEARCH_JSON_PATH = SMOKE_CACHE_DIR / "search_smoke.json"


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
                print(f"  → 有価証券報告書が見つかりません")
                continue

            latest = sorted(annual, key=lambda d: str(d.get("submitDateTime") or ""), reverse=True)[0]
            doc_id = str(latest["docID"])
            fy_end = str(latest.get("periodEnd") or "")
            print(f"  → 最新: docID={doc_id}  期末={fy_end}")

            xbrl_path = await client.download_document(doc_id, doc_type=1, save_dir=SMOKE_CACHE_DIR)
            if xbrl_path:
                print(f"  → XBRL展開: {xbrl_path}")
            else:
                print(f"  → XBRLダウンロード失敗")

            all_docs.append(latest)
        except Exception as exc:
            print(f"  → エラー: {exc}")

    # smoke test が glob("search_*.json") で読み込む形式で保存
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
