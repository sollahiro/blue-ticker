"""
キャッシュ管理モジュール

APIレスポンスのキャッシュ保存・読み込み機能を提供します。
"""

import asyncio
import json
import logging
import threading
import uuid
from datetime import datetime, date
from typing import Any, ClassVar
from pathlib import Path
import shutil

from blue_ticker.utils.cache_paths import derived_cache_dir

logger = logging.getLogger(__name__)


class _NumpyEncoder(json.JSONEncoder):
    def default(self, obj) -> Any:
        module = getattr(type(obj), "__module__", "")
        if module == "numpy" or module.startswith("numpy."):
            if hasattr(obj, "tolist"):
                return obj.tolist()
            if hasattr(obj, "item"):
                return obj.item()
        return super().default(obj)


class CacheManager:
    """
    キャッシュ管理クラス

    APIレスポンスをキャッシュし、日単位で有効期限を管理します。
    """

    # metadata.json パス単位のプロセス内共有ロック。
    # 同一 cache_dir を指す複数インスタンスが並列 async_set しても lost update が起きないよう、
    # パスをキーに同一 Lock オブジェクトを共有する。
    _path_locks: ClassVar[dict[str, threading.Lock]] = {}
    _path_locks_guard: ClassVar[threading.Lock] = threading.Lock()

    @classmethod
    def _get_path_lock(cls, path: Path) -> threading.Lock:
        key = str(path.resolve())
        with cls._path_locks_guard:
            if key not in cls._path_locks:
                cls._path_locks[key] = threading.Lock()
            return cls._path_locks[key]

    @property
    def _meta_lock(self) -> threading.Lock:
        """metadata.json パスに対応した共有 Lock を返す。"""
        return CacheManager._get_path_lock(self._get_metadata_file_path())

    def __init__(self, cache_dir: str = "cache", enabled: bool = True, ttl_days: int = 7):
        """
        初期化

        Args:
            cache_dir: キャッシュディレクトリのパス
            enabled: キャッシュを有効にするか（デフォルト: True）
            ttl_days: キャッシュ有効期限（日数、デフォルト: 7）
        """
        self._metadata_cache: dict[str, str] | None = None
        self.ttl_days = ttl_days
        self.cache_dir = Path(cache_dir)
        self.data_dir = derived_cache_dir(self.cache_dir)
        self.enabled = enabled
        logger.info(f"CacheManager initialized. Dir: {self.data_dir.absolute()} (enabled={self.enabled})")

    def set_cache_dir(self, cache_dir: str | Path) -> None:
        """キャッシュルートを差し替え、derived 配下を管理対象にする。"""
        self.cache_dir = Path(cache_dir)
        self.data_dir = derived_cache_dir(self.cache_dir)
        self._metadata_cache = None
    
    def _get_cache_file_path(self, key: str) -> Path:
        """キャッシュファイルのパスを取得"""
        # キーから安全なファイル名を生成（スペースやその他の特殊文字も置換）
        safe_key = key.replace("/", "_").replace("\\", "_").replace(" ", "_")
        return self._cache_category_dir(key) / f"{safe_key}.json"

    def _get_legacy_cache_file_path(self, key: str) -> Path:
        safe_key = key.replace("/", "_").replace("\\", "_").replace(" ", "_")
        return self.cache_dir / f"{safe_key}.json"

    def _cache_category_dir(self, key: str) -> Path:
        if key.startswith("individual_analysis_"):
            return self.data_dir / "analysis"
        if key.startswith("half_year_periods_"):
            return self.data_dir / "half_year"
        if key.startswith("edinet_docs_"):
            return self.data_dir / "document_discovery"
        if key.startswith("xbrl_parsed_"):
            return self.data_dir / "xbrl_numeric_index"
        if key.startswith("xbrl_sections_"):
            return self.data_dir / "xbrl_sections"
        return self.data_dir / "misc"
    
    def _get_metadata_file_path(self) -> Path:
        """メタデータファイルのパスを取得"""
        return self.data_dir / "metadata.json"
    
    def _load_metadata(self) -> dict[str, str]:
        """メタデータを読み込み（一度読んだらメモリキャッシュ）。_meta_lock 保持下で呼ぶこと。"""
        if self._metadata_cache is not None:
            return self._metadata_cache
        metadata_path = self._get_metadata_file_path()
        if metadata_path.exists():
            try:
                with open(metadata_path, "r", encoding="utf-8") as f:
                    data: dict[str, str] = json.load(f)
                    self._metadata_cache = data
                    return data
            except (json.JSONDecodeError, IOError):
                pass
        self._metadata_cache = {}
        return self._metadata_cache

    def _save_metadata(self, metadata: dict[str, str], *, replace: bool = False) -> None:
        """メタデータを atomic write で保存し、メモリキャッシュも更新。_meta_lock 保持下で呼ぶこと。

        replace=False（デフォルト / set 用）:
            ディスクから最新を再読み込みして metadata をマージしてから保存する。
            同一 cache_dir を指す複数インスタンス間の lost update を防ぐ。

        replace=True（clear 用）:
            metadata をそのまま保存する。呼び出し元でディスク再読み込み済みであること。
            キー削除には merge ではなく replace が必要（merge はキーを復活させてしまう）。
        """
        metadata_path = self._get_metadata_file_path()
        metadata_path.parent.mkdir(parents=True, exist_ok=True)
        if replace:
            to_write = metadata
        else:
            on_disk: dict[str, str] = {}
            if metadata_path.exists():
                try:
                    with open(metadata_path, "r", encoding="utf-8") as f:
                        on_disk = json.load(f)
                except (json.JSONDecodeError, IOError):
                    pass
            on_disk.update(metadata)
            to_write = on_disk
        tmp = metadata_path.with_name(f".metadata.{uuid.uuid4().hex}.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(to_write, f, ensure_ascii=False, indent=2)
        tmp.replace(metadata_path)
        self._metadata_cache = to_write
    
    def get(self, key: str) -> Any | None:
        """
        キャッシュからデータを取得

        Args:
            key: キャッシュキー

        Returns:
            キャッシュされたデータ。存在しないか期限切れの場合はNone
        """
        if not self.enabled:
            return None

        cache_file = self._get_cache_file_path(key)
        if not cache_file.exists():
            legacy_cache_file = self._get_legacy_cache_file_path(key)
            if not legacy_cache_file.exists():
                return None
            cache_file = legacy_cache_file

        with self._meta_lock:
            metadata = self._load_metadata()
            cache_date = metadata.get(key)

        if cache_date:
            try:
                cache_datetime = datetime.fromisoformat(cache_date)
                cache_date_obj = cache_datetime.date()
                today = date.today()
                
                if (today - cache_date_obj).days >= self.ttl_days:
                    return None
            except (ValueError, TypeError):
                return None
        
        # キャッシュファイルを読み込み
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            return None
    
    def set(self, key: str, value: Any) -> None:
        """
        キャッシュにデータを保存
        
        Args:
            key: キャッシュキー
            value: 保存するデータ
        """
        if not self.enabled:
            return
        
        cache_file = self._get_cache_file_path(key)
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        
        # データを atomic write で保存（同一ファイルシステム上の rename はアトミック）
        tmp = cache_file.with_name(f".{cache_file.name}.{uuid.uuid4().hex}.tmp")
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(value, f, ensure_ascii=False, cls=_NumpyEncoder)
            tmp.replace(cache_file)
        except (TypeError, IOError) as e:
            # キャッシュ保存に失敗しても処理は続行
            logger.warning(f"キャッシュの保存に失敗しました: {e}")
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
            return

        # メタデータを更新
        with self._meta_lock:
            metadata = self._load_metadata()
            metadata[key] = datetime.now().isoformat()
            self._save_metadata(metadata)

    def keys(self) -> list[str]:
        """保存済みキャッシュキーの一覧を返す。"""
        with self._meta_lock:
            return sorted(self._load_metadata().keys())

    def clear_prefix(self, prefix: str) -> int:
        """指定 prefix で始まるキャッシュを削除し、削除件数を返す。"""
        keys = [key for key in self.keys() if key.startswith(prefix)]
        for key in keys:
            self.clear(key)
        return len(keys)
    
    async def async_get(self, key: str) -> Any | None:
        """非同期コンテキスト用の get ラッパー。ファイルI/O をスレッドプールに委譲する。"""
        return await asyncio.to_thread(self.get, key)

    async def async_set(self, key: str, value: Any) -> None:
        """非同期コンテキスト用の set ラッパー。ファイルI/O をスレッドプールに委譲する。"""
        await asyncio.to_thread(self.set, key, value)

    def clear(self, key: str | None = None) -> None:
        """
        キャッシュをクリア
        
        Args:
            key: クリアするキャッシュキー。Noneの場合は全キャッシュをクリア
        """
        if key:
            cache_file = self._get_cache_file_path(key)
            if cache_file.exists():
                cache_file.unlink()
            legacy_cache_file = self._get_legacy_cache_file_path(key)
            if legacy_cache_file.exists():
                legacy_cache_file.unlink()

            with self._meta_lock:
                # _load_metadata() は in-memory キャッシュが stale な場合があるため、
                # ディスクから直接読み込んで削除し、replace=True で保存する。
                metadata_path = self._get_metadata_file_path()
                on_disk: dict[str, str] = {}
                if metadata_path.exists():
                    try:
                        with open(metadata_path, "r", encoding="utf-8") as f:
                            on_disk = json.load(f)
                    except (json.JSONDecodeError, IOError):
                        pass
                on_disk.pop(key, None)
                self._save_metadata(on_disk, replace=True)
        else:
            # 全キャッシュをクリア
            if self.data_dir.exists():
                shutil.rmtree(self.data_dir)

            with self._meta_lock:
                metadata_path = self._get_metadata_file_path()
                if metadata_path.exists():
                    metadata_path.unlink()
                self._metadata_cache = None





