"""
銘柄マスタ管理サービス
"""

import csv
import logging
import os
import unicodedata
from pathlib import Path
from blue_ticker.infrastructure.settings import settings_store
from blue_ticker.utils.master_types import MasterStock, SectorSummary, StockSearchResult

logger = logging.getLogger(__name__)

ASSETS_PATH_ENV = "BLUE_TICKER_ASSETS_PATH"
_CSV_FILENAME = "EdinetcodeDlInfo.csv"


class MasterDataManager:
    """銘柄マスタ（EDINET CSV）の読み込み、保持、検索を行うクラス"""

    def __init__(self):
        self._is_loaded = False
        self._master_data: list[MasterStock] = []
        self._code_index: dict[str, MasterStock] = {}

    def _normalize_name(self, name: str) -> str:
        """
        検索用の名称正規化
        1. NFKC正規化（全角英数を半角に、半角カナを全角に）
        2. 大文字化
        3. 中点（・, ･）の除去
        4. スペース（全角・半角）の除去
        """
        if not name:
            return ""
        normalized = unicodedata.normalize('NFKC', name).upper()
        normalized = normalized.replace('・', '').replace('･', '')
        normalized = "".join(normalized.split())
        return normalized

    def load_if_needed(self) -> bool:
        """必要に応じてマスタデータをロード"""
        if not self._is_loaded:
            return self.reload()
        return True

    def reload(self) -> bool:
        """銘柄マスタを強制的に再読み込み

        EdinetcodeDlInfo.csv の入手先:
            https://disclosure2.edinet-fsa.go.jp/weee0010.aspx
            （EDINETコード一覧 → ダウンロード後、assets/ に配置する）
        """
        assets_dir = os.environ.get(ASSETS_PATH_ENV)
        if assets_dir:
            csv_path = Path(assets_dir) / _CSV_FILENAME
        else:
            candidates = [
                Path("assets") / _CSV_FILENAME,
                Path(__file__).parent.parent.parent / "assets" / _CSV_FILENAME,
                Path(settings_store.user_data_path) / "assets" / _CSV_FILENAME,
            ]
            csv_path = None
            for p in candidates:
                if p.exists():
                    csv_path = p
                    break
            if not csv_path:
                csv_path = Path("assets") / _CSV_FILENAME

        logger.info(f"銘柄マスタを読み込んでいます: {csv_path}")

        if not csv_path.exists():
            logger.warning(f"銘柄マスタが見つかりません: {csv_path}")
            return False

        try:
            # 1行目はメタデータ（ダウンロード実行日など）、2行目がヘッダ
            with open(csv_path, encoding='cp932', newline='') as f:
                next(f)  # メタデータ行をスキップ
                reader = csv.DictReader(f)
                raw_data = list(reader)

            processed_data: list[MasterStock] = []

            for row in raw_data:
                edinet_code = row.get("ＥＤＩＮＥＴコード", "").strip('"').strip()
                listing = row.get("上場区分", "").strip('"').strip()
                consolidated = row.get("連結の有無", "").strip('"').strip()
                co_name = row.get("提出者名", "").strip('"').strip()
                co_name_en = row.get("提出者名（英字）", "").strip('"').strip()
                co_name_kana = row.get("提出者名（ヨミ）", "").strip('"').strip()
                industry = row.get("提出者業種", "").strip('"').strip()
                securities_code = row.get("証券コード", "").strip('"').strip()

                # 証券コードは5桁（末尾0）で格納されている。4桁に正規化する
                code = securities_code[:4] if len(securities_code) == 5 else securities_code

                processed_data.append({
                    "Code": code,
                    "EdinetCode": edinet_code,
                    "CoName": co_name,
                    "CoNameEn": co_name_en,
                    "CoNameKana": co_name_kana,
                    "CoNameNormalized": self._normalize_name(co_name),
                    "S33Nm": industry,
                    "MktNm": listing,
                    "IsListed": listing == "上場",
                    "HasConsolidated": consolidated == "有",
                })

            self._master_data = processed_data

            # O(1)ルックアップ用インデックス（証券コード4桁・5桁・EDINETコードでアクセス可能）
            self._code_index = {}
            for item in self._master_data:
                code = item["Code"]
                edinet_code = item["EdinetCode"]
                if code:
                    self._code_index[code] = item
                    self._code_index[code + "0"] = item
                if edinet_code:
                    self._code_index[edinet_code] = item

            self._is_loaded = True
            logger.info(f"銘柄マスタを更新しました: {len(self._master_data)} 件 (元データ {len(raw_data)} 件)")
            return True

        except Exception as e:
            logger.error(f"銘柄マスタの読み込みに失敗しました: {e}", exc_info=True)
            return False

    def search(self, query: str, limit: int = 20) -> list[StockSearchResult]:
        """コード・EDINETコード・名称で銘柄を検索"""
        self.load_if_needed()

        if not query:
            return []

        query_normalized = self._normalize_name(query)
        query_upper = query.strip().upper()
        results: list[StockSearchResult] = []

        for item in self._master_data:
            code = item["Code"]
            edinet_code = item["EdinetCode"]
            name_normalized = item["CoNameNormalized"]

            is_match = (
                (query_upper == code)
                or (code.startswith(query_upper) and len(query_upper) == 4)
                or (query_upper == edinet_code)
                or (query_normalized in name_normalized)
            )

            if is_match:
                results.append({
                    "code": code or edinet_code,
                    "name": item["CoName"],
                    "sector": item["S33Nm"],
                    "market": item["MktNm"],
                })
                if len(results) >= limit:
                    break

        return results

    def get_by_code(self, code: str) -> MasterStock | None:
        """証券コードまたはEDINETコード指定で銘柄情報を取得"""
        self.load_if_needed()
        if not code:
            return None
        return self._code_index.get(str(code).strip())

    def list_sectors(self) -> list[SectorSummary]:
        """業種の一覧を銘柄数付きで返す"""
        self.load_if_needed()
        counts: dict[str, int] = {}
        for item in self._master_data:
            industry = item["S33Nm"]
            if industry:
                counts[industry] = counts.get(industry, 0) + 1
        return [
            {"code": name, "name": name, "count": counts[name]}
            for name in sorted(counts)
        ]

    def search_by_sector(self, sector_query: str, limit: int = 200) -> list[StockSearchResult]:
        """業種名（部分一致）で銘柄一覧を返す"""
        self.load_if_needed()
        query_normalized = self._normalize_name(sector_query)
        results: list[StockSearchResult] = []
        for item in self._master_data:
            industry = item["S33Nm"]
            if query_normalized in self._normalize_name(industry):
                results.append({
                    "code": item["Code"] or item["EdinetCode"],
                    "name": item["CoName"],
                    "sector": industry,
                    "market": item["MktNm"],
                })
            if len(results) >= limit:
                break
        return results


# シングルトン
master_data_manager = MasterDataManager()
