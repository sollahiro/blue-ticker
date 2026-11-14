# Breakdown 軸の3分割（segment / product_service / geography）

出典: 旧課題管理のチケット（移行日 2026-11-12）。当時の題名: Breakdown 軸を出典表で3分割: segment / product_service / geography。
この文書は決定・契約の正本としてリポジトリで維持する。件数や進捗の最新値はここに書かない。現行の公開軸は `docs/breakdown.md`。

## 問題

当時の product_service 軸は「報告セグメント表」と「関連情報・製品及びサービスごとの情報」を1軸に混ぜ、年ごとにどちらか一方を採用していた。

* 同一企業で年によって区分が変わる（6758: FY2025 はセグメント、FY2021–24 は製品カテゴリー）
* 従業員・設備投資・セグメント利益（報告セグメント単位で開示）とキーがつながらず、一人当たり売上が出せない
* 製品表の小計・重複を segment 行として扱う
* 報告セグメント自体が地域別の会社もある

## 方針: 軸は「中身」ではなく「有報のどの表から取ったか」で決める

| 軸 | 出典 | 備考 |
| -- | -- | -- |
| segment | セグメント情報・報告セグメント表（XBRL の ReportableSegment member / 外部顧客売上） | 行に segment_basis = business / geographic を持つ。全社・調整は reconciling。単一セグメントは1行または開示なし |
| product_service | 関連情報「製品及びサービスごとの情報」 | 開示がなければ空。旧公開キー `business` は廃止 |
| geography | 関連情報「地域ごとの情報」 | 現行どおり |

従業員・設備投資・利益の結合キーは segment 軸。

## 重複ルール

1. 関連情報が「セグメント情報に同様の情報を開示しているため記載を省略」→ その軸は `same_as: segment` の参照だけを持つ（値は複製しない。API は値を返してよいが出典を segment と示す）。
2. 両方開示・中身が違う（所在地別セグメント vs 顧客所在地別地域）→ 別物として両方持つ。
3. 両方開示・中身が同じ → 両方持つ。一致を CI チェックにできる。
4. 単一セグメント → segment は1行/なし、関連情報側だけに値。

どの軸の値も有報の特定ページに一対一で対応すること。

## Golden（壊れた行のみ）

* 6758/S100W19Q/breakdown/segment: G&NS=4,543,571 / 音楽=1,820,263 / 映画=1,498,534 / ET&S=2,362,838 / I&SS=1,712,534 / 金融=922,147 / その他=82,477（百万円, p152, segment）; denominator=12,957,064（p126/p155）
* 6758/S100W19Q/breakdown/product_service: 「その他」が segment 軸に混入しないこと（製品カテゴリー表 p155 はこの軸）

## 実装メモ（原因）

* `SalesAndFinancialServicesRevenueToCustomersIFRS` が `Xbrl.segmentExternalRevenueTags` に無い
* coverage discovery ±5% が NetSales と比較（金融ビジネス収入を含む売上と比較すべき）
* `preferredTables` が製品表を優先し報告セグメント行列を出さない

構造判断は設計レビューの対象。
