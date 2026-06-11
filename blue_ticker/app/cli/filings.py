import json
import sys
import logging
import aiohttp
from blue_ticker.infrastructure.helpers import validate_stock_code
from blue_ticker.constants.api import EDINET_FILINGS_DEFAULT_YEARS

logger = logging.getLogger(__name__)


async def cmd_filings(args):
    """EDINET書類一覧コマンド"""
    from blue_ticker.services.data_service import data_service

    try:
        code = validate_stock_code(args.code)
        years = getattr(args, "years", EDINET_FILINGS_DEFAULT_YEARS)
        if years <= 0:
            print("エラー: years には正の整数を指定してください。", file=sys.stderr)
            return
        docs = await data_service.search_filings(
            code,
            max_years=years,
            doc_types=["120", "130", "140", "150", "160", "170"],
            max_documents=10,
        )
        if not docs:
            print(f"書類が見つかりませんでした: {code}", file=sys.stderr)
            return
        if args.format == "json":
            print(json.dumps(docs, indent=2, ensure_ascii=False))
        else:
            print(f"\n[EDINET書類一覧] {code} ({len(docs)}件)", file=sys.stderr)
            print("-" * 80, file=sys.stderr)
            print(f"{'書類ID':<16} {'種別':<6} {'提出日時':<20} {'書類名'}", file=sys.stderr)
            print("-" * 80, file=sys.stderr)
            for doc in docs:
                print(
                    f"{doc.get('docID',''):<16}"
                    f" {doc.get('docTypeCode',''):<6}"
                    f" {doc.get('submitDateTime',''):<20}"
                    f" {doc.get('docDescription','')}",
                    file=sys.stderr,
                )
            print("-" * 80, file=sys.stderr)
    except ValueError as e:
        print(f"エラー: {e}", file=sys.stderr)
    except aiohttp.ClientError as e:
        print(f"エラー: {e}", file=sys.stderr)
        logger.exception(e)
    finally:
        await data_service.close()


async def cmd_filing(args):
    """EDINET書類抽出コマンド"""
    from blue_ticker.services.data_service import data_service

    try:
        code = validate_stock_code(args.code)
        doc_id = getattr(args, "doc_id", None)
        sections = getattr(args, "sections", None) or []
        result = await data_service.extract_filing_content(
            code,
            doc_id=doc_id or None,
            sections=sections or None,
        )
        print(json.dumps(result, indent=2, ensure_ascii=False))
    except ValueError as e:
        print(f"エラー: {e}", file=sys.stderr)
    except aiohttp.ClientError as e:
        print(f"エラー: {e}", file=sys.stderr)
        logger.exception(e)
    finally:
        await data_service.close()
