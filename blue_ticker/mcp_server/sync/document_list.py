import json
import logging
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.infrastructure.settings import settings_store
from blue_ticker.utils.cache_paths import edinet_cache_dir

logger = logging.getLogger(__name__)

_STATUS_FILENAME = "stage1_status.json"


def _status_path() -> Path:
    return Path(edinet_cache_dir(settings_store.cache_dir)) / _STATUS_FILENAME


def get_stage1_status() -> dict[str, Any] | None:
    """Stage 1 の最新ステータスを返す。未実行の場合は None。"""
    path = _status_path()
    if not path.exists():
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return None


def _write_stage1_status(status: dict[str, Any]) -> None:
    """status.json を atomic write で保存する。"""
    path = _status_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".stage1_status.{uuid.uuid4().hex}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(status, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


async def sync_document_list(years: int = 2) -> dict[str, Any]:
    """EDINET年次インデックスを差分更新する（cache catchup 相当）。"""
    api_key = settings_store.edinet_api_key
    if not api_key:
        return {"status": "error", "message": "EDINET APIキーが設定されていません"}

    client = EdinetAPIClient(
        api_key=api_key,
        cache_dir=str(edinet_cache_dir(settings_store.cache_dir)),
    )
    current_year = datetime.now().year
    target_years = [current_year - offset for offset in range(years)]
    entries: list[dict[str, Any]] = []
    try:
        for year in target_years:
            docs = await client.catchup_document_index_for_year(year)
            entries.append({"year": year, "documents": len(docs), "status": "synced"})
            logger.info(f"書類一覧を同期しました: {year}年 {len(docs)}件")
    finally:
        await client.close()

    run_at = datetime.now().isoformat()
    status: dict[str, Any] = {
        "last_run_at": run_at,
        "synced_years": len(entries),
        "total_docs": sum(e["documents"] for e in entries),
        "entries": entries,
    }
    _write_stage1_status(status)

    return {"status": "ok", **status}
