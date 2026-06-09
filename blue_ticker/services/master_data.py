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


class MasterDataManager:
    """銘柄マスタ（CSV）の読み込み、保持、検索を行うクラス"""
    
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
        # 1. NFKC + Upper
        normalized = unicodedata.normalize('NFKC', name).upper()
        # 2. 中点の除去
        normalized = normalized.replace('・', '').replace('･', '')
        # 3. スペースの除去
        normalized = "".join(normalized.split())
        return normalized

    def load_if_needed(self) -> bool:
        """必要に応じてマスタデータをロード"""
        if not self._is_loaded:
            return self.reload()
        return True

    def reload(self) -> bool:
        """銘柄マスタを強制的に再読み込み

        data_j.csv の入手先:
            https://www.jpx.co.jp/markets/statistics-equities/misc/01.html
            （東証上場銘柄一覧 → 「東証上場銘柄一覧（Excel）」をダウンロードし、
              data_j.csv という名前で assets/ に配置する）
        """
        # 1. パスの決定
        assets_dir = os.environ.get(ASSETS_PATH_ENV)
        if assets_dir:
            csv_path = Path(assets_dir) / "data_j.csv"
        else:
            # 探索候補
            candidates = [
                Path("assets/data_j.csv"),
                Path(__file__).parent.parent.parent / "assets" / "data_j.csv",
                # インストール環境を想定
                Path(settings_store.user_data_path) / "assets" / "data_j.csv",
            ]
            csv_path = None
            for p in candidates:
                if p.exists():
                    csv_path = p
                    break
            
            if not csv_path:
                csv_path = Path("assets/data_j.csv") # デフォルト
            
        logger.info(f"銘柄マスタを読み込んでいます: {csv_path}")
        
        if not csv_path.exists():
            logger.warning(f"銘柄マスタが見つかりません: {csv_path}")
            return False
            
        try:
            # 2. CSV読み込み（全て文字列として扱いコードの0落ちを防ぐ）
            # utf-8-sig は BOM 有無両対応
            with open(csv_path, encoding='utf-8-sig', newline='') as f:
                reader = csv.DictReader(f)
                raw_data = list(reader)
            
            # 4. 検索用データの事前処理
            # 許可する市場区分（個別株のみ）
            allowed_markets = ["プライム", "スタンダード", "グロース"]
            processed_data: list[MasterStock] = []
            
            for row in raw_data:
                market = row.get("市場・商品区分", "")
                # 許可された区分に含まれない（ETF, REIT, PRO Market等）場合は除外
                if not any(m in market for m in allowed_markets):
                    continue
                
                # 市場名のクリーンアップ（事前に行う）
                clean_market = market.split("（")[0].split("(")[0]
                
                # 検索用正規化名称
                normalized_name = self._normalize_name(row.get("銘柄名", ""))
                
                processed_data.append({
                    "Code": row.get("コード", ""),
                    "CoName": row.get("銘柄名", ""),
                    "CoNameUpper": row.get("銘柄名", "").upper(), # 互換性維持のため残すが、基本はNormalizedを使用
                    "CoNameNormalized": normalized_name, # 正規化済み名称
                    "S33Nm": row.get("33業種区分", ""),
                    "MktNm": clean_market,
                    "S33": row.get("33業種コード", ""),
                    "S17Nm": row.get("17業種区分", ""),
                    "S17": row.get("17業種コード", ""),
                })
            
            self._master_data = processed_data
            # O(1) ルックアップ用インデックスを構築（4桁・5桁両方でアクセス可能に）
            self._code_index = {}
            for item in self._master_data:
                code = item.get("Code", "")
                if code:
                    self._code_index[code] = item
                    if len(code) == 4:
                        self._code_index[code + "0"] = item
                    elif len(code) == 5 and code.endswith("0"):
                        self._code_index[code[:4]] = item
            self._is_loaded = True
            logger.info(f"銘柄マスタを更新しました: {len(self._master_data)} 件 (元データ {len(raw_data)} 件)")
            return True
            
        except Exception as e:
            logger.error(f"銘柄マスタの読み込みに失敗しました: {e}", exc_info=True)
            return False

    def search(self, query: str, limit: int = 20) -> list[StockSearchResult]:
        """
        コードまたは名称で銘柄を検索
        """
        self.load_if_needed()
        
        if not query:
            return []
            
        query_normalized = self._normalize_name(query)
        results: list[StockSearchResult] = []
        
        for item in self._master_data:
            code = item.get("Code", "")
            name_upper = item.get("CoNameUpper", "")
            name_normalized = item.get("CoNameNormalized", "")
            
            # マッチング
            # 1. コード完全一致 または 4桁コード前方一致
            query_upper = query.strip().upper() # コード比較用には単純なUpperを使用
            is_match = (query_upper == code) or (code.startswith(query_upper) and len(query_upper) == 4)
            # 2. 名称部分一致（正規化済み名称で比較）
            if not is_match:
                is_match = (query_normalized in name_normalized)
            
            if is_match:
                results.append({
                    "code": code,
                    "name": item.get("CoName", ""),
                    "sector": item.get("S33Nm", ""),
                    "market": item.get("MktNm", ""),
                })
                
                if len(results) >= limit:
                    break
                    
        return results

    def get_by_code(self, code: str) -> MasterStock | None:
        """コード指定で銘柄情報を取得"""
        self.load_if_needed()
        if not code:
            return None
        return self._code_index.get(str(code).strip())

    def list_sectors(self) -> list[SectorSummary]:
        """33業種の一覧を銘柄数付きで返す"""
        self.load_if_needed()
        counts: dict[str, int] = {}
        names: dict[str, str] = {}
        for item in self._master_data:
            code = item.get("S33", "")
            name = item.get("S33Nm", "")
            if code and name:
                counts[code] = counts.get(code, 0) + 1
                names[code] = name
        return [
            {"code": c, "name": names[c], "count": counts[c]}
            for c in sorted(counts)
        ]

    def search_by_sector(self, sector_query: str, limit: int = 200) -> list[StockSearchResult]:
        """業種名（部分一致）で銘柄一覧を返す"""
        self.load_if_needed()
        query_normalized = self._normalize_name(sector_query)
        results: list[StockSearchResult] = []
        for item in self._master_data:
            sector_name = item.get("S33Nm", "")
            if query_normalized in self._normalize_name(sector_name):
                results.append({
                    "code": item.get("Code", ""),
                    "name": item.get("CoName", ""),
                    "sector": sector_name,
                    "market": item.get("MktNm", ""),
                })
            if len(results) >= limit:
                break
        return results

# シングルトン
master_data_manager = MasterDataManager()
