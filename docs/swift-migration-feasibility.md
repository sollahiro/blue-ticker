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

### 7. MCP サーバー (`mcp_server/`) — 難易度: 高

現在 `FastMCP`（Python）を使用。Swift 向けの MCP SDK は 2026 年 6 月時点で **非公式実装のみ**。

- 公式 Swift MCP SDK: 未存在（未リリース）
- 非公式: [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)（コミュニティ製、安定性不明）

MCP サーバー機能は移行対象から**一時的に除外**するか、Python サイドカーとして残すことを推奨。

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

### リスク C（高）: MCP サーバー

公式 Swift MCP SDK が未存在のため、MCP サーバー機能（`blt-server`）の移行は現時点で不確実。

### リスク D（低）: Linux ツールチェーン

Swift の Linux サポート（swift-corelibs-foundation）は CLI ツールとして必要な機能を網羅している。

- `URLSession`・`FileManager`・`JSONEncoder`・`Process`・`XMLParser` はすべて Linux で動作
- GitHub Actions に公式 Swift セットアップアクションあり（CI/CD 再構築は軽微）
- `Security.framework`（Keychain）は macOS 専用だが、Linux では `FileManager` + `chmod` フォールバックで現状と同等

Linux 固有の注意点として、`#if os(Linux)` の条件コンパイルが数箇所必要になるが、既存 Python コードの `platform.system()` 分岐と対応関係は明確で複雑でない。

---

## 移行コスト見積もり

| フェーズ | 内容 | 概算工数 |
|---|---|---|
| Phase 1 | プロジェクト設定・CLI・インフラ（Keystore macOS/Linux 分岐含む）・キャッシュ | 1〜2 週 |
| Phase 2 | HTTP クライアント（EDINET API）・サービス層・データ集計・ウォーターフォール計算 | 2〜3 週 |
| Phase 3 | XBRL 解析 22 モジュール（analysis/） | 4〜6 週 |
| Phase 4 | テスト移植・Smoke テスト検証（macOS + Linux CI） | 2〜3 週 |
| Phase 5 | MCP サーバー（保留または別途） | 未定 |
| **合計** | MCP 除く | **10〜15 週** |

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
Phase 1: CLI + インフラ（Keystore macOS/Linux）+ キャッシュ
Phase 2: HTTP クライアント + サービス層 + データ集計・ウォーターフォール計算
Phase 3: XBRL 解析 22 モジュール（Smoke テストをゴールデンファイルとして逐次検証）
Phase 4: テスト移植・CI（macOS + Linux）整備
Phase 5: MCP サーバー（公式 SDK の状況次第）
```

Phase 1 単体では `config` 程度しか完結しない。`ticker search` が純 Swift になるのは Phase 2 完了後、`ticker analyze` は Phase 3 完了後。

**利点**:
- 各フェーズ完了時点で動作確認でき、問題を局所化できる
- Phase 3 の XBRL 移植は既存 Python 版を並走させてモジュール単位で出力比較できる
- MCP サーバーは Python 版を維持したまま先行移行できる

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
| MCP サーバー | 現時点では移行困難（公式 SDK 待ち） |
| 総合工数 | MCP 除き 10〜15 週 |

**推奨: 案 B（段階移行）**。目的（パフォーマンス・型安全性・Python 依存解消）をすべて達成するには Phase 3 まで完遂する必要があり、段階移行はそのリスクを分散する手段として機能する。XBRL 解析の移植は既存 Smoke テスト（10 社）をゴールデンファイルとして用い、モジュール単位で Python 版の出力と一致させながら進める。
