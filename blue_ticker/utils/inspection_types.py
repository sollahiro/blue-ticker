"""inspect コマンドの異常値候補 TypedDict 定義。

services/inspector.py が組み立て、app/cli/inspect.py が表示に使う
レイヤー間共有のデータ構造。
"""

from typing import TypedDict


class AnomalyCandidate(TypedDict):
    """人間のレビューに回す異常値候補1件。

    severity:
        warning: データ誤りの可能性が高い（単位誤り・恒等式不一致など）
        info:    正当な理由がありうるが目視確認に値する（税率の範囲外など）
    evidence: 判断根拠となった実際の値。レビュー時の再現確認に使う。
    """

    code: str
    name: str | None
    fy_end: str | None
    check: str
    severity: str
    message: str
    evidence: dict[str, float | int | str | None]


class InspectionReport(TypedDict):
    """分析キャッシュ走査の結果サマリー。"""

    scanned_codes: int
    scanned_years: int
    candidates: list[AnomalyCandidate]
