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
| Phase 4 | ✅ 完了 | HTML パース完了（`Analysis/USGAAPHtmlFields`, `Analysis/IFRSLease`）— スモークテスト knownGap 全廃で 11 社全 OK。分析層ユニットテスト移植完了（13 ファイル・149 テスト）。サービス層テスト移植完了（5 ファイル・34 テスト追加、全 204 テスト合格）。テストを Swift Testing へ移行し macOS / Linux CI ジョブを整備（下記） |
| Phase 5 | ✅ 完了 | `Sources/BlueTicker/MCPServer/`（HTTPApp・ServerSetup・BltServerEntry）、`Sources/BltServer/main.swift`、`Sources/BlueTickerMain/main.swift` |
| Phase A | ✅ 完了 | 年次 analyze 不足フィールド（net_revenue・share_buyback・ROE/ROIC/営業利益ウォーターフォール） |
| Phase B | ✅ 完了 | 半期機能（`--half` フラグ・`HalfYearAnalyzer`・`HalfPeriod` 型・`halfYearTrimPeriods`）＋半期スモークテスト（11 社全 OK） |
| Phase C | ✅ 完了 | セグメント・地域別情報（`Analysis/SegmentExtractor`・`filing --sections segments/geography`・MCP `get_filing_content` 拡充）＋Python ゴールデンパリティテスト（26 書類完全一致） |
| Phase D | 未着手 | Python 全廃（`blue_ticker/` 削除・CI 更新・Homebrew formula 更新） |

### Phase 5 実装範囲（2026-06-12）

Python `blt-server`（FastMCP）を Swift 実装に完全置き換え。`swift build` で `blt-server` バイナリが生成される。

**アーキテクチャ変更:**

- `BlueTickerCore`（ライブラリターゲット）: `Sources/BlueTicker/` 全体（CLI・XBRL・サービス層・MCPサーバー実装を含む共有ライブラリ）
- `BlueTicker`（実行ターゲット）: `Sources/BlueTickerMain/main.swift` のみ（`Task { await Ticker.main() }` + `RunLoop.main.run()`）
- `BltServer`（実行ターゲット）: `Sources/BltServer/main.swift` のみ（`runBltServer(host:port:)` 呼び出し）

**追加ファイル:**

| ファイル | 役割 |
|---|---|
| `Sources/BlueTicker/MCPServer/HTTPApp.swift` | SwiftNIO ベース HTTP サーバー。`StatefulHTTPServerTransport` とセッション管理を実装（swift-sdk conformance server を参考に NIO で再実装） |
| `Sources/BlueTicker/MCPServer/ServerSetup.swift` | `BltServerContext` actor（`EdinetAPIClient`・`CacheManager` 共有）と 6 MCP ツールのハンドラー |
| `Sources/BlueTicker/MCPServer/BltServerEntry.swift` | `public func runBltServer(host:port:)` エントリポイント。`SettingsStore` から API キーを読み出し `HTTPApp` を起動 |
| `Sources/BltServer/main.swift` | `runBltServer()` を呼ぶだけの薄いエントリポイント |
| `Sources/BlueTickerMain/main.swift` | `ticker` CLI の async エントリポイント |

**実装した MCP ツール（6 件）:**

| ツール名 | 機能 |
|---|---|
| `search_companies` | 銘柄コード・企業名で検索 |
| `search_by_sector` | セクターで銘柄一覧を取得 |
| `get_filings` | 有価証券報告書一覧を取得 |
| `get_financial_summary` | 財務指標サマリーを取得（キャッシュ優先） |
| `get_filing_content` | 書類セクション（リスク・MD&A 等）テキストを抽出 |
| `sync_document_list` | EDINET 書類一覧を同期 |

**技術的知見:**

- `JSONRPCMessageKind` は swift-sdk 内で `package enum` 宣言のため外部パッケージから参照不可。`isInitializeRequest(_ data: Data)` として `JSONSerialization` で代替実装
- `AsyncParsableCommand.main()` を `main.swift` から呼ぶには `Task { await Ticker.main() }` + `RunLoop.main.run()` パターンが必要（`@main` なしで async エントリポイントを確立）
- SwiftPM ライブラリターゲットの型はデフォルト `internal`。`Ticker` 構造体のみ `public` 化し、CLIサブコマンド群は `internal` のまま（`App.swift` が同一モジュール内のため）
- `@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)` を `Ticker` に付与することで ArgumentParser のアベイラビリティチェックをパス

### Phase 4 HTML パース実装範囲（2026-06-11）

- `Analysis/USGAAPHtmlFields.swift` — US-GAAP 連結 P/L・BS の iXBRL HTML テーブル抽出。`USGAAP_HTML_*` 仮想タグを FieldSet に注入（Python `usgaap/html_fields.py` 相当）。売上総利益・支払利息の直接 HTML 抽出（`usgaap/gross_profit.py`・`usgaap/interest_expense.py` 相当）。ヘッダー列検出ロジック（Python では 3 モジュールに重複）は `HtmlFinancialTable` に統合
- `Analysis/IFRSLease.swift` — IFRS リース負債（XBRL タグ → リース注記 TextBlock → BS HTML の優先順）、IFRS 財政状態計算書 TextBlock からの IBD 積み上げ
- `Extractors.swift` — IBDExtractor を Python `resolve_ibd` フローへ統一（直接法 → IFRS 集約 → コンポーネント積み上げ → US-GAAP HTML 仮想タグ → TextBlock / zero_debt）、GP・OP・税金・支払利息・PPE・BS に US-GAAP 分岐追加。PPE の IFRS フォールバックを取得原価 + 減価償却累計（負値）に修正
- 検証: スモークテスト 11 社の knownGaps（IFRS 3 社の IBD、US-GAAP 2 社の全 19 フィールド）を全廃して全社 OK

**未移植（Python 側にのみ存在）**: 株主資本等変動計算書 HTML からの自己株式取得（`parse_usgaap_html_equity_cf_fields`）。Swift 側に自己株式取得の出力経路がまだないため、対応する機能追加時に移植する。
（IFRS 注記文章からの支払利息抽出（トヨタ型）と IFRS PL TextBlock からの粗利益抽出はユニットテスト移植時に Swift へ移植済み）

### Phase 4 CI 整備（2026-06-12）

- `ci.yml` に `swift-macos` / `swift-linux`（swift:6.1 コンテナ、timeout 30 分）ジョブを追加（`swift test`、SwiftPM キャッシュ付き）
- Linux ビルド互換対応を実施: `FoundationNetworking`（URLSession）・`FoundationXML`（XMLParser）の条件付き import、`KeystoreError.keychainError(OSStatus)` の `#if canImport(Security)` ガード

#### XCTest → Swift Testing 移行（2026-06-12）

Linux で XCTest のテスト実行が確率的にデッドロックする問題（10 回中 7 回ハング、swift:6.1 / 6.2 とも再現、`--parallel` でも回避不可）を調査した結果、corelibs-xctest の既知の未修正バグ [swiftlang/swift-corelibs-xctest#504](https://github.com/swiftlang/swift-corelibs-xctest/issues/504) と特定（teardown シーケンスの `XCTWaiter.wait()` が ppoll でハング。取得したスタックトレースと一致）。

XCTest を使う限り回避不能のため、テスト全 24 ファイル・204 テストを Swift Testing（`import Testing`、`@Suite` / `@Test` / `#expect`）へ移行した。

- `setUpWithError` / `tearDownWithError` は `init()` / `deinit`（`@Suite final class`）へ変換（4 ファイル）
- `XCTSkip` は `.enabled(if:)` トレイト（XBRLUtilsTests）と早期 return（SmokeTests）へ置き換え
- Swift Testing はスイート間並列実行がデフォルト。テストは temp ディレクトリ分離済みのため競合なし（環境変数を触るのは UserPathsTests の 1 件のみで、対象環境変数を読むテストは他にない）
- 移行後の検証: macOS 全 204 テスト合格、Linux（swift:6.1 コンテナ）10 回連続全合格（ハング解消）

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

**設計判断（2026-06-12）**: EDINET 日付処理は **UTC 固定を最終形**とする。UTC の「今日」は JST 0:00〜8:59 の間まだ前日のため当日提出分の取得が最大 1 日遅れるが、これは許容する（次回実行時に catchup で埋まる）。Asia/Tokyo 固定への一本化は行わない。`CachePruner` / `CacheCommand` 等に残る `Calendar.current` も影響は同じ日単位境界のみのため統一不要。

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
| analyzer / calculator / ROE・ROIC waterfall / output_serializer 等 | Python サービス層・出力層固有（Swift は IndividualAnalyzer / HalfYearAnalyzer に統合済み、スモークテストでカバー） |
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
Phase 4 ✅: HTML パース / テスト移植（全 204 テスト・Swift Testing）/ CI 整備（macOS + Linux）
Phase 5 ✅: MCP サーバー（公式 Swift SDK 0.12.1、Python blt-server 完全置き換え）
Phase A ✅: 年次 analyze 不足フィールド（ウォーターフォール・自己株式取得・IFRS 純収益）
Phase B ✅: 半期機能（--half フラグ・HalfYearAnalyzer）＋半期スモークテスト（11 社全 OK）
Phase C ✅: セグメント・地域別情報（SegmentExtractor・filing/MCP セクション拡充）＋パリティテスト（26 書類）
Phase D  : Python 全廃（blue_ticker/ 削除・CI・Homebrew 更新）
```

Phase 3 完了時点で全コマンドが純 Swift で動作する。Phase 4 で IFRS リース負債・US-GAAP 連結財務諸表が完全対応。Phase 5 で Python blt-server を置き換え。Phase A〜D で残存 Python 機能を移植し Python 依存を完全に解消する。

**利点**:
- 各フェーズ完了時点で動作確認でき、問題を局所化できる
- Phase 3 の XBRL 移植は Swift スモークテスト（11 社）をゴールデンファイルとして常時検証できる
- MCP サーバーは公式 Swift SDK（0.12.1）を用いて Phase 5 で Swift 化できる

---

### 案 C: 完全一括移行

全レイヤーを同時に Swift 化。動作確認できる中間状態がなくリスクが最も高い。

---

---

## Python 全廃フェーズ（Phase A〜D）

Phase 1〜5 で Swift の全コマンドが動作しているが、Python `blue_ticker/` パッケージに残存する機能がある。Phase A〜D で移植を完遂し、Python 依存を完全に解消する。

### 未移植機能の全体像

| 機能 | Python モジュール | 規模 | `ticker analyze` への影響 |
|---|---|---|---|
| IFRS 純収益フォールバック | `analysis/net_revenue.py` | 35行 | IFRS 金融会社の粗利益・営業利益フィールドが欠落 |
| 自己株式取得 | `analysis/share_buyback.py` | 121行 | 「自己株式取得 (百万)」フィールドが常に空 |
| ROE ウォーターフォール | `utils/roe_waterfall.py` | 112行 | ROE前年差・3因子分解フィールドが空 |
| ROIC ウォーターフォール | `utils/roic_waterfall.py` | 213行 | ROIC前年差・2因子分解フィールドが空 |
| 営業利益ウォーターフォール | `utils/operating_profit_change.py` | 482行 | 営業利益前年差・4因子分解フィールドが空 |
| セグメント情報抽出 | `analysis/segment_extractor.py` | 372行 | `ticker filing` でセグメントセクションが取得不可 |

---

### Phase A: 年次 analyze 不足フィールドの補完（2026-06-12 完了）

commit `767a281`。`ticker analyze` の年次出力で空だったフィールドを補完。

| サブフェーズ | 実装内容 |
|---|---|
| A-1 | `NetRevenueExtractor`（`Extractors.swift`）— `NetRevenueIFRS` / `BusinessProfitIFRSSummaryOfBusinessResults` を抽出、Sales/OP が nil の場合フォールバック適用 |
| A-2 | `ShareBuybackExtractor`（`Extractors.swift`）— SS連結 → CF → SS単体の優先順で自己株式取得額を抽出（J-GAAP / IFRS / US-GAAP 対応）。`RawData.Buyback` に格納 |
| A-3 | `applyRoeWaterfallToYears`（`Waterfall.swift`）— DuPont 3因子分解（純利益率差・資産回転率差・レバレッジ差） |
| A-4 | `applyRoicWaterfallToYears`（`Waterfall.swift`）— NOPATマージン差 + 投下資本回転率差の2因子分解 |
| A-5 | `applyOperatingProfitChangeToYears`（`Waterfall.swift`）— 売上差影響・粗利率差影響・販管費差影響の3因子分解 |

その他: `AnalyzeCommand.swift` に「自己株式取得」行を追加。`IndividualAnalyzer` の `operatingMargin` 二重計算バグを修正。

---

### Phase B: 半期機能（`--half` フラグ）（2026-06-12 完了）

`ticker analyze --half` で H1/H2 期間ごとの財務指標を表示する機能。Python の `half_year_data_service.py`（XBRL パス）相当。

#### 実装ファイル

| ファイル | 役割 |
|---|---|
| `Models/HalfYearTypes.swift` | `HalfPeriod`（label/half/fyEnd/yearEntry）Codable struct |
| `Services/HalfYearAnalyzer.swift` | メインサービス（fetchAndBuild・buildH2Entry・キャッシュ）＋ `halfYearTrimPeriods` |
| `CLI/AnalyzeCommand.swift` | `--half` フラグ追加・`printHalfYearTable` |
| `SwiftTests/HalfYearTests.swift` | `halfYearTrimPeriods` を 5 ケースでテスト |
| `SwiftTests/SmokeTests.swift`（更新） | `testHalfSmokeAll` を追加（11 社全 OK） |

#### スモークテスト検証（11 社全 OK）

`SmokeTests.testHalfSmokeAll()` を追加。`tmp_cache/edinet/` の 2Q XBRL（`prepare_half_cache.py` で展開済み）を直接読み、`smoke/smoke_half_expected/*.json` のゴールデンファイルと照合。

| 会計基準 | 検証銘柄 | 結果 |
|---|---|---|
| J-GAAP | 2871 ニチレイ、3490 AZplanning、6103 オークマ、7422 東邦レマック、8306 三菱 UFJ、8316 三井住友 | ✅ 全件 OK |
| IFRS | 2802 味の素、6326 クボタ、7269 スズキ | ✅ 全件 OK |
| US-GAAP | 4901 富士フイルム、7751 キヤノン | ✅ 全件 OK |

半期ゴールデンファイルで `capital_expenditure` / `research_development` / `interest_expense` が null の場合は既存の `compare` ロジック（expected nil → skip）で自動除外されるため、`is_half` フラグの追加は不要。

#### 設計

- **H1** = 2Q 書類を `IndividualAnalyzer.processDocument` で処理した `YearEntry`（XBRL extractor を完全再利用）
- **H2** = FY YearEntry − H1 YearEntry（フロー）、BS は FY 期末スナップショット（Python `_apply_fy_bs_and_roic` と同設計）
  - ROE は H2 純利益 / FY 期末純資産（H1 側は Q2 期末純資産）
- **当期 H1**（FY 未公開）: Q2 書類のみ存在する場合も H1 として追加
- ウォーターフォールは H1 系列・H2 系列を独立して適用（同一 half 間の年次比較）
- **trim ロジック**（`halfYearTrimPeriods`）: 完結 H1+H2 ペア N 件 + 当期 H1（FY 未公開）を返す。Python `_trim_half_year_periods` と同ロジック。
- キャッシュキー: `"half_year_periods_{code}"`、バージョン: `"26.6.0"`

#### 未移植（Python との差分）

Python の `half_year_data_service.py` には外部株価 API 経由の IBD・BS 補完パスがあるが、Swift 版では XBRL のみ（外部 API 連携なし）。

---

### Phase C: セグメント情報（`ticker filing` 拡充）（2026-06-13 完了）

`segment_extractor.py`（372行）を Swift へ移植。`ticker filing --sections segments geography` でセグメント別・地域別情報を取得できる（Python CLI と同じセクション名）。

#### 実装ファイル

| ファイル | 役割 |
|---|---|
| `Analysis/SegmentExtractor.swift` | 抽出本体。XBRL TextBlock HTML テーブル（期間判定付き）優先 → dimension 付き fact フォールバック。SAX ベースの TextBlock 収集（エスケープ済み HTML 対応）と context dimension マップ収集 |
| `Constants/Xbrl.swift` | セグメント・地域別の TextBlock タグ／dimension キーワード定数 |
| `CLI/FilingsCommand.swift` | `--sections` に `segments` / `geography` を追加、セクション名バリデーション（Python 同様に不正名はエラー）、テキスト出力（Markdown 表） |
| `MCPServer/ServerSetup.swift` | `get_filing_content` に `segments` / `geography` を追加（Python MCP とパリティ） |
| `SwiftTests/BlueTickerTests/SegmentExtractorTests.swift` | ユニットテスト（Python `test_segment_extractor.py` 全ケース＋TextBlock/fact 統合テスト）＋パリティテスト |

#### 検証

- **Python ゴールデンパリティ**: `smoke/segment_expected.json`（`smoke/update_segment_fixtures.py` で生成）と `tmp_cache/edinet/` の 26 書類で、Swift 出力が Python 出力と**完全一致**（テーブル Markdown 文字列・period ラベル・facts 全フィールド）。キャッシュ未準備の環境ではスキップ（既存スモークテストと同方式）
- **bs4 セマンティクス再現**: `get_text(strip=True)`（各テキストノードを個別 strip して区切りなし連結）を `bs4Text` として実装し、Markdown のセル文字列・列幅まで Python と一致させた
- facts の出力順は Swift Dictionary の走査順が不定のため (tag, contextRef) でソート（Python は dict 挿入順。JSON 配列の順序は契約に含めない）

---

### Phase D: Python 全廃

Phase A〜C 完了後に実施。

#### 削除対象

| 対象 | 内容 |
|---|---|
| `blue_ticker/` | Python パッケージ本体（91 ファイル、約 17,500行） |
| `tests/` | Python テスト（45 ファイル） |
| `smoke/` | Python スモークスクリプト（7 ファイル） |
| `pyproject.toml`, `poetry.lock`, `uv.lock` | Python プロジェクト設定 |
| `pyrightconfig.json` | Python 型チェッカー設定 |
| `blue_ticker.spec` | PyInstaller 設定 |
| `dist/` | PyInstaller 生成バイナリ |

#### CI 更新（`.github/workflows/`）

- `ci.yml`: Python/Poetry/pyright/pytest ジョブを削除。Swift ジョブ（macOS + Linux）のみに整理
- `release.yml`: PyInstaller ビルドを削除。`swift build -c release` でバイナリ生成に置き換え

#### Homebrew formula 更新（`Formula/`）

- インストール元を Python wheel / PyInstaller バイナリから Swift リリースバイナリに変更
- `brew install` 時の Python ランタイム依存を削除

#### CLAUDE.md 更新

- Python アーキテクチャ依存ルール（`services/` は `blue_ticker.app` をインポートしてはならない、等）を削除
- Swift 向けのアーキテクチャルールに書き換え

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
