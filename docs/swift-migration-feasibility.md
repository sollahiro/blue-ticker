# Swift 移行 実現可能性レポート

作成日: 2026-06-09

## 対象プラットフォーム

| プラットフォーム | 方針 |
|---|---|
| macOS | 主ターゲット |
| Linux | 互換維持（現状と同等の動作を保つ） |
| Windows | **対象外** |

Linux では現状でも Keystore がシステムキーチェーンに対応していない（`secrets.json` フォールバック）が、その動作は Swift でも同等に再現できる。

## 現状サマリー

| 項目 | 値 |
|---|---|
| Python ファイル数 | 91 ファイル |
| 総行数 | 約 17,500 行 |
| 外部依存 | aiohttp、beautifulsoup4（最小構成） |
| Python バージョン | 3.11+ |
| 非同期モデル | asyncio + aiohttp（semaphore によるレート制限） |

---

## コンポーネント別移行難易度

### 1. CLI レイヤー (`app/cli/`) — 難易度: 低

| Python | Swift 対応策 |
|---|---|
| `argparse` | [swift-argument-parser](https://github.com/apple/swift-argument-parser)（Apple 公式） |
| `asyncio.run(...)` | `Task.detached { }` + `RunLoop.main.run()` |
| `print` / テーブル出力 | `Swift.print` / `String` フォーマット |

コマンド体系（search / analyze / config / cache / filings / filing / sector）は `AsyncParsableCommand` で直接対応できる。

---

### 2. HTTP クライアント (`api/edinet_client.py`) — 難易度: 低〜中

| Python | Swift 対応策 |
|---|---|
| `aiohttp.ClientSession` | `URLSession` + `async/await`（Swift 5.5+） |
| セマフォ（10 並列） | `AsyncSemaphore`（`swift-async-algorithms` 提供）または actor による逐次化 |
| SSL 設定 | `URLSession.Configuration.urlCache` / `URLCredentialStorage` |
| ZIP ダウンロード | `URLSession.downloadTask` + `FileManager` 解凍（`ZipArchive` or `Process`） |

ZIP 展開は標準ライブラリに含まれないため、[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 等の追加が必要。これが外部依存を増やす唯一の箇所。

---

### 3. XBRL 解析 (`analysis/`) — 難易度: 高（最大の課題）

91 ファイル中 26 ファイルが analysis/ に集中しており、プロジェクト最大の複雑箇所。

#### 3a. XML パース

| Python (BeautifulSoup4) | Swift |
|---|---|
| `soup.find_all(...)` の動的タグ検索 | `Foundation.XMLParser`（SAX 式、冗長）or `libxml2` wapper |
| `tag.get("contextRef")` | `XMLElement` の属性アクセス |
| `nil` セーフなパース | `Optional` チェーンで同等 |

BeautifulSoup4 の柔軟な検索は `Foundation.XMLParser`（SAX）では再現難易度が高い。DOM スタイルが欲しければ [SwiftSoup](https://github.com/scinfu/SwiftSoup) が実質唯一の選択肢（HTML パース用途でも利用可）。

**外部依存追加要否: SwiftSoup 必須**

#### 3b. コンテキスト判定ロジック

`_is_consolidated_duration`、`_detect_accounting_standard` など Python の動的ディスパッチに依存した箇所が多い。Swift では `enum` + `switch` で表現できるが、型の堅牢さから実装量が 1.5〜2 倍になる。

#### 3c. US-GAAP HTML テーブルパース (`analysis/usgaap/`)

`colspan` / `rowspan` を処理するファジーマッチングロジックは Python 固有の動的処理に依存している。SwiftSoup でほぼ再現できるが、テーブル構造の解析ロジックを 1 から書き直す必要がある。

---

### 4. インフラ・キーストア (`infrastructure/`) — 難易度: 低

現在の `keystore.py` は macOS と非 macOS で実装を分岐している。

| Python (現状) | Swift での対応 |
|---|---|
| macOS: `subprocess.run(["security", ...])` | macOS: `Security.framework` を直接呼び出し（subprocess 不要、より堅牢） |
| Linux: `secrets.json` + `chmod 0600` | Linux: `FileManager` + `try fileManager.setAttributes([.posixPermissions: 0o600], ...)` |

Linux では現状のファイルベース実装と **機能的に同等**。むしろ macOS 側は subprocess 経由ではなく `Security.framework` を直接使えるため改善になる。

`user_paths.py`（XDG / `~/.config` など）は `FileManager.urls(for:in:)` + `#if os(macOS)` / `#if os(Linux)` の条件コンパイルで同等に実装できる。

---

### 5. キャッシング (`utils/cache.py`, `api/edinet_cache_store.py`) — 難易度: 中

| Python | Swift |
|---|---|
| `TypedDict` + JSON ファイル | `Codable` struct + `JSONEncoder/Decoder` |
| ファイル I/O | `FileManager` + `Data` |
| `asyncio.Lock` | `actor` による排他制御 |
| TTL チェック | `Date` + `TimeInterval` |
| `_cache_version` 埋め込み | `Codable` の `CodingKeys` で実装 |

**構造的に最も移行しやすい層**。`CacheManager` クラスはほぼ 1:1 で Swift actor に変換できる。

---

### 6. 型定義 (`utils/metrics_types.py` など) — 難易度: 低

| Python | Swift |
|---|---|
| `TypedDict` | `struct` + `Codable` |
| `total=False` の TypedDict | `struct` + Optional フィールド |
| `tuple[bool, str \| None]` | `(Bool, String?)` または `Result<T, E>` |

Python の `total=False` による段階的辞書組み立てパターンは、Swift では `var` プロパティが Optional な struct で自然に表現できる。

---

### 7. MCP サーバー (`mcp_server/`) — 難易度: 中

**ローカル MCP は実装しない。** AI エージェントは Skills 経由で CLI を直接操作する。  
MCP サーバーは **リモート（HTTP transport）専用** として実装する。

現在 `FastMCP`（Python）でリモート MCP を提供中。Swift 向けの公式 SDK が利用可能になったため、Phase 5 で Python `blt-server` を Swift 実装に置き換える。

- 公式 Swift MCP SDK: [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)（最新リリース 0.12.1 / 2026-05-07）
- MCP spec 2025-11-25 準拠、HTTP transport（Streamable HTTP）対応

Python `FastMCP` との API 差分・エンドポイント互換性の検証が必要。

---

### 8. テスト (`tests/` 46 ファイル) — 難易度: 中

| Python | Swift |
|---|---|
| `pytest` + `pytest-asyncio` | XCTest + `async/await` テスト（Swift 5.5+） |
| フィクスチャ XML ファイル | そのまま再利用可（.xml は資産として維持） |
| `pyright` | Swift コンパイラの型チェック（より厳格） |
| Smoke テスト | XCTest の統合テストターゲットで対応 |

XML フィクスチャファイルは Swift プロジェクトにそのまま移植できる。テストロジックは XCTest で書き直しが必要。

---

## 移行が有利になる点

1. **型安全性の向上**: Python の `TypedDict` + pyright より Swift コンパイラの静的解析が強力。ランタイムエラーをコンパイル時に検出できる。
2. **バイナリ配布**: Python ランタイム不要の単一バイナリを `swift build -c release` で生成できる。Homebrew 配布が簡素化される。
3. **メモリ効率**: ARC（自動参照カウント）による予測可能なメモリ使用量。大量 XBRL 処理時のピークメモリを抑制できる可能性がある。
4. **起動速度**: CLI ツールとして Python インタープリタ起動オーバーヘッドがなくなる。

---

## 移行のリスクと課題

### リスク A（高）: XBRL 解析の複雑さ

26 モジュール・複数の会計基準・コンテキスト解決ロジック・フォールバックチェーンを正確に移植するには、既存の Python テストをゴールデンファイルとして使いながら慎重に進める必要がある。バグが混入しても財務数値の誤りは検出しにくい。

### リスク B（中）: 外部依存の増加

現在 Python は `aiohttp` + `beautifulsoup4` の 2 パッケージのみ。Swift では最低限以下が追加になる:

| パッケージ | 用途 | 代替 |
|---|---|---|
| swift-argument-parser | CLI | 必須（Apple 公式） |
| ZIPFoundation | ZIP 展開 | `Process` で `unzip` 呼び出し（回避可） |
| SwiftSoup | HTML/XML 解析 | Foundation.XMLParser（SAX 式、実装量大） |

`ZIPFoundation` と `SwiftSoup` は実績のある OSS だが、依存ポリシー（`dependencies.md`）との整合を確認する必要がある。

### リスク C（低〜中）: MCP サーバー

公式 Swift MCP SDK（0.12.1）が利用可能になったため、移行の不確実性は大幅に低下した。ローカル MCP は実装しない（AI エージェントは Skills 経由で CLI 操作）ため、HTTP transport のリモートサーバー実装のみが対象。Python `FastMCP` との API 差分の検証は必要。

### リスク D（低）: Linux ツールチェーン

Swift の Linux サポート（swift-corelibs-foundation）は CLI ツールとして必要な機能を網羅している。

- `URLSession`・`FileManager`・`JSONEncoder`・`Process`・`XMLParser` はすべて Linux で動作
- GitHub Actions に公式 Swift セットアップアクションあり（CI/CD 再構築は軽微）
- `Security.framework`（Keychain）は macOS 専用だが、Linux では `FileManager` + `chmod` フォールバックで現状と同等

Linux 固有の注意点として、`#if os(Linux)` の条件コンパイルが数箇所必要になるが、既存 Python コードの `platform.system()` 分岐と対応関係は明確で複雑でない。

---

## 実装進捗（2026-06-12 時点）

| フェーズ | 状態 | 実装済みファイル |
|---|---|---|
| Phase 1 | ✅ 完了 | `App.swift`, `CLI/` 全コマンド骨格, `Infrastructure/Keystore`, `Infrastructure/Settings`, `Infrastructure/UserPaths`, `API/EdinetAPIClient`, `API/EdinetCacheStore`, `Utils/CacheManager`, `Utils/CachePaths`, `Utils/FiscalYear`, `Utils/Converters`, `Models/`, `Constants/`, `Services/MasterDataManager`, `Services/CompanyInfoService` |
| Phase 2 | ✅ 完了 | `Services/EdinetDiscovery`, `Services/FilingService`, `Services/CachePruner`, `CLI/FilingsCommand`（filings 一覧）, `CLI/CacheCommand`（clean オプション拡充） |
| Phase 3 | ✅ 完了 | `Analysis/FieldParser`, `Analysis/Extractors`（12 エクストラクター＋銀行固有）, `Services/IndividualAnalyzer`, `CLI/AnalyzeCommand`, `CLI/FilingCommand`（XBRL セクション抽出）, `SwiftTests/SmokeTests`（11 社全 OK） |
| Phase 4 | 🔲 一部完了 | HTML パース完了（`Analysis/USGAAPHtmlFields`, `Analysis/IFRSLease`）— スモークテスト knownGap 全廃で 11 社全 OK。分析層ユニットテスト移植完了（13 ファイル・149 テスト）。サービス層テスト移植完了（5 ファイル・34 テスト追加、全 204 テスト合格）。残: CI 整備 |
| Phase 5 | 未着手 | MCP サーバー（`modelcontextprotocol/swift-sdk` 0.12.1）|

### Phase 4 HTML パース実装範囲（2026-06-11）

- `Analysis/USGAAPHtmlFields.swift` — US-GAAP 連結 P/L・BS の iXBRL HTML テーブル抽出。`USGAAP_HTML_*` 仮想タグを FieldSet に注入（Python `usgaap/html_fields.py` 相当）。売上総利益・支払利息の直接 HTML 抽出（`usgaap/gross_profit.py`・`usgaap/interest_expense.py` 相当）。ヘッダー列検出ロジック（Python では 3 モジュールに重複）は `HtmlFinancialTable` に統合
- `Analysis/IFRSLease.swift` — IFRS リース負債（XBRL タグ → リース注記 TextBlock → BS HTML の優先順）、IFRS 財政状態計算書 TextBlock からの IBD 積み上げ
- `Extractors.swift` — IBDExtractor を Python `resolve_ibd` フローへ統一（直接法 → IFRS 集約 → コンポーネント積み上げ → US-GAAP HTML 仮想タグ → TextBlock / zero_debt）、GP・OP・税金・支払利息・PPE・BS に US-GAAP 分岐追加。PPE の IFRS フォールバックを取得原価 + 減価償却累計（負値）に修正
- 検証: スモークテスト 11 社の knownGaps（IFRS 3 社の IBD、US-GAAP 2 社の全 19 フィールド）を全廃して全社 OK

**未移植（Python 側にのみ存在）**: 株主資本等変動計算書 HTML からの自己株式取得（`parse_usgaap_html_equity_cf_fields`）。Swift 側に自己株式取得の出力経路がまだないため、対応する機能追加時に移植する。
（IFRS 注記文章からの支払利息抽出（トヨタ型）と IFRS PL TextBlock からの粗利益抽出はユニットテスト移植時に Swift へ移植済み）

### Phase 4 サービス層テスト移植（2026-06-12）

Python サービス層テスト 5 ファイルを XCTest へ移植（共通ヘルパー `ServiceTestSupport.swift`、計 34 テスト）:

| Python テスト | Swift テスト | 補足 |
|---|---|---|
| `test_edinet_cache_store.py` | `EdinetCacheStoreTests` | TTL は mtime 操作で再現。`max_xbrl_bytes` の途中書き換えは同一ディレクトリを指す別インスタンスで代替 |
| `test_cache_pruner.py` | `CachePrunerTests` | prune 系のみ。stats / audit は Swift 未実装のため対象外 |
| `test_edinet_client.py` | `EdinetClientTests` | キャッシュシード方式（下記） |
| `test_edinet_discovery.py` | `EdinetDiscoveryTests` | キャッシュシード方式（下記） |
| `test_user_paths.py` | `UserPathsTests` | 環境変数テストのみ。SettingsStore の Keychain テストは Keystore 静的依存のため対象外 |

**キャッシュシード方式**: Python は monkeypatch でフェッチ関数をモックするが、Swift の `EdinetAPIClient` は actor（継承不可）のため、検索キャッシュ・年次インデックスを一時ディレクトリへ事前に書き込み、API キー未設定で HTTP を即時失敗させる。これによりキャッシュ優先・stale フォールバックの実コードパスをネットワークなしで検証できる。

**移植過程で発見・修正したパリティバグ**: `EdinetAPIClient` が `Calendar.current`（ローカル TZ）と UTC の ISO フォーマッタを混在させており、JST 環境では年次インデックスの日付ラベルが Python 版と 1 日ずれていた（Python と共有するキャッシュの整合性に影響）。UTC カレンダーに統一して修正済み。

**移植対象外（Swift に該当機構がないもの）**: `test_edinet_doc_filter` / `test_edinet_docs_cache_upgrade` / `test_edinet_fetcher_boundary` / `test_data_service` / `test_dup_deduplication`（Python 側のサーバー・DataService・doc_filter モジュール固有）、`file_lock` の待機通知テスト（time モック前提）、CA バンドル解決テスト（URLSession は OS に委譲）。

### Phase 4 ユニットテスト移植（2026-06-12）

Python 分析層テスト 13 ファイルを XCTest へ移植（`SwiftTests/BlueTickerTests/`、共通ヘルパー `XBRLTestSupport.swift`）。移植過程で判明した Swift 抽出器のパリティギャップも修正:

- GrossProfit: 解決順序を Python 準拠化（direct → 銀行業務粗利益 → 営業総利益 → computed）、COGS タグ欠落時の 0 扱い、IFRS PL TextBlock フォールバック追加
- OperatingProfit: GP−SGA computed パス追加、IFRS 企業での経常利益フォールバック抑止
- TaxExpense: method フィールド・not_found 判定追加
- InterestExpense: IFRS 注記テキストからの抽出（トヨタ型）追加

**移植対象外としたもの**:

| 対象 | 理由 |
|---|---|
| net_revenue / share_buyback / order_book / bank_financials / shareholder_metrics / segment_extractor 等のテスト | 対応モジュールが Swift 未実装（analyze 出力に未統合） |
| analyzer / calculator / ROE・ROIC waterfall / half_year / output_serializer 等 | Python サービス層・出力層固有（Swift は IndividualAnalyzer に統合済み、スモークテストでカバー） |
| EDINET API / discovery / cache 系 | サービス層テストとして移植済み（上記 2026-06-12） |
| CLI 統合・dependency_rules | dependency_rules は Python の import 規約固有。CLI 統合は Swift スモークテストでカバー |
| components のタグ名検証・税金の prior 系フィールド | Swift の結果構造体が未保持（必要になった時点で追加） |

### Phase 3 実装範囲と検証結果

**実装済みコンポーネント（2026-06-10）:**

- `Analysis/FieldParser.swift` — Duration/Instant FieldSet 正規化、連結/非連結コンテキスト判定
- `Analysis/Extractors.swift` — 12 エクストラクター（IS, CF, GrossProfit, OperatingProfit, BS, IBD, Employees, TaxExpense, InterestExpense, PPE, Capex, RD）＋銀行固有（連結業務粗利益・銀行 IBD コンポーネント）
- `Services/IndividualAnalyzer.swift` — EDINET 書類インデックス → 並列 XBRL ダウンロード → メトリクス組み立て → キャッシュ
- `CLI/AnalyzeCommand.swift` — テーブル表示・JSON 出力
- `CLI/FilingCommand.swift` — XBRL セクション（リスク・MD&A 等）テキスト抽出
- `SwiftTests/BlueTickerTests/SmokeTests.swift` — 11 社全指標をキャッシュ済み XBRL から直接検証（Keychain 不要）

**Python 版との比較検証結果（Swift スモークテスト 11 社、全件 OK）:**

| 会計基準 | 代表銘柄 | 主要指標一致 | 備考 |
|---|---|---|---|
| J-GAAP | 6103 オークマ, 2871 ニチレイ, 3490 AZplanning, 7422 東邦レマック | ✅ 完全一致 | 全指標一致 |
| J-GAAP（銀行） | 8306 三菱 UFJ, 8316 三井住友 | ✅ 完全一致 | 連結業務粗利益・銀行 IBD コンポーネント積み上げ実装済み |
| IFRS | 2802 味の素, 6326 クボタ, 7269 スズキ | ✅ ほぼ一致 | IBD はリース負債分のみ差異（knownGap） |
| US-GAAP | 4901 富士フイルム, 7751 キヤノン | ⚠️ 部分的 | HTML テーブルパースなしで基本指標のみ（主要財務項目は knownGap） |

**既知の未実装事項（Phase 4 スコープ）:**

- **IFRS リース負債**: XBRL 数値タグが連結財務諸表に存在しないことを確認済み（3 社調査: 味の素・クボタ・スズキ）。`LeaseObligationsCL`/`NCL` は個別財務諸表にのみ存在し、連結値は `NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock` の HTML テーブル内にのみ埋め込まれている。Python 抽出メソッド `field_parser+lease_textblock` がこの構造を示す。
- **US-GAAP 連結 P/L・BS**: 連結値が HTML テーブル内にあり、XBRL タグ単独では取得不可（富士フイルム・キヤノン）。

Swift スモークテスト（11 社）は全て `OK` で合格。

### Phase 2 実装範囲の補足

当初の Phase 2 想定（「データ集計・ウォーターフォール計算」）は XBRL 依存が判明したため Phase 3 へ移動。  
実際に Phase 2 で実装したのは XBRL 不要のサービス層のみ:

- `EdinetDiscovery`: 書類インデックス構築（`edinet_discovery.py` 相当）
- `FilingService`: 書類一覧検索（`filing_service.py` の EDINET 検索部分）
- `CachePruner`: キャッシュ整理（`cache_pruner.py` 相当）

---

## 移行コスト見積もり

| フェーズ | 内容 | 概算工数 |
|---|---|---|
| Phase 1 | プロジェクト設定・CLI・インフラ（Keystore macOS/Linux 分岐含む）・キャッシュ | 1〜2 週 |
| Phase 2 | HTTP クライアント（EDINET API）・サービス層・データ集計・ウォーターフォール計算 | 2〜3 週 |
| Phase 3 | XBRL 解析 25 モジュール（analysis/）・AnalyzeCommand・FilingCommand | 4〜6 週 |
| Phase 4 | テスト移植・Smoke テスト検証（macOS + Linux CI） | 2〜3 週 |
| Phase 5 | リモート MCP サーバー（HTTP transport・公式 Swift SDK、Python blt-server を置き換え、remote CLI も MCP 統一） | 1〜2 週 |
| **合計** | MCP 含む全 Phase | **11〜17 週** |

---

## 移行の目的

本移行で達成したい目的は以下の 3 点。これらはすべて **XBRL 解析を含む完全移行**を前提とする。

| 目的 | XBRL を Python に残した場合 |
|---|---|
| 起動速度・実行パフォーマンス | `analyze` の大半が Python サブプロセス経由のまま改善しない |
| 型安全性・保守性の向上 | 最も複雑な XBRL 層が動的な Python のまま残る |
| Python 依存をなくしたい | ランタイムが引き続き必要なため達成できない |

「XBRL 解析（Phase 3）を省略して Python に残す」構成は永続的な目標には合わない。Phase 1〜2 は XBRL 移植前のアーキテクチャ検証ステップとして意味を持つが、最終的には Phase 3 まで完遂する前提で進める。

---

## 移行アプローチ

### 案 A: Swift CLI ラッパー＋Python コア維持（除外）

**問題点**:
- Swift ↔ Python の境界（subprocess または Python C API）がそれ自体の複雑さを生む
- Python ランタイムを同梱しない限り単一バイナリにならない
- 型安全性・パフォーマンスなど移行のメリットがコア層に及ばない

---

### 案 B: 段階移行（推奨）

リスクの低いレイヤーから順に Swift 化し、フェーズごとに動作確認しながら進める。

```
Phase 1 ✅: CLI + インフラ（Keystore macOS/Linux）+ キャッシュ
Phase 2 ✅: EDINET API + 書類検索サービス + キャッシュ整理
Phase 3 ✅: XBRL 解析（12 エクストラクター＋銀行固有）+ Swift スモークテスト（11 社全 OK）
Phase 4 🔲: HTML パース ✅ / 分析層テスト移植 ✅ / サービス層テスト移植 ✅（全 204 テスト）/ 残: CI 整備
Phase 5   : MCP サーバー（公式 Swift SDK 0.12.1）
```

Phase 3 完了時点で全コマンド（`ticker search`・`ticker filings`・`ticker cache`・`ticker config`・`ticker analyze`・`ticker filing`）が純 Swift で動作する。  
Phase 4 の HTML パース完了後に IFRS リース負債・US-GAAP 連結財務諸表が完全対応となる。

**利点**:
- 各フェーズ完了時点で動作確認でき、問題を局所化できる
- Phase 3 の XBRL 移植は Swift スモークテスト（11 社）をゴールデンファイルとして常時検証できる
- MCP サーバーは公式 Swift SDK（0.12.1）を用いて Phase 5 で Swift 化できる

---

### 案 C: 完全一括移行

全レイヤーを同時に Swift 化。動作確認できる中間状態がなくリスクが最も高い。

---

## 結論と推奨

**実現可能性: 中〜高**（ただし工数・リスクは大きい）

| 評価項目 | 評価 |
|---|---|
| CLI・HTTP・キャッシュ・インフラ層 | 移行容易（Swift の強みが活きる） |
| XBRL 解析層 | 移行可能だが最大リスク（慎重な移植とテスト検証が必須） |
| MCP サーバー | 公式 Swift SDK（0.12.1）利用可能、FastMCP との差分確認が必要 |
| 総合工数 | MCP 含む全 Phase で 11〜17 週 |

**推奨: 案 B（段階移行）**。目的（パフォーマンス・型安全性・Python 依存解消）をすべて達成するには Phase 3 まで完遂する必要があり、段階移行はそのリスクを分散する手段として機能する。XBRL 解析の移植は既存 Smoke テスト（10 社）をゴールデンファイルとして用い、モジュール単位で Python 版の出力と一致させながら進める。MCP サーバーは公式 Swift SDK（0.12.1）が利用可能になったため Phase 5 として全体計画に組み込める。
