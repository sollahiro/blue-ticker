"""
smoke/prepare_cache.py — smoke_expected/*.json が指定する期末日の XBRL を tmp_cache/edinet/ に展開する。

決算期は fixture の fy_end に固定される。このスクリプトを何度実行しても
同じ期末日の書類のみダウンロードされ、fixture の参照先が変わることはない。

実行方法:
    poetry run python smoke/prepare_cache.py                      # 全件
    poetry run python smoke/prepare_cache.py --ticker 2871       # 1社のみ
    poetry run python smoke/prepare_cache.py --ticker 2871 7751  # 複数指定
"""
import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from _common import FIXTURE_DIR, load_fixtures
from blue_ticker.api.edinet_cache_store import EdinetCacheStore
from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.infrastructure.settings import SettingsStore as Settings
from blue_ticker.utils.edinet_discovery import build_document_index_for_code
from blue_ticker.utils.fiscal_year import normalize_date_format

SMOKE_CACHE_DIR = Path("tmp_cache/edinet")
SEARCH_JSON_PATH = SMOKE_CACHE_DIR / "search_smoke.json"


def _load_existing_docs() -> dict[str, dict]:
    """search_smoke.json から既存エントリを {secCode: doc} で返す。"""
    if not SEARCH_JSON_PATH.exists():
        return {}
    data = json.loads(SEARCH_JSON_PATH.read_text(encoding="utf-8"))
    return {d["secCode"]: d for d in data if isinstance(d, dict) and "secCode" in d}


async def main(api_key: str, tickers: list[str] | None) -> None:
    cache_store = EdinetCacheStore(cache_dir=SMOKE_CACHE_DIR)
    client = EdinetAPIClient(api_key=api_key, cache_store=cache_store)

    fixtures = load_fixtures()
    if not fixtures:
        print("smoke_expected/ にフィクスチャが見つかりません", file=sys.stderr)
        sys.exit(1)

    # ticker フィルタ指定時は既存エントリを保持し、対象のみ上書きする
    docs_by_sec: dict[str, dict] = _load_existing_docs() if tickers else {}

    for fixture_id, fixture in fixtures:
        code: str = fixture["code"]
        fy_end: str = fixture["fy_end"]
        name: str = fixture.get("name", code)

        if tickers and code not in tickers:
            continue

        print(f"\n[{code}] {name}  fy_end={fy_end}")
        try:
            docs, _ = await build_document_index_for_code(
                code,
                client,
                initial_scan_days=400,
                analysis_years=3,
            )
            annual = [d for d in docs if d.get("docTypeCode") == "120" and not d.get("_is_amendment")]

            target = next(
                (d for d in annual if (normalize_date_format(str(d.get("periodEnd") or "")) or "") == fy_end),
                None,
            )
            if target is None:
                print(f"  → {fy_end} の有価証券報告書が見つかりません")
                continue

            doc_id = str(target["docID"])
            print(f"  → docID={doc_id}")

            xbrl_path = await client.download_document(doc_id, doc_type=1, save_dir=SMOKE_CACHE_DIR)
            if xbrl_path:
                print(f"  → XBRL展開: {xbrl_path}")
            else:
                print("  → XBRLダウンロード失敗")

            docs_by_sec[target["secCode"]] = target
        except Exception as exc:
            print(f"  → エラー: {exc}")

    all_docs = list(docs_by_sec.values())
    SEARCH_JSON_PATH.write_text(
        json.dumps(all_docs, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n検索キャッシュ保存: {SEARCH_JSON_PATH} ({len(all_docs)}件)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="prepare annual smoke cache")
    parser.add_argument("--ticker", nargs="+", metavar="XXXX", help="取得する銘柄コード（省略時は全件）")
    args = parser.parse_args()

    settings = Settings()
    api_key = settings.edinet_api_key
    if not api_key:
        print("EDINET APIキーが設定されていません。", file=sys.stderr)
        sys.exit(1)
    asyncio.run(main(api_key, args.ticker))
