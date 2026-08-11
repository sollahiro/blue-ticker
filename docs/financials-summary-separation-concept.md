# financials（Summary）と正本の分離構想

`company_financials`（公開面の呼称は Summary、`docs/feature-tiers.md`）が担ってきた「XBRL 抽出の
なんでも屋」を、正本（statement / notes / breakdown）とそこから組み立てるビュー（Summary）に
分離する構想。実装決定・コード変更は未着手（本ドキュメントは設計合意のみ）。

## 用語

- **financials**: 実装名（`FinancialsResponse` / `company_financials` / `companyFinancialsCacheVersion`
  / REST パス `.../financials`）。リネームされていない。
- **Summary**: 公開面の呼称（MCP ツール名 `get_financial_summary`、PR #171 でリネーム）。
- 本ドキュメントでは同じものとして `financials（Summary）` と併記する。

## 現状の実態（2026-08-11 時点、コード確認済み）

### financials（Summary）の中身

`FinancialsYear`（`Sources/BlueTicker/Models/FinancialsContract.swift`）は1構造体に約70フィールド。

| 分類 | 例 |
|---|---|
| FS 水準値 | `sales` / `operatingProfit` / `totalAssets` / `cfo` など |
| note 相当値 | `eps` / `issuedShares` / `employees` / `rd` |
| Waterfall 専用（分析） | `roicDelta` / `ccc` / `dso`/`dio`/`dpo` / `businessProfitChange` 等 |

配信は既に投影レベルで分離済み: `summaryJsonObject()` が `analysisOnlyKeys`（22フィールド）を除いて
返し、`analysisJsonObject()`（Waterfall 応答）が全フィールド＋前年差を返す。**格納（`fin-vN` 1本）は
同居、配信は分離**というのが正確な現状。

### notes は既に正本化済み

`StatementNotesContract.swift` の9 note_type は全件、financials を読まず XBRL から自己完結で
決定論抽出している（grep 確認済み、参照箇所なし）。`research_and_development` は
**本日（2026-08-11）** note_type から廃止し breakdown 軸へ統合された（`bcfcf61` / `4f6a6c0` /
`d5363cf`）。つまり「notes が financials の passthrough」という問題は、この草案が書かれた時点の
問題意識としては正しかったが、**現時点では解消済み**。

### breakdown は逆方向に financials へ依存している

`BreakdownIngest.swift` の `employeesForDocFromFinancials` / `rdForDocFromFinancials` /
（`salesForDoc` 経由の）business・geography 軸は、分母（全社合計）を `company_financials` から
取得する。目指す形（notes/breakdown が正本、Summary はそれを写すビュー）とは**逆方向の依存**が
現行実装。

例外は research_and_development 軸のみ: 値は financials 由来のままだが、タグ名は同一 XBRL から
独立再解決している（`resolveResearchAndDevelopmentBreakdown` の `totalTag`、本日実装）。
`AGENTS.md`「タグ透明性」原則の先行適用例。

### 二重計算: EPS・発行済株式

`per_share_information` note（`StatementNotesResolver.resolvePerShareInformation`）と
financials 本体（`IndividualAnalyzer.swift`）は、**どちらも独立に `PerShareExtractor.extract` を
呼んでいる**。ロジックは共有関数なので実装の重複ではないが、

- XBRL 解析・計算が2回走る（ingest コスト2倍）
- cache_version のライフサイクルが別（`fin-v5` と `notes-eps-v2`）。抽出ロジック修正時に片方だけ
  バンプし忘れるドリフトリスクがある
- 値が一致することを保証するテストが無い

`issued_shares_and_capital` note も同型（`financials.issuedShares` と `IssuedSharesAsOfPayload.issuedShares`）。

**EPS は PL 本表には基本的に載らない**（`Xbrl.swift:86-96` のコメントで実データ確認済み: J-GAAP・
US-GAAP は本表に離散数値タグが無く「業績等の概要（SummaryOfBusinessResults）」が唯一の数値源。
IFRS のみ本表に直接タグを持つ）。`per_share_information` note は EPS・潜在株式調整後 EPS・BPS の
3値をカバレッジ実測済み（EPS 144/144、BPS 142/144、潜在株式調整後EPS 65/144）で、financials の
`eps` 1値より完全。→ **正本は「PL」ではなく「`per_share_information` note」**。

## 設計方針（確定）

| 項目 | 方針 |
|---|---|
| Summary の格納 | `company_financials` は維持（materialized snapshot）。Fly read-only・Waterfall
  多年次・低レイテンシのため、read 時 join 方式（案B）は採らない |
| `fin-vN` | 存続。意味は「組立＋未分離抽出」に限定していく。床・`blueTickerVersion` 非連動は現状踏襲 |
| 新規指標 | financials に足さず、まず notes / breakdown / statement 正本へ置く |
| 二重物の解消 | 見つかり次第、正本を1つに決めて financials 側をパススルー化する（下記が最初の2件） |

## アクション（今回合意・優先度順）

### 1. EPS: `per_share_information` note を正本にする

- 正本: `StatementNotesResolver.resolvePerShareInformation`（変更なし、既に検証済み）
- financials 側: `IndividualAnalyzer` が独自に `PerShareExtractor` を呼ぶのをやめ、
  `per_share_information` note の `items`（`tag == "eps"`）から値を読むパススルーに変更
- **実装時の未決事項（要検討、今回は決めない）**: 既定 `--stages` 実行順は
  `financials → filing-sections → breakdowns → statements → notes`（`FactsIngest.swift`）。
  **notes は financials より後に走る**ため、単純に「DB に格納済みの notes 行を読む」実装だと
  初回 ingest で値が引けない。選択肢は (a) financials 用にだけ notes を先出しする順序変更、
  (b) ストレージ越しの参照ではなく同一 ingest パス内で resolver 関数を直接呼び共有する
  （2テーブル間の read 依存を作らない）。どちらを採るかは実装着手時に確認する
- 公開契約: Summary の `eps` フィールドの形は変えない（BPS・潜在株式調整後EPSを Summary に
  追加するかは別途・非スコープ）

### 2. 発行済株式: `issued_shares_and_capital` note を正本にする

- 同型のパターン。`financials.issuedShares` を `IssuedSharesAsOfPayload.issuedShares` からの
  パススルーに変更
- 実装時の未決事項はアクション1と同じ（ingest 順序 or 関数共有）

## 将来ステップ（今回のスコープ外・非ゴール）

- **breakdown の financials 依存解消**: employees / research_and_development / business /
  geography 軸の分母を、financials 経由ではなく正本（notes 拡張または独立抽出）から取るように
  設計を変える。方針としては合意済み（ゆくゆくは financials 経路を外す）が、
  - employees に対応する note_type が現状存在しない（新設が必要か、他の正本を充てるかは未決）
  - business/geography の連結売上分母をどの正本に寄せるかも未決
  正本側の設計が固まってから着手する。今回のロードマップには実装ステップを含めない
- Summary 固有計算（CCC・ROIC 部品等）の格納単位分離（`source_versions` 方式等）
- Summary REST/MCP の削除、notes/breakdown エンドポイント統合
- 公開応答への `fin-vN` 露出

## 関連ドキュメント

- `docs/breakdown-normalization-concept.md` — breakdowns 正規化構想（今後の検討事項に
  breakdown の financials 依存解消を追記予定）
- `docs/statement-normalization-concept.md` — statements / statement-notes 設計
- `.agents/rules/project/versioning.md` — cache_version バンプ規則
- `AGENTS.md`「タグ透明性」— R&D breakdown の `totalTag` 独立再解決が先行実装例
