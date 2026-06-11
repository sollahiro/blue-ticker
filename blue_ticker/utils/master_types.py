"""
銘柄マスタ関連の TypedDict 定義

CSV 読み込み後の内部表現と、検索/業種一覧の公開結果を型で表現する。
"""

from typing import TypedDict


class MasterStock(TypedDict):
    Code: str               # 証券コード（4桁または5桁）。未上場は空文字
    EdinetCode: str         # ＥＤＩＮＥＴコード（E00004 形式）
    CoName: str             # 提出者名
    CoNameEn: str           # 提出者名（英字）
    CoNameKana: str         # 提出者名（ヨミ）
    CoNameNormalized: str   # 検索用正規化名称
    S33Nm: str              # 提出者業種
    MktNm: str              # 上場区分（"上場" / "非上場"）
    IsListed: bool          # 上場かどうか
    HasConsolidated: bool   # 連結の有無


class StockSearchResult(TypedDict):
    code: str
    name: str
    sector: str
    market: str


class SectorSummary(TypedDict):
    code: str
    name: str
    count: int
