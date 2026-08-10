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

## 現行モジュール構成（`Sources/BlueTicker/Analysis/`）

| ファイル | 役割 |
|---|---|
| `FieldParser.swift` | Duration/Instant FieldSet 正規化・連結/非連結コンテキスト判定 |
| `ContextHelpers.swift` | XBRL コンテキスト判定ユーティリティ（連結当期損益判定等） |
| `XBRLTypes.swift` | XBRL 抽出結果の型定義（`XbrlFact` / `XbrlFactIndex`） |
| `Extractors.swift` | 12 エクストラクター（IS/CF/GP/OP/BS/IBD/従業員/税金/支払利息/PPE/Capex/RD）＋銀行固有 |
| `USGAAPHtmlFields.swift` | US-GAAP 連結 P/L・BS の iXBRL HTML テーブル抽出（summary 用仮想タグ） |
| `USGAAPStatementHtml.swift` | US-GAAP 連結 BS/PL/CF/SS の HTML→`StatementLineItem`（Statement 用・決定論。当期優先・キヤノン型 `components`） |
| `IFRSLease.swift` | IFRS リース負債（XBRL タグ → 注記 TextBlock → BS HTML の優先順） |
| `BorrowingsSchedule.swift` | 借入金等明細表からの有利子負債フォールバック抽出 |
| `BreakdownExtractor.swift` | セグメント・地域別情報（TextBlock HTML表 → dimension 付き fact） |
| `XBRLSectionParser.swift` | 有価証券報告書セクション（リスク・MD&A 等）テキスト抽出 |

### breakdowns 事業別・地域別内訳の正規化（`docs/breakdown-normalization-concept.md`）

| ファイル | 役割 |
|---|---|
| `BreakdownNormalizer.swift` | `BreakdownExtractor` の xbrl_facts 結果 → `BreakdownSnapshot`（比較可能な正規化スナップショット） |
| `BusinessBreakdownResolver.swift` | `segments` キーの事業別内訳を、method に応じてどの正規化器（xbrl_facts / LLM 2種）に振り分けるか判定 |
| `GeographyBreakdownResolver.swift` | `geography` キーの地域別内訳を、method に応じて xbrl_facts 正規化 / LLM フォールバックへ振り分け（DevCLI live 分岐と共有） |
| `GeographyBreakdownLLMNormalizer.swift` | geography（地域別情報）の html_table を LLM で `BreakdownSnapshot` へ正規化 |
| `SegmentInfoLLMNormalizer.swift` | `segments` キー自体が html_table を返すケースを LLM で `BreakdownSnapshot`（axis: business）へ正規化 |
| `RevenueRecognitionLLMNormalizer.swift` | オークマ型（segments が実は地域別）の収益認識関係注記を LLM で事業別 `BreakdownSnapshot` へ正規化 |

## 詳細リファレンス

タグ体系・コンテキスト命名規則・会計基準判定ロジック・US-GAAP HTMLパースの仕様は `docs/xbrl-parsing.md` を参照してください。
