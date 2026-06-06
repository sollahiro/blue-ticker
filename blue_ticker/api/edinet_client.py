import asyncio
import logging
import os
import re
import ssl
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

import aiohttp

from ..constants.api import (
    EDINET_API_BASE_URL,
    EDINET_DOCUMENT_INDEX_BATCH_SIZE,
    EDINET_DOCUMENT_INDEX_MIN_RANGE_DAYS,
    SSL_CA_BUNDLE_CANDIDATES,
    SSL_CERT_FILE_ENV,
)
from .edinet_cache_backend import EdinetCacheBackend
from blue_ticker.utils.fiscal_year import normalize_date_format, parse_date_string
from .edinet_cache_store import EdinetCacheStore

logger = logging.getLogger(__name__)

class EdinetAPIClient:
    """EDINET API v2 クライアント"""

    def __init__(
        self,
        api_key: str | None = None,
        cache_dir: str | None = None,
        cache_store: EdinetCacheBackend | None = None,
    ):
        self.api_key = api_key
        self.base_url = EDINET_API_BASE_URL
        self.cache_store = cache_store or EdinetCacheStore(cache_dir or Path("tmp_cache") / "edinet")
        self.cache_dir = self.cache_store.cache_dir

        self._session: aiohttp.ClientSession | None = None
        self._session_loop: asyncio.AbstractEventLoop | None = None
        self._download_locks: dict[str, asyncio.Lock] = {}
        self._date_fetch_semaphore = asyncio.Semaphore(10)
        self._xbrl_download_semaphore = asyncio.Semaphore(4)
        self._document_index_locks: dict[int, asyncio.Lock] = {}

    def update_api_key(self, api_key: str | None) -> None:
        """APIキーを更新します。"""
        self.api_key = api_key.strip() if api_key else ""
        self._session = None
        self._session_loop = None

    def set_cache_store(self, cache_store: EdinetCacheBackend) -> None:
        """EDINET API由来キャッシュの backend を差し替える。"""
        self.cache_store = cache_store
        self.cache_dir = self.cache_store.cache_dir

    def set_cache_dir(self, cache_dir: str | Path) -> None:
        """EDINET API由来キャッシュの保存先を差し替える。"""
        self.set_cache_store(EdinetCacheStore(cache_dir))

    async def _get_session(self) -> aiohttp.ClientSession:
        """セッションを遅延作成して返す"""
        current_loop = asyncio.get_running_loop()
        if self._session is not None and not self._session.closed and self._session_loop is not current_loop:
            await self._session.close()
            self._session = None
        if self._session is None or self._session.closed:
            ssl_context = _create_ssl_context()
            connector = aiohttp.TCPConnector(ssl=ssl_context)
            self._session = aiohttp.ClientSession(connector=connector)
            self._session_loop = current_loop
        return self._session

    async def close(self) -> None:
        """セッションを明示的にクローズする"""
        if self._session is not None and not self._session.closed:
            await self._session.close()
        self._session = None
        self._session_loop = None

    async def _request(
        self,
        endpoint: str,
        params: dict[str, Any] | None = None,
        max_retries: int = 3,
    ) -> dict[str, Any]:
        """リトライ機能付きAPIリクエスト実行（JSON応答）"""
        if not self.api_key:
            raise ValueError("EDINET_API_KEY is not set")

        url = f"{self.base_url}{endpoint}"
        params = dict(params or {})
        params["Subscription-Key"] = self.api_key

        last_exception: BaseException | None = None
        retry_wait_seconds: float | None = None
        session = await self._get_session()
        timeout = aiohttp.ClientTimeout(total=30)

        for attempt in range(max_retries):
            try:
                if attempt > 0:
                    wait_time = retry_wait_seconds if retry_wait_seconds is not None else 2 ** attempt
                    retry_wait_seconds = None
                    logger.warning(f"⚠️ [EDINET API] Retry attempt {attempt+1}/{max_retries} after {wait_time}s...")
                    await asyncio.sleep(wait_time)

                async with session.get(url, params=params, timeout=timeout) as response:
                    # JSONボディのビジネスエラーをステータスコードより先にチェック
                    try:
                        data = await response.json(content_type=None)
                        status_code_in_body = data.get("statusCode")
                        if status_code_in_body and status_code_in_body != 200:
                            message = data.get("message", "Unknown error")
                            logger.error(f"❌ [EDINET API] Business logic error: {status_code_in_body} - {message}")
                            if status_code_in_body == 401:
                                raise ValueError(f"EDINET APIキーが無効です: {message}")
                            raise aiohttp.ClientResponseError(
                                response.request_info,
                                response.history,
                                status=status_code_in_body,
                                message=f"EDINET API error: {status_code_in_body} - {message}",
                            )
                        response.raise_for_status()
                        return data
                    except ValueError as e:
                        if "EDINET APIキーが無効です" in str(e):
                            raise
                        # JSON以外のレスポンス
                        response.raise_for_status()
                        return {}

            except (aiohttp.ClientResponseError, aiohttp.ClientError, ValueError) as e:
                last_exception = e
                if isinstance(e, ValueError) and "EDINET APIキーが無効です" in str(e):
                    raise

                status_code = getattr(e, "status", None)
                if status_code in [429, 500, 502, 503, 504] or isinstance(e, aiohttp.ClientConnectorError):
                    if status_code == 429:
                        retry_wait_seconds = _retry_after_seconds(e)
                    continue
                else:
                    logger.error(f"❌ [EDINET API] Non-retryable error: {e}")
                    raise

        logger.error(f"❌ [EDINET API] All {max_retries} attempts failed. Last error: {last_exception}")
        if last_exception is not None:
            raise last_exception
        raise aiohttp.ClientError("EDINET APIリトライ回数上限に達しました。")

    async def _request_binary(
        self,
        endpoint: str,
        params: dict[str, Any] | None = None,
        max_retries: int = 3,
    ) -> bytes:
        """リトライ機能付きAPIリクエスト実行（バイナリ応答）"""
        if not self.api_key:
            raise ValueError("EDINET_API_KEY is not set")

        url = f"{self.base_url}{endpoint}"
        params = dict(params or {})
        params["Subscription-Key"] = self.api_key

        last_exception: BaseException | None = None
        retry_wait_seconds: float | None = None
        session = await self._get_session()
        timeout = aiohttp.ClientTimeout(total=120)

        for attempt in range(max_retries):
            try:
                if attempt > 0:
                    wait_time = retry_wait_seconds if retry_wait_seconds is not None else 2 ** attempt
                    retry_wait_seconds = None
                    logger.warning(f"⚠️ [EDINET API] Retry attempt {attempt+1}/{max_retries} after {wait_time}s...")
                    await asyncio.sleep(wait_time)

                async with session.get(url, params=params, timeout=timeout) as response:
                    response.raise_for_status()
                    return await response.read()

            except (aiohttp.ClientResponseError, aiohttp.ClientError) as e:
                last_exception = e
                status_code = getattr(e, "status", None)
                if status_code in [429, 500, 502, 503, 504] or isinstance(e, aiohttp.ClientConnectorError):
                    if status_code == 429:
                        retry_wait_seconds = _retry_after_seconds(e)
                    continue
                raise

        if last_exception is not None:
            raise last_exception
        raise aiohttp.ClientError("EDINET APIバイナリ取得のリトライ回数上限に達しました。")

    def _get_search_cache_key(self, date_str: str) -> str:
        """検索用キャッシュキー生成（日付ベース）"""
        return self.cache_store.search_cache_key(date_str)

    def _load_search_cache(self, filename: str) -> list[dict[str, Any]] | None:
        """キャッシュから検索結果をロード"""
        return self.cache_store.load_search_cache(filename)

    def _load_stale_search_cache(self, filename: str) -> list[dict[str, Any]] | None:
        """期限切れを許容して検索結果をロードする。EDINET外部キャッシュ優先用。"""
        return self.cache_store.load_search_cache(filename, allow_expired=True)

    def _save_search_cache(self, filename: str, data: list[dict[str, Any]]) -> None:
        """検索結果をキャッシュに保存"""
        self.cache_store.save_search_cache(filename, data)

    async def _get_documents_for_date(self, date_str: str) -> list[dict[str, Any]] | None:
        """特定の日付のドキュメント一覧を取得（キャッシュ対応）。

        Returns:
            取得成功（0件を含む）: list  ← キャッシュ保存済み
            API失敗かつ stale なし: None ← キャッシュ未保存
        """
        cache_key = self._get_search_cache_key(date_str)
        # TTL 尊重: 有効期限内ならそのまま返す（過去日付は TTL=3650日で実質永久）
        documents = self._load_search_cache(cache_key)
        if documents is not None:
            return documents

        try:
            with self.cache_store.file_lock(f"documents_by_date_{date_str}"):
                documents = self._load_search_cache(cache_key)
                if documents is not None:
                    return documents

                async with self._date_fetch_semaphore:
                    documents = self._load_search_cache(cache_key)
                    if documents is not None:
                        return documents
                    try:
                        data = await self._request("/documents.json", {"date": date_str, "type": 2})
                        documents = data.get("results", [])
                        self._save_search_cache(cache_key, documents)
                        return documents
                    except Exception:
                        # API 失敗時は期限切れキャッシュをフォールバックとして使う。
                        # stale もなければ None を返し、呼び出し元が「取得不能」と判断できるようにする。
                        return self._load_stale_search_cache(cache_key)
        except TimeoutError as e:
            logger.warning(f"[EDINET] date cache lock timeout: date={date_str} error={e}")
            return self._load_stale_search_cache(cache_key)

    async def ensure_document_index_for_year(self, year: int) -> list[dict[str, Any]]:
        """指定年の日次書類一覧を束ねたローカルインデックスを返す。"""
        today = datetime.now().date()
        year_start = date(year, 1, 1)
        year_end = date(year, 12, 31)
        if year_start > today:
            return []
        required_through_date = min(year_end, today)
        required_through = required_through_date.strftime("%Y-%m-%d")

        cached = self.cache_store.load_document_index(
            year,
            required_through=required_through,
            allow_stale=True,
        )
        if cached is not None:
            return cached

        if year not in self._document_index_locks:
            self._document_index_locks[year] = asyncio.Lock()
        async with self._document_index_locks[year]:
            cached = self.cache_store.load_document_index(
                year,
                required_through=required_through,
                allow_stale=True,
            )
            if cached is not None:
                return cached

            try:
                with self.cache_store.file_lock(f"document_index_{year}"):
                    cached = self.cache_store.load_document_index(
                        year,
                        required_through=required_through,
                        allow_stale=True,
                    )
                    if cached is not None:
                        return cached

                    docs = await self._build_document_index_for_year(year, required_through_date)
                    if docs is not None:
                        self.cache_store.save_document_index(year, docs, built_through=required_through)
                    return docs if docs is not None else []
            except TimeoutError as e:
                logger.warning(f"[EDINET] document index lock timeout: year={year} error={e}")
                cached = self.cache_store.load_document_index(
                    year,
                    required_through=required_through,
                    allow_stale=True,
                )
                return cached or []

    async def refresh_document_index_for_year(self, year: int) -> list[dict[str, Any]]:
        """指定年のEDINET年次インデックスを今日まで更新する。"""
        today = datetime.now().date()
        year_start = date(year, 1, 1)
        year_end = date(year, 12, 31)
        if year_start > today:
            return []
        required_through_date = min(year_end, today)
        required_through = required_through_date.strftime("%Y-%m-%d")

        if year not in self._document_index_locks:
            self._document_index_locks[year] = asyncio.Lock()
        async with self._document_index_locks[year]:
            try:
                with self.cache_store.file_lock(f"document_index_{year}"):
                    self.cache_store.clear_document_index(year)
                    docs = await self._build_document_index_for_year(year, required_through_date)
                    if docs is not None:
                        self.cache_store.save_document_index(year, docs, built_through=required_through)
                    return docs if docs is not None else []
            except TimeoutError as e:
                logger.warning(f"[EDINET] document index refresh lock timeout: year={year} error={e}")
                cached = self.cache_store.load_document_index(
                    year,
                    required_through=required_through,
                    allow_stale=True,
                )
                return cached or []

    async def catchup_document_index_for_year(self, year: int) -> list[dict[str, Any]]:
        """指定年のEDINET年次インデックスを built_through の翌日から今日まで追いつかせる。"""
        today = datetime.now().date()
        year_start = date(year, 1, 1)
        year_end = date(year, 12, 31)
        if year_start > today:
            return []
        required_through_date = min(year_end, today)
        required_through = required_through_date.strftime("%Y-%m-%d")

        if year not in self._document_index_locks:
            self._document_index_locks[year] = asyncio.Lock()
        async with self._document_index_locks[year]:
            try:
                with self.cache_store.file_lock(f"document_index_{year}"):
                    cached_info = self.cache_store.load_document_index_info(
                        year,
                        required_through=required_through,
                        allow_stale=True,
                    )
                    if cached_info is None:
                        docs = await self._build_document_index_for_year(year, required_through_date)
                        if docs is not None:
                            self.cache_store.save_document_index(year, docs, built_through=required_through)
                        return docs if docs is not None else []

                    documents = cached_info.get("documents")
                    existing_docs = list(documents) if isinstance(documents, list) else []
                    built_through = cached_info.get("built_through")
                    built_dt = parse_date_string(built_through) if isinstance(built_through, str) else None
                    if built_dt is not None and built_dt.date() >= required_through_date:
                        return existing_docs

                    start_date = (built_dt.date() + timedelta(days=1)) if built_dt is not None else year_start
                    if start_date > required_through_date:
                        self.cache_store.save_document_index(year, existing_docs, built_through=required_through)
                        return existing_docs

                    docs_by_date = await self._get_documents_for_date_range_daily(start_date, required_through_date)
                    if any(v is None for v in docs_by_date.values()):
                        return existing_docs
                    docs_by_date_clean = {k: v for k, v in docs_by_date.items() if v is not None}
                    merged = _merge_document_index_docs(existing_docs, docs_by_date_clean)
                    self.cache_store.save_document_index(year, merged, built_through=required_through)
                    return merged
            except TimeoutError as e:
                logger.warning(f"[EDINET] document index catchup lock timeout: year={year} error={e}")
                cached = self.cache_store.load_document_index(
                    year,
                    required_through=required_through,
                    allow_stale=True,
                )
                return cached or []

    async def get_documents_for_date_range(
        self,
        start: date,
        end: date,
        *,
        use_index: bool = True,
    ) -> dict[str, list[dict[str, Any]]]:
        """日付範囲の書類一覧を取得する。広い範囲では年次インデックスを優先する。"""
        if start > end:
            return {}

        days = (end - start).days + 1
        if use_index and days >= EDINET_DOCUMENT_INDEX_MIN_RANGE_DAYS:
            try:
                return await self._get_documents_for_date_range_from_index(start, end)
            except Exception as e:
                logger.warning(f"[EDINET] document index fallback to daily cache: {e}")

        docs_by_date = await self._get_documents_for_date_range_daily(start, end)
        return {k: v or [] for k, v in docs_by_date.items()}

    async def _build_document_index_for_year(
        self,
        year: int,
        required_through: date,
    ) -> list[dict[str, Any]] | None:
        """年次インデックスを構築する。

        Returns:
            成功（0件を含む）: list
            いずれかの日のAPI取得が失敗（stale もなし）: None
        """
        dates = [
            date(year, 1, 1) + timedelta(days=offset)
            for offset in range((required_through - date(year, 1, 1)).days + 1)
        ]

        documents: list[dict[str, Any]] = []
        had_failure = False
        for i in range(0, len(dates), EDINET_DOCUMENT_INDEX_BATCH_SIZE):
            batch = dates[i: i + EDINET_DOCUMENT_INDEX_BATCH_SIZE]
            responses = await asyncio.gather(
                *[self._get_documents_for_date(d.strftime("%Y-%m-%d")) for d in batch],
                return_exceptions=True,
            )
            for d, res in zip(batch, responses):
                if isinstance(res, BaseException) or res is None:
                    had_failure = True
                    continue
                list_date = d.strftime("%Y-%m-%d")
                for doc in res:
                    indexed_doc = dict(doc)
                    indexed_doc["_edinet_list_date"] = list_date
                    documents.append(indexed_doc)
        return None if had_failure else documents

    async def _get_documents_for_date_range_from_index(
        self,
        start: date,
        end: date,
    ) -> dict[str, list[dict[str, Any]]]:
        result = _empty_date_range(start, end)
        for year in range(start.year, end.year + 1):
            for doc in await self.ensure_document_index_for_year(year):
                doc_date = _document_list_date(doc)
                if doc_date is None or doc_date < start or doc_date > end:
                    continue
                result[doc_date.strftime("%Y-%m-%d")].append(_strip_index_metadata(doc))
        return result

    async def _get_documents_for_date_range_daily(
        self,
        start: date,
        end: date,
    ) -> dict[str, list[dict[str, Any]] | None]:
        result: dict[str, list[dict[str, Any]] | None] = {}
        curr = start
        while curr <= end:
            date_str = curr.strftime("%Y-%m-%d")
            result[date_str] = await self._get_documents_for_date(date_str)
            curr += timedelta(days=1)
        return result

    async def download_document(self, doc_id: str, doc_type: int = 1, save_dir: Path | None = None) -> Path | None:
        """書類をダウンロード（1=XBRLのみ維持。旧2=PDFは廃止）"""
        if doc_type != 1:
            logger.warning(f"⚠️ [EDINET] ID={doc_id} の PDF ダウンロードは廃止されました。")
            return None

        if save_dir is None:
            save_dir = self.cache_store.xbrl_root_dir
        save_dir = Path(save_dir)
        save_dir.mkdir(parents=True, exist_ok=True)

        dest = self.cache_store.xbrl_dir(doc_id, save_dir)

        if doc_id not in self._download_locks:
            self._download_locks[doc_id] = asyncio.Lock()
        async with self._download_locks[doc_id]:
            if self.cache_store.has_xbrl_dir(doc_id, save_dir):
                self.cache_store.touch_xbrl_dir(doc_id, save_dir)
                return dest

            if not self.api_key:
                return None

            try:
                async with self._xbrl_download_semaphore:
                    content = await self._request_binary(f"/documents/{doc_id}", {"type": 1})
                return self.cache_store.store_xbrl_zip(doc_id, content, save_dir)
            except Exception as e:
                logger.error(f"❌ [EDINET] XBRL Download error {doc_id}: {e}")
                return None


def _create_ssl_context() -> ssl.SSLContext:
    ca_bundle = _resolve_ca_bundle_file()
    if ca_bundle is None:
        return ssl.create_default_context()
    return ssl.create_default_context(cafile=str(ca_bundle))


def _resolve_ca_bundle_file() -> Path | None:
    env_path = os.environ.get(SSL_CERT_FILE_ENV)
    if env_path:
        path = Path(env_path).expanduser()
        if path.is_file():
            return path

    for candidate in SSL_CA_BUNDLE_CANDIDATES:
        path = Path(candidate)
        if path.is_file():
            return path
    return None


def _retry_after_seconds(error: BaseException) -> float | None:
    headers = getattr(error, "headers", None)
    retry_after = headers.get("Retry-After") if headers is not None else None
    if retry_after:
        try:
            return max(float(retry_after), 0.0)
        except ValueError:
            pass

    message = str(getattr(error, "message", "")) or str(error)
    match = re.search(r"try again in\s+(\d+(?:\.\d+)?)\s+seconds", message, re.IGNORECASE)
    if match:
        return float(match.group(1))
    return None


def _document_list_date(doc: dict[str, Any]) -> date | None:
    list_date = normalize_date_format(str(doc.get("_edinet_list_date") or ""))
    if list_date:
        parsed = parse_date_string(list_date)
        if parsed is not None:
            return parsed.date()
    submit_date = normalize_date_format(str(doc.get("submitDateTime") or ""))
    if not submit_date:
        return None
    parsed = parse_date_string(submit_date)
    return parsed.date() if parsed is not None else None


def _empty_date_range(start: date, end: date) -> dict[str, list[dict[str, Any]]]:
    days = (end - start).days + 1
    return {
        (start + timedelta(days=offset)).strftime("%Y-%m-%d"): []
        for offset in range(days)
    }


def _merge_document_index_docs(
    existing_docs: list[dict[str, Any]],
    docs_by_date: dict[str, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    merged: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()

    def append_doc(doc: dict[str, Any], list_date: str | None = None) -> None:
        indexed_doc = dict(doc)
        if list_date is not None:
            indexed_doc["_edinet_list_date"] = list_date
        doc_id = str(indexed_doc.get("docID") or "")
        doc_date = str(indexed_doc.get("_edinet_list_date") or indexed_doc.get("submitDateTime") or "")
        key = (doc_id, doc_date)
        if key in seen:
            return
        seen.add(key)
        merged.append(indexed_doc)

    for doc in existing_docs:
        append_doc(doc)
    for list_date in sorted(docs_by_date.keys()):
        for doc in docs_by_date[list_date]:
            append_doc(doc, list_date)
    return merged


def _strip_index_metadata(doc: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in doc.items() if key != "_edinet_list_date"}
