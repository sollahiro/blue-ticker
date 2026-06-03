"""
キャッシュ整理サービス

廃止済みキャッシュや肥大化しやすい EDINET キャッシュを削除する。
"""

import shutil
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

from blue_ticker.constants.api import EDINET_DOCUMENT_INDEX_KEEP_YEARS
from blue_ticker.utils.cache import CacheManager
from blue_ticker.utils.cache_paths import derived_cache_dir, edinet_cache_dir, external_cache_dir


@dataclass(frozen=True)
class PruneSummary:
    removed_files: int = 0
    removed_dirs: int = 0
    freed_bytes: int = 0
    scanned_files: int = 0
    scanned_dirs: int = 0
    dry_run: bool = True

    def to_dict(self) -> dict[str, int | bool]:
        return asdict(self)


@dataclass(frozen=True)
class CacheStats:
    cache_dir: str
    total_files: int = 0
    total_dirs: int = 0
    total_bytes: int = 0
    metadata_entries: int = 0
    root_json_files: int = 0
    edinet_search_files: int = 0
    edinet_search_bytes: int = 0
    edinet_doc_index_files: int = 0
    edinet_doc_index_bytes: int = 0
    edinet_xbrl_dirs: int = 0
    edinet_xbrl_bytes: int = 0
    edinet_docs_cache_files: int = 0
    edinet_docs_cache_bytes: int = 0
    xbrl_parse_cache_files: int = 0
    xbrl_parse_cache_bytes: int = 0
    individual_analysis_files: int = 0
    individual_analysis_bytes: int = 0
    half_year_analysis_files: int = 0
    half_year_analysis_bytes: int = 0
    unknown_root_json_files: int = 0

    def to_dict(self) -> dict[str, int | str]:
        return asdict(self)


@dataclass(frozen=True)
class CacheAudit:
    cache_dir: str
    unknown_root_json_files: list[str]
    orphan_metadata_keys: list[str]
    edinet_search_files: list[str]
    edinet_doc_index_files: list[str]
    edinet_xbrl_dirs: list[str]
    edinet_docs_cache_files: list[str]
    xbrl_parse_cache_files: list[str]
    individual_analysis_files: list[str]
    half_year_analysis_files: list[str]

    def to_dict(self) -> dict[str, str | list[str]]:
        return asdict(self)



class CachePruner:
    """キャッシュディレクトリのスリム化を担当する。"""

    def __init__(self, cache_dir: str | Path):
        self.cache_dir = Path(cache_dir)
        self.external_dir = external_cache_dir(self.cache_dir)
        self.edinet_dir = edinet_cache_dir(self.cache_dir)
        self.derived_dir = derived_cache_dir(self.cache_dir)
        self.cache_manager = CacheManager(cache_dir=str(self.cache_dir))

    def prune(
        self,
        *,
        dry_run: bool = True,
        edinet_search_days: int | None = None,
        edinet_xbrl_days: int | None = None,
        edinet_doc_index_years: int | None = EDINET_DOCUMENT_INDEX_KEEP_YEARS,
    ) -> PruneSummary:
        summary = PruneSummary(dry_run=dry_run)
        if edinet_search_days is not None:
            summary = self._merge(
                summary,
                self._prune_edinet_search(days=edinet_search_days, dry_run=dry_run),
            )
        if edinet_xbrl_days is not None:
            summary = self._merge(
                summary,
                self._prune_edinet_xbrl(days=edinet_xbrl_days, dry_run=dry_run),
            )
        if edinet_doc_index_years is not None:
            summary = self._merge(
                summary,
                self._prune_edinet_doc_indexes(
                    keep_years=edinet_doc_index_years,
                    dry_run=dry_run,
                ),
            )
        return summary

    def stats(self) -> CacheStats:
        """キャッシュ全体のサイズと主要カテゴリ別件数を返す。"""
        files = [path for path in self.cache_dir.rglob("*") if path.is_file()]
        dirs = [path for path in self.cache_dir.rglob("*") if path.is_dir()]
        metadata_keys = self.cache_manager.keys()
        root_json_files = _legacy_root_json_files(self.cache_dir)
        derived_json_files = _derived_json_files(self.derived_dir)
        known_root_prefixes = (
            "individual_analysis_",
            "half_year_periods_",
            "edinet_docs_",
            "xbrl_parsed_",
        )
        edinet_search_files = _edinet_search_files(self.edinet_dir)
        edinet_doc_index_files = _edinet_doc_index_files(self.edinet_dir)
        edinet_xbrl_dirs = _edinet_xbrl_dirs(self.edinet_dir)
        edinet_docs_cache_files = _category_files(self.derived_dir / "document_discovery", root_json_files, "edinet_docs_")
        xbrl_parse_cache_files = _category_files(self.derived_dir / "xbrl_numeric_index", root_json_files, "xbrl_parsed_")
        individual_analysis_files = _category_files(self.derived_dir / "analysis", root_json_files, "individual_analysis_")
        half_year_analysis_files = _category_files(self.derived_dir / "half_year", root_json_files, "half_year_periods_")
        unknown_root_json_files = [
            path
            for path in root_json_files + [p for p in derived_json_files if p.parent.name == "misc"]
            if not path.stem.startswith(known_root_prefixes)
        ]

        return CacheStats(
            cache_dir=str(self.cache_dir),
            total_files=len(files),
            total_dirs=len(dirs),
            total_bytes=sum(path.stat().st_size for path in files),
            metadata_entries=len(metadata_keys),
            root_json_files=len(root_json_files),
            edinet_search_files=len(edinet_search_files),
            edinet_search_bytes=sum(path.stat().st_size for path in edinet_search_files),
            edinet_doc_index_files=len(edinet_doc_index_files),
            edinet_doc_index_bytes=sum(path.stat().st_size for path in edinet_doc_index_files),
            edinet_xbrl_dirs=len(edinet_xbrl_dirs),
            edinet_xbrl_bytes=sum(self._path_size(path) for path in edinet_xbrl_dirs),
            edinet_docs_cache_files=len(edinet_docs_cache_files),
            edinet_docs_cache_bytes=sum(path.stat().st_size for path in edinet_docs_cache_files),
            xbrl_parse_cache_files=len(xbrl_parse_cache_files),
            xbrl_parse_cache_bytes=sum(path.stat().st_size for path in xbrl_parse_cache_files),
            individual_analysis_files=len(individual_analysis_files),
            individual_analysis_bytes=sum(path.stat().st_size for path in individual_analysis_files),
            half_year_analysis_files=len(half_year_analysis_files),
            half_year_analysis_bytes=sum(path.stat().st_size for path in half_year_analysis_files),
            unknown_root_json_files=len(unknown_root_json_files),
        )

    def audit(self) -> CacheAudit:
        """キャッシュカテゴリ別のファイル一覧を返す。削除は行わない。"""
        metadata_keys = self.cache_manager.keys()
        root_json_files = _legacy_root_json_files(self.cache_dir)
        derived_json_files = _derived_json_files(self.derived_dir)
        known_root_prefixes = (
            "individual_analysis_",
            "half_year_periods_",
            "edinet_docs_",
            "xbrl_parsed_",
        )
        existing_cache_stems = {path.stem for path in root_json_files + derived_json_files}
        return CacheAudit(
            cache_dir=str(self.cache_dir),
            unknown_root_json_files=_names([
                path for path in root_json_files + [p for p in derived_json_files if p.parent.name == "misc"]
                if not path.stem.startswith(known_root_prefixes)
            ]),
            orphan_metadata_keys=sorted(key for key in metadata_keys if key not in existing_cache_stems),
            edinet_search_files=_names(_edinet_search_files(self.edinet_dir)),
            edinet_doc_index_files=_names(_edinet_doc_index_files(self.edinet_dir)),
            edinet_xbrl_dirs=_names(_edinet_xbrl_dirs(self.edinet_dir)),
            edinet_docs_cache_files=_names(_category_files(self.derived_dir / "document_discovery", root_json_files, "edinet_docs_")),
            xbrl_parse_cache_files=_names(_category_files(self.derived_dir / "xbrl_numeric_index", root_json_files, "xbrl_parsed_")),
            individual_analysis_files=_names(_category_files(self.derived_dir / "analysis", root_json_files, "individual_analysis_")),
            half_year_analysis_files=_names(_category_files(self.derived_dir / "half_year", root_json_files, "half_year_periods_")),
        )

    def _prune_edinet_search(self, *, days: int, dry_run: bool) -> PruneSummary:
        files = [
            path
            for path in _edinet_search_files(self.edinet_dir)
            if self._age_days(path) >= days
        ]
        freed = sum(path.stat().st_size for path in files if path.exists())
        if not dry_run:
            for path in files:
                if path.exists():
                    path.unlink()
        return PruneSummary(
            removed_files=len(files),
            freed_bytes=freed,
            scanned_files=len(files),
            dry_run=dry_run,
        )

    def _prune_edinet_xbrl(self, *, days: int, dry_run: bool) -> PruneSummary:
        dirs = [
            path
            for path in _edinet_xbrl_dirs(self.edinet_dir)
            if path.is_dir() and self._age_days(path) >= days
        ]
        freed = sum(self._path_size(path) for path in dirs)
        if not dry_run:
            for path in dirs:
                if path.exists():
                    shutil.rmtree(path)
        return PruneSummary(
            removed_dirs=len(dirs),
            freed_bytes=freed,
            scanned_dirs=len(dirs),
            dry_run=dry_run,
        )

    def _prune_edinet_doc_indexes(self, *, keep_years: int, dry_run: bool) -> PruneSummary:
        if keep_years <= 0:
            threshold_year = datetime.now().year + 1
        else:
            threshold_year = datetime.now().year - keep_years + 1
        files = [
            path
            for path in _edinet_doc_index_files(self.edinet_dir)
            if (year := _doc_index_year(path)) is not None and year < threshold_year
        ]
        freed = sum(path.stat().st_size for path in files if path.exists())
        if not dry_run:
            for path in files:
                if path.exists():
                    path.unlink()
        return PruneSummary(
            removed_files=len(files),
            freed_bytes=freed,
            scanned_files=len(files),
            dry_run=dry_run,
        )

    @staticmethod
    def _age_days(path: Path) -> int:
        mtime = datetime.fromtimestamp(path.stat().st_mtime)
        return (datetime.now() - mtime).days

    @staticmethod
    def _path_size(path: Path) -> int:
        if path.is_file():
            return path.stat().st_size
        return sum(child.stat().st_size for child in path.rglob("*") if child.is_file())

    @staticmethod
    def _merge(left: PruneSummary, right: PruneSummary) -> PruneSummary:
        return PruneSummary(
            removed_files=left.removed_files + right.removed_files,
            removed_dirs=left.removed_dirs + right.removed_dirs,
            freed_bytes=left.freed_bytes + right.freed_bytes,
            scanned_files=left.scanned_files + right.scanned_files,
            scanned_dirs=left.scanned_dirs + right.scanned_dirs,
            dry_run=left.dry_run and right.dry_run,
        )


def _doc_index_year(path: Path) -> int | None:
    year_text = path.stem.removeprefix("doc_index_")
    try:
        return int(year_text)
    except ValueError:
        return None


def _names(paths: Iterable[Path]) -> list[str]:
    return sorted(path.name for path in paths)


def _legacy_root_json_files(cache_dir: Path) -> list[Path]:
    return [
        path
        for path in cache_dir.glob("*.json")
        if path.name != "metadata.json"
    ]


def _derived_json_files(derived_dir: Path) -> list[Path]:
    if not derived_dir.exists():
        return []
    return [
        path
        for path in derived_dir.rglob("*.json")
        if path.name != "metadata.json"
    ]


def _category_files(category_dir: Path, legacy_files: list[Path], prefix: str) -> list[Path]:
    files = list(category_dir.glob(f"{prefix}*.json")) if category_dir.exists() else []
    files.extend(path for path in legacy_files if path.stem.startswith(prefix))
    return files


def _edinet_search_files(edinet_dir: Path) -> list[Path]:
    legacy_edinet_dir = edinet_dir.parent.parent / "edinet"
    files = list((edinet_dir / "documents_by_date").glob("search_*.json"))
    files.extend(edinet_dir.glob("search_*.json"))
    files.extend(legacy_edinet_dir.glob("search_*.json"))
    return files


def _edinet_doc_index_files(edinet_dir: Path) -> list[Path]:
    legacy_edinet_dir = edinet_dir.parent.parent / "edinet"
    files = list((edinet_dir / "document_indexes").glob("doc_index_*.json"))
    files.extend(edinet_dir.glob("doc_index_*.json"))
    files.extend(legacy_edinet_dir.glob("doc_index_*.json"))
    return files


def _edinet_xbrl_dirs(edinet_dir: Path) -> list[Path]:
    legacy_edinet_dir = edinet_dir.parent.parent / "edinet"
    dirs = [path for path in (edinet_dir / "xbrl").glob("*_xbrl") if path.is_dir()]
    dirs.extend(path for path in edinet_dir.glob("*_xbrl") if path.is_dir())
    dirs.extend(path for path in legacy_edinet_dir.glob("*_xbrl") if path.is_dir())
    return dirs
