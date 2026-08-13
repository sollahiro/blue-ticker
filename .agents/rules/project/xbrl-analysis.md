# XBRL解析モジュールの規約

## 共通ユーティリティの使用

XBRL解析モジュール（`Sources/BlueTicker/Analysis/` 配下）では、以下の共通関数を必ず `XBRLUtils`（`Analysis/XBRLUtils.swift`）から使うこと。各モジュールに同じ実装を書き直してはならない。

| 関数 | 用途 |
|---|---|
| `parseXbrlValue(_:)` | XBRL数値テキスト → `Double?`（nil・空文字は nil） |
| `collectNumericElements(in:allowedTags:)` | XMLファイル → `{localTag: {contextRef: value}}` |
| `collectAllNumericFacts(in:)` | XBRLディレクトリ → ラベル・unitRef 等メタ付き fact インデックス |
| `findXbrlFiles(in:)` | XBRLディレクトリ → インスタンス文書リスト（ラベル等を除外） |
| `parseHtmlNumber(_:)` / `parseHtmlIntAttribute(_:_:)` | HTML表セルの数値・属性の安全なパース |
| `extractIfrsTextblockTable(in:textblockTag:)` | TextBlock 内 HTML テーブル → ラベル別 (当期, 前期) |

## モジュール固有のロジック（共通化しない）

以下は財務諸表の性質が異なるため、`XBRLUtils` には置かない。

| ロジック | 理由 |
|---|---|
| コンテキスト判定（`FieldParser` / `ContextHelpers` の連結・Duration/Instant 判定） | Duration（損益計算書・CF）と Instant（貸借対照表）は別概念 |
| 会計基準判定 | IBD は IFRS/US-GAAP 混在判別など高度なロジックが必要 |

ファイル単位の役割・エクストラクター一覧はコード（`Sources/BlueTicker/Analysis/`）と `docs/xbrl-parsing.md` §4 を正本とする（rules にモジュール表を複製しない）。

## 配信契約のタグ透明性

statement・notes・breakdown の配信契約（`denominatorTag`・`amountTag` 等のタグ系フィールド）には、値の由来を示す実際の XBRL タグ名を可能な限り載せる。`"company_financials"` のような固定文字列プレースホルダーは、実タグが解決できない場合のみのフォールバックとする（`AGENTS.md`「タグ透明性」）。

- 分母・合計値が別ステージ（`company_financials` 等）から渡ってくる場合でも、同一書類の XBRL から独立にタグを再解決できるならそちらを優先する（値の再計算はしない。タグ名の解決だけを行う）
- 実例: `BreakdownNormalizer.normalizeResearchAndDevelopment` のセグメント dimension 無し・全社合計のみのフォールバック（オークマ型）。`RDExtractor.extract` の `RDResult.tag` を呼び出し側（`BltServerFacade.resolveResearchAndDevelopmentBreakdown`）が同一 XBRL から再解決し `totalTag` として渡す。渡せない場合のみ `denominatorTag = "company_financials"` に落ちる

## US-GAAP の二経路（混同禁止）

- Summary / financials 用: `USGAAPHtml` / `USGAAPHtmlFields.swift`
- Statement 本表用: `USGAAPStatementHtml.swift`（決定論・当期優先・キヤノン型 `components`）

同じ「US-GAAP HTML」でも経路が違う。一方の修正を他方に流用しない。

## 詳細リファレンス

タグ体系・コンテキスト命名規則・会計基準判定・US-GAAP HTML・smoke 床は `docs/xbrl-parsing.md`。breakdown 正規化の再発防止ルールは `docs/breakdown-normalization-concept.md`（学び）。
