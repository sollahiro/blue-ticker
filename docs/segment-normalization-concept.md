# 事業別・地域別売上の正規化構想（Stage 6）

企業間比較（同業の事業割合・地域割合）と、同一企業の期ごとの推移把握を目的とする。抽出の綺麗さ自体ではなく、**比較可能な共通指標に落とすこと**が本体。

関連: 現行抽出は `SegmentExtractor`（`docs/xbrl-parsing.md`）。ロードマップ上は Stage 6（`docs/blt-server-roadmap.md`）。

## 目的

| 用途 | 必要なもの |
|---|---|
| 同業比較 | 同じ期・同じ軸で事業割合 / 地域割合を並べる |
| 推移 | 同一企業の期ごとのスナップショット列 |

割合の定義（比較の正本）:

\[
\text{事業割合}_i = \frac{\text{外部売上}_i}{\text{連結外部売上}},\quad
\text{地域割合}_j = \frac{\text{仕向地売上}_j}{\text{連結外部売上}}
\]

原則指標は **外部顧客売上**（内部取引込みは使わない）。分母は連結の外部売上（調整後）。

### 方針（確定）

- **事業再編・セグメント名称変更の過去遡及補正はしない。** 変わるのは所与。各期はその期の開示どおり保存・表示する。
- `segments` / `geography` は意味ラベルではなく **開示ブロックの取り分け**（報告セグメント注記 / 地域注記）。事業×地域の両方が常にあることは保証しない。

## 現行抽出の実態

`SegmentExtractor` は2段:

1. **本命** — 専用 TextBlock 内 HTML 表 → `method: "html_table"`（Markdown）
2. **フォールバック** — dimension 付き数値 fact（事業軸 / 地域軸キーワード）→ `method: "xbrl_facts"`

キー:

| API キー | XBRL 上の意味 |
|---|---|
| `segments` | 報告セグメント（`OperatingSegments` 等）。マネジメント・アプローチのため **事業とも地域とも限らない** |
| `geography` | 地域別注記（GeographicArea 系 TextBlock / dimension） |

## 試行で見えた会社差（2026-07）

対象は有報 XBRL（味の素・日立・オークマは 26-03、ヒューリック・キヤノンは 25-12）。

| 会社 | `segments` | `geography` | 「事業別」の実置き場 |
|---|---|---|---|
| 味の素 | `xbrl_facts`（事業） | `html_table` | 報告セグメント |
| 日立 | `xbrl_facts`（事業） | `html_table`（比較表） | 報告セグメント |
| オークマ | `xbrl_facts`（**地域**） | `html_table`（細かい地域。period 誤ラベルあり） | **収益認識関係 １**（製品別） |
| ヒューリック | `xbrl_facts`（事業） | `not_found` | 報告セグメント。収益認識１は事業×収益種別クロス |
| キヤノン | fact は設備・人員等のみ（主数値なし） | 表が混線（収益タイミング表が混入） | **US-GAAP 連結注記** 注23。収益は注15 |

追加ソースの例:

- `NotesRevenueRecognitionConsolidatedFinancialStatementsTextBlock`（J-GAAP 収益認識関係）
- `NotesToConsolidatedFinancialStatementsUSGAAPTextBlock` 内の注番号切出し（キヤノン型）

## 学び

1. **比較可能性のボトルネックは会社間ラベル対応**（「プリンティング」≠「デジタルシステム&サービス」）。社内の Markdown→JSON 整形より重い。
2. **`xbrl_facts` の整形は決定的処理で足りる**（期分割・軸ピボット・円→百万円・tag 別名表）。LLM 必須ではない。
3. **LLM が効くのは意味の写像**（軸判定、変則表ヘッダ、共通バケットへの候補付け）。入力帰属が壊れていると救えない（オークマ geography の全表 `前期`、キヤノンの表取り違え）。
4. **全社で事業×地域の両軸がある前提は置けない。** 軸ごとに欠測を許す。
5. **ミソはプロンプト単体ではなく正規化契約**（スキーマ・分母・指標・軸判定）。LLM を使うなら契約を `json_schema` / プロンプトに落とす。使わないなら同じ契約をコードと別名表に落とす。
6. 時系列はスナップショット列でよい（再編の連続補正なし）。

## 正規化契約（草案）

比較用コモンモデルの骨格。実装時に型へ落とす。

```text
BreakdownSnapshot
  code, doc_id, fy_end
  axis: business | geography | product   # 欠ける軸は出さない
  unit: 百万円
  denominator: external_revenue          # 連結外部売上
  rows: [{ id?, label_raw, label_common?, amount, share }]
  source: { kind: html_table | xbrl_facts | revenue_recognition | usgaap_note, ref }
  as_reported: true                      # 組替補正しない
```

契約で固定する方針:

| 項目 | 方針 |
|---|---|
| 行の単位 | 軸ごと（事業 / 地域 / 製品）。報告セグメントが地域なら `geography` 側に載せるか、`axis=geography` の snapshot として出す |
| 売上 | 外部顧客売上を優先（`RevenuesFromExternalCustomers*` 等） |
| 利益 | 比較の第一指標は売上割合。利益割合は任意・定義を明示 |
| 調整・消去 | rows に混ぜず reconciling / denominator 計算に使う |
| 共通バケット | 粗い共通集合（例: 地域は 日本/米州/欧州/アジア/その他）。写せないものは未分類 |
| 業種別スキーマ | 汎用バケットだけに頼らず、同業比較用の対応表を持ちうる |

`segments` / `geography` 生データは raw として残し、比較用は `BreakdownSnapshot` に写す二層が安全。

## 処理分担（構想）

```text
1. ソース発見（決定的）
   TextBlock / dimension fact / 収益認識注記 / US-GAAP 注番号
2. 正規化
   fact ピボット・単位 = コード
   軸判定・表解釈・共通バケット候補 = ルール優先、難所のみ LLM
3. 検証
   行合計≒分母、期・単位の整合、抜き打ち（任意で LLM）
```

LLM は「構造化の本体」ではなく **契約に沿った写像の補助・検証** に置く。

## 今後の検討事項

優先度は未確定。実装前に決めること:

1. **比較用コモンモデルの確定** — 上記草案のフィールド・欠測表現・API 形
2. **軸判定ルール** — 報告セグメント member / 見出しから `business` vs `geography` をどう決めるか
3. **追加ソースの採用範囲** — 収益認識１・US-GAAP 注15/23 を Stage 6 に含めるか、後続か
4. **業種別バケット** — 初回は粗い汎用のみか、食料品/機械/不動産など業種別対応表を持つか
5. **`SegmentExtractor` の前処理欠陥** — period 誤ラベル、US-GAAP 巨大注記未対応、geography への表混入。正規化より先に直す対象の切り分け
6. **永続化** — filing-sections 派生か別テーブルか、cache_version 方針
7. **LLM の位置づけ** — 本番経路に載せるか、候補生成・評価のみか（費用・再現性・監査）
8. **検証セット** — 最低でも事業型・地域型報告セグメント・US-GAAP・収益認識製品別を含む書類セット

非目標（現時点）:

- 過去セグメント定義への遡及組替
- 全企業・全期での事業×地域の完全充足保証
- 生 XBRL を渡して LLM に一発抽出させる経路（現行 HTML/fact 前段を捨てない）

## 関連

- `Sources/BlueTicker/Analysis/SegmentExtractor.swift`
- `Sources/BlueTicker/Constants/Xbrl.swift`（TextBlock / dimension キーワード）
- `docs/xbrl-parsing.md`
- `docs/blt-server-roadmap.md`（Stage 6）
