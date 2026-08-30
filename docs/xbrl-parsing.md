# XBRL 解析契約

会計基準判定・コンテキスト・smoke/golden の床。抽出 how-to（パッケージ構成、エクストラクター、US-GAAP HTML、taxonomy 調査）は `.agents/skills/xbrl-development/SKILL.md`。配信契約は `statement.md` / `breakdown.md`。

## 1. 会計基準の判定

XBRL タグの有無から会計基準を推定します。`FieldParser.swift` の `detectAccountingStandard(_:)` が判定し、各エクストラクターに渡されます。

### 判定ロジック

収集済みタグ名に対する部分文字列マッチで判定します（固定のマーカータグリストは持ちません）。

```
US-GAAP  ← タグ名に "USGAAP" を含むタグが存在 かつ "IFRS" を含むタグが不在
IFRS     ← タグ名に "IFRS" を含むタグが存在
J-GAAP   ← 上記いずれにも該当しない
```

> **注意**: IFRSへ移行済みの企業でも、過去比較データとして `*USGAAP*` タグが残存することがあります。「USGAAPタグが存在してもIFRSタグがあれば IFRS と判定」という優先順位でこれを吸収しています。

---

## 2. コンテキスト体系

XBRL の `contextRef` 属性は財務諸表の種別・期間・連結区分を表します。

### 2.1 コンテキストの分類

| 次元 | 値の例 | 説明 |
|---|---|---|
| **期間種別** | `Duration` / `Instant` | フロー（損益・CF）/ ストック（BS） |
| **連結区分** | （なし）/ `_NonConsolidated` | 連結 / 個別 |
| **当期・前期** | `CurrentYear` / `Prior1Year`, `PriorYear` | 当期・前期 |
| **期の形式** | `FYDuration` / `InterimDuration` / `YTDDuration` | 通期・中間期・累計 |

### 2.2 コンテキストパターン（`Constants/Xbrl.swift`）

**Duration コンテキスト（損益計算書・CF計算書）**

| 定数名 | パターン | 意味 |
|---|---|---|
| `Xbrl.durationContextPatterns` | `CurrentYearDuration` | 連結 当期（年次通期） |
| | `FilingDateDuration` | 連結 当期（提出日基準） |
| | `InterimDuration` | 連結 当期（新形式 中間期） |
| | `CurrentYTDDuration` | 連結 当期（旧形式 中間・四半期累計） |
| `Xbrl.priorDurationContextPatterns` | `Prior1YearDuration` | 連結 前期（年次） |
| | `PriorYearDuration` | 連結 前期（年次 別名） |
| | `Prior1InterimDuration` | 連結 前期（中間期） |
| | `Prior1YTDDuration` | 連結 前期（累計） |

**Instant コンテキスト（貸借対照表）**

| 定数名 | パターン | 意味 |
|---|---|---|
| `Xbrl.instantContextPatterns` | `CurrentYearInstant` | 連結 当期末 |
| | `CurrentQuarterInstant` | 連結 当期末（四半期） |
| | `InterimInstant` | 連結 当期末（中間期） |
| | `FilingDateInstant` | 連結 当期末（提出日基準） |
| `Xbrl.priorInstantContextPatterns` | `Prior1YearInstant` | 連結 前期末 |
| | `PriorYearInstant` | 連結 前期末（別名） |
| | `Prior1QuarterInstant` | 連結 前期末（四半期） |
| | `Prior1InterimInstant` | 連結 前期末（中間期） |

`_NonConsolidated` が含まれるコンテキストは個別財務諸表の値です。

---

## 3. スモークテスト

### 3.1 構成

スモークテストは Swift Testing の一部として実行されます（`swift test`）。期待値は `smoke/` ディレクトリで管理します。

```
smoke/
  smoke_expected/         # 年次期待値 JSON（{code}_{fy_end}.json）
  breakdown_extraction_expected.json   # セグメント・地域別抽出の期待値（有報=通期のみ、書類ID別）
  breakdown_business_oracle_expected.json   # business 軸 smoke 床（xbrl_facts 行 / llm_input 表）
  breakdown_geography_oracle_expected.json  # geography 軸 smoke 床（llm_input 表 / not_found）
  smoke-field-values.md   # フィールド一覧とスモークテストの仕様説明
```

| テスト | 実装 | 照合対象 |
|---|---|---|
| 年次スモーク | `SwiftTests/BlueTickerTests/Spec/Oracle/SmokeTests.swift` `testSmokeAll` | `smoke_expected/` |
| セグメントパリティ | `BreakdownExtractorTests.swift` `SegmentParityTests` | `breakdown_extraction_expected.json`（有報=通期のみ。半期/四半期 q2r は対象外） |
| 内訳(business/geography)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/BreakdownBusinessGeographyOracleFormatTests.swift` | `smoke/breakdown_{business,geography}_oracle_expected.json`（smoke固定11社。`path=xbrl_facts`は決定論行実額、`path=llm_input`はLLM渡す前のtables、`path=not_found`は欠測。LLM正規化後の金額は床に含めない） |
| 内訳(breakdown)実データ回帰 | `SwiftTests/BlueTickerTests/Spec/Oracle/RealXbrlBreakdownTests.swift`（4 `@Suite`: Extraction / EmployeesRD / Resolver / LiveLLM） | `smoke/` 配下は使わない。対象企業は各 `@Test` 関数にハードコード（一覧は同ファイル参照） |
| Statement（本体 BS/PL/CF/SS）実データ回帰 | `SwiftTests/BlueTickerTests/Spec/Oracle/RealXbrlStatementTests.swift` | トヨタ/デンソー/任天堂＋smoke 固定11社のうち US-GAAP2社を除く9社。BS/PL/CF は最上位合計と `smoke_expected` 突合。SS（`changes_in_equity`）は合計列の期首/期末値・order・連結 stray `ProfitLoss` 除外。US-GAAP HTML は富士フイルム/キヤノンに加え野村（連結資本勘定変動表の全行＋`section` 見出し）・オムロン（BS 45行 / PL 21行 / CF 50行 / SS 11行）・小松（BS 39行 / PL 21行 / CF 31行 / SS 12行）・オリックス（BS 39行 / PL 28行 / CF 51行 / SS 18行）。詳細は `docs/statement.md` / `.agents/skills/xbrl-development/SKILL.md`（Spec 層） |
| 注記(statement-notes)実データ回帰 | `SwiftTests/BlueTickerTests/Spec/Oracle/RealXbrlStatementNotesTests.swift`（`golden*` 関数群） | `smoke/` 配下は使わない。対象企業は各 `@Test` 関数にハードコード |
| 注記(borrowings_schedule)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/StatementNotesOracleFormatTests.swift` | `smoke/statement_notes_borrowings_schedule_expected.json`（試作3docID + smoke固定11社。US-GAAP 2社は巨大注記 HTML から内訳。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| 注記(per_share_information)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/PerShareInformationOracleFormatTests.swift` | `smoke/statement_notes_per_share_information_expected.json`（試作2docID + smoke固定11社。US-GAAP BPS含む。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| 注記(issued_shares_and_capital)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/IssuedSharesAndCapitalOracleFormatTests.swift` | `smoke/statement_notes_issued_shares_and_capital_expected.json`（smoke固定11社。`as_of_period_end`＝離散タグ＋`issued_shares_events`＝textblock表。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| 注記(policy_holding_securities)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/PolicyHoldingSecuritiesOracleFormatTests.swift` | `smoke/statement_notes_policy_holding_securities_expected.json`（トヨタ + smoke固定10社。SMFG(8316)は複数docID間でXBRLタグ付けが不完全なため対象外。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| 注記(dividends)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/DividendsOracleFormatTests.swift` | `smoke/statement_notes_dividends_expected.json`（試作2docID + smoke固定11社。決議単位の1株配当・総額。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| 注記(goodwill_and_intangibles)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/GoodwillAndIntangiblesOracleFormatTests.swift` | `smoke/statement_notes_goodwill_and_intangibles_expected.json`（トヨタ + smoke固定11社。IFRS連結2社は種類別正味帳簿価額、スズキと非IFRS8社は `not_found`。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| 注記(property_plant_equipment_schedule)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/PropertyPlantEquipmentScheduleOracleFormatTests.swift` | `smoke/statement_notes_property_plant_equipment_schedule_expected.json`（smoke固定11社。IFRS連結3社は種類別正味帳簿価額、J-GAAP6社は BS 区分タグ当期値ありで `available_via_statement`、US-GAAP2社は `us_gaap_unsupported`。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| 注記(lease_liabilities)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/LeaseLiabilitiesOracleFormatTests.swift` | `smoke/statement_notes_lease_liabilities_expected.json`（smoke固定11社。IFRS連結3社は TextBlock 抽出、BSタグありは `available_via_statement`、借入金等明細表のリース債務は `available_via_notes`、US-GAAPは `us_gaap_unsupported`。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| 注記(sga_expense_breakdown)外出しオラクル | `SwiftTests/BlueTickerTests/Spec/Oracle/SgaExpenseBreakdownOracleFormatTests.swift` | `smoke/statement_notes_sga_expense_breakdown_expected.json`（smoke固定11社。2026-08-27 ユーザー全件目視確認・golden化承認。**未公開・未配線**＝ingest / REST / MCP / job-03 に載せない。連結の `*SGA` / IFRS 販管費費目。発生支出・`AmortizationOfGoodwillSGA` は除外。銀行・クボタは `not_found`、US-GAAPは `us_gaap_unsupported`。深さは S100YFQC / S100YFG2。smoke 分は `SmokeCacheSupport` / `tmp_cache/edinet`） |
| IBD⇔借入金等明細表 横断INVARIANT | `SwiftTests/BlueTickerTests/Spec/Invariant/CrossModuleInvariantTests.swift` | borrowings_schedule 解決 docID は合計一致、field_parser（SOMPO）は不一致自体を固定 |

一部テストは `SwiftTests/.../Spec/{Oracle,Invariant,Contract,Policy}/` に配置（`.agents/skills/xbrl-development/SKILL.md`（Spec 層））。ラベル混在ファイルは元の場所のまま。SwiftPM はサブフォルダを再帰含むため `Package.swift` 変更不要。

**golden回帰とsmokeの役割の違い**: 2つは同じ「実データ回帰」でも軸が異なる。

- **smoke（年次スモーク）**: 会計基準（J-GAAP/IFRS/US-GAAP）・決算期の移行境界・連結有無など、抽出ロジックが分岐する「次元」を意図して選んだ固定企業セット（§3.2）で、既存ロジック全体の最低品質を継続的に守る**床**。対象は基本財務諸表抽出器（BS/PL/CF/GP/IBD）と **`per_share_information`・`issued_shares_and_capital`・`policy_holding_securities`・`dividends`・`borrowings_schedule`・`goodwill_and_intangibles`・`property_plant_equipment_schedule`・`lease_liabilities` note_type**（公開）、および実装済み・未公開の **`sga_expense_breakdown`**、さらに **breakdown の `business` / `geography` 軸**（各 `*OracleFormatTests` + 外出しJSON。`policy_holding_securities` のみ SMFG(8316) を対象外とした固定10社。breakdown の LLM 経路は渡す前の tables を突合し、正規化後金額は床に含めない）。公開 note_type はいずれも床に載済み。`statement`（Statement 本体）は `SmokeTests.swift` 自体は通らないが、同固定セットの golden を `RealXbrlStatementTests.swift` に持つ（BS/PL/CF/SS）
- **golden回帰**（年次スモーク以外）: 個別ロジックの実装・改善時に見つけたエッジケースを持つ企業をその都度追加する**深さ**方向の蓄積型で、対象企業の選定基準は「そのロジック分岐を踏む」ことのみ（次元の網羅性は保証しない）

原則としては note_type の決定論ロジックもこの床でカバーされるべきだが、公開 note_type はいずれも固定11社の外出しオラクル床に載済み。golden側でエッジケースは踏んでいても、smokeが意図的にカバーする次元（銀行・US-GAAP・小規模企業など）での確認を後追いで足す余地は、新規 note_type 追加時に残る。

smoke・goldenの期待値はどちらも言語非依存で残るべき資産（`SPEC_ORACLE`＝L0）にあたる。突合する Swift テストコードは L1（`HARNESS_ONLY`）。テストを移行耐性の観点で層分けする指針は `.agents/skills/xbrl-development/SKILL.md` を参照。

XBRL キャッシュ（`tmp_cache/edinet/`、git 管理外のローカル専用）は `SmokeCacheSupport`（`SwiftTests/BlueTickerTests/SmokeCacheSupport.swift`）が自動管理します。`BLT_EDINET_API_KEY` 環境変数（`blt-server` と共通）が設定されていれば、各テストが対象 docID の不足分を EDINET から自動ダウンロードしてから照合します。未設定でキャッシュも無い docID は個別に SKIP され、テスト全体は失敗しません（Keychain・`ticker config` は不使用）。期待値 JSON は旧 Python 実装の出力をゴールデンとして凍結したもので、更新するにはテストの差分出力を確認し、正しければ上書きします。

`RealXbrlBreakdownTests.swift` はキャッシュ先が `~/.config/blue-ticker/analysis_cache/` と異なる（`smoke/smoke_expected/` の期待値 JSON を経由しない）ため、上記スモーク一式とは別系統として扱ってください。

CI では `swift-macos` / `swift-linux` ジョブの `Test` ステップに repo secret `BLT_EDINET_API_KEY` を渡しており、実データでの照合が毎回走ります（`.github/workflows/ci.yml`）。未設定（fork からの PR 等）では各テストが SKIP し、ジョブは失敗しません。

### 3.2 対象企業

| コード | 企業 | 区分 | 確認内容 |
|---|---|---|---|
| `4901` | 富士フイルム | US-GAAP | US-GAAP制約の確認。連結財務諸表に `ix:nonFraction` がなく、BS/PL/GP/IE を HTML パースで補う経路を検証する |
| `7751` | キヤノン | US-GAAP→IFRS移行境界 | 期末 `2026-12-31` 以前は US-GAAP、以降は IFRS を期待する |
| `8306` | 三菱UFJ | J-GAAP金融 | 銀行系。PL/BS抽出と会計基準判定を通しつつ、GP・有利子負債の未検出を許容する |
| `8316` | 三井住友 | J-GAAP金融 | 銀行系。GP・IBD 未検出を許容する |
| `6103` | オークマ | J-GAAP事業 | 標準的なJ-GAAP事業会社。PL/BS/GP/IBD が通ることを見る |
| `2871` | ニチレイ | J-GAAP事業 | `borrowings_schedule` 抽出で、値なしの区分見出し行（「その他有利子負債」等）が同インデントの部分木を閉じるケースを検証する |
| `6326` | クボタ | IFRS | IFRSタグ体系でPL/BS/GP/IBD抽出が通ることを見る |
| `2802` | 味の素 | IFRS | `GrossProfitIFRS` の直接取得と、IFRS IBD で粒度別タグが一部不足するケースを検証する |
| `7269` | スズキ | J-GAAP→IFRS移行境界 | 期末 `2024-03-31` 以前は J-GAAP、以降は IFRS を期待する |
| `7422` | 東邦レマック | J-GAAP非連結 | 連結財務諸表なし。`has_nonconsolidated_contexts` が False になり、個別財務諸表フォールバックを検証する |
| `3490` | アズ企画設計 | 連結作成開始境界 | 期末 `2024-02-29` 以降から連結作成。`has_nonconsolidated_contexts` が境界前後で変わることを見る |

スモークで必ず確認する抽出器は損益計算書・貸借対照表・売上総利益・有利子負債です。金融会社だけ GP・IBD の未検出を許容します。

---
