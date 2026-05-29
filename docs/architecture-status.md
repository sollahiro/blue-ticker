# アーキテクチャ課題と対応状況

作成日: 2026-05-02
最終更新: 2026-05-08

このメモは、アーキテクチャ棚卸しで見つかった問題を「何が問題だったか」「現在どう扱っているか」で追えるようにした対応台帳です。

詳細な構造図と指標カタログは `docs/architecture-review.md` を参照してください。
リモートMCP移行とEDINETキャッシュbackendの将来計画は `docs/mcp-server-roadmap.md` を参照してください。

## 状況サマリー

| 領域 | 状況 | 一言 |
|---|---|---|
| CLI JSON出力 | 対応済み | 標準JSONからデバッグフィールドを除外し、必要時だけ明示出力する |
| 指標の出所情報 | 対応済み | `MetricSources` に集約し、内部計算では保持する |
| ローカルMCP | 廃止済み | `ticker mcp` とローカルMCPサーバーを削除し、CLI + Skills の運用に寄せた |
| キャッシュ可視化/削除 | 対応済み | status/clean をCLIで提供し、内部auditは削除対象の分類に使う |
| リモートMCP移行ロードマップ | 設計中 | ローカルCLI/キャッシュは残し、将来のremote MCPとは分離する方針 |
| 公開JSONスキーマ固定 | 対応済み | ゴールデンテストでpublicキー・debugキーを契約として固定 |
| XBRL抽出結果の型 | 対応済み | 全抽出器の戻り値を `TypedDict` 化、pyright 0 errors |
| EDINETキャッシュ境界 | 対応済み | `EdinetCacheStore` + TTL + 年次インデックス + XBRL容量上限・LRU対応済み |
| EDINET補完パイプライン | 対応済み | 共通フォーマット化・H2計算整理まで完了 |
| 個別分析キャッシュ粒度 | 対応済み | XBRL parse・書類リストを独立キャッシュ化。年度別粒度化は恩恵薄として見送り |

## 対応済み

### 1. 標準JSONが内部デバッグ情報を出しすぎる

**問題**

`ticker analyze --format json` が、内部計算用の `MetricSources` や `IBDComponents` まで返していた。利用者側から見ても、財務数値と検証用メタデータの境界が分かりにくかった。

**対応**

- `utils/output_serializer.py` を追加
- 標準JSONでは以下を除外
  - `MetricSources`
  - `IBDComponents`
  - `GrossProfitMethod`
  - `IBDAccountingStandard`
- `SalesLabel` / `OPLabel` は意味情報として標準JSONに残す
- `--include-debug-fields` でデバッグフィールドを明示的に出せるようにした
- キャッシュには内部構造を保存し、返却時だけ整形する

**主なファイル**

- `blue_ticker/utils/output_serializer.py`
- `blue_ticker/services/data_service.py`
- `blue_ticker/services/half_year_data_service.py`
- `blue_ticker/app/cli/parser.py`

**現在の扱い**

ゴールデンテストで公開フィールドが契約として固定済み（`#12` を参照）。

### 2. 半期データのEDINET失敗経路でデバッグ情報が漏れる

**問題**

半期データでEDINET補完が失敗した場合、早期returnが serializer を通らず、標準出力でも `MetricSources` が残っていた。

**対応**

- EDINET失敗時の早期returnも `serialize_half_year_periods()` を通すよう修正
- デフォルトでは除外されること、`include_debug_fields=True` では含まれることをテスト追加

**主なファイル**

- `blue_ticker/services/half_year_data_service.py`
- `tests/test_data_service.py`

**現在の扱い**

標準出力とデバッグ出力の境界は serializer に集約している。

### 3. 指標の出所と手法が追いにくい

**問題**

EDINET由来、内部計算、財務省CSV由来の値が `CalculatedData` に混在していた。値がどこから来たのか、どの方法で補完されたのかを後から確認しづらかった。

**対応**

- `CalculatedData.MetricSources` に `source`, `method`, `docID`, `unit`, `label` を集約
- 年次・半期の主要指標で出所情報を付与
- 標準JSONでは出さず、デバッグ出力で確認する設計に整理

**主なファイル**

- `blue_ticker/analysis/calculator.py`
- `blue_ticker/services/analyzer.py`
- `blue_ticker/services/half_year_data_service.py`
- `blue_ticker/utils/metrics_types.py`

**現在の扱い**

`utils/xbrl_result_types.py` で全抽出器の戻り値 `TypedDict` を定義し、各 `extract_*` 関数の戻り値型として適用済み。

### 4. EDINETキャッシュ処理がAPIクライアント内に寄りすぎていた

**問題**

EDINETの日別検索キャッシュとXBRL zip展開処理が `EdinetAPIClient` に直接入っており、通信責務とローカルファイル管理責務が混ざっていた。

**対応**

- `api/edinet_cache_store.py` を追加
- 日別検索キャッシュの読み書き、XBRL zip展開、安全なzip entry検証を `EdinetCacheStore` に分離
- `EdinetAPIClient` は通信とキャッシュストア呼び出しに寄せた

**主なファイル**

- `blue_ticker/api/edinet_cache_store.py`
- `blue_ticker/api/edinet_client.py`

**現在の扱い**

日別検索は空結果1日・直近ヒット30日・過去日3650日のTTLで管理する。年次インデックスは `_cache_version` と `built_through` で検証し、XBRL展開ディレクトリは2GB上限を超えた場合にmtime LRUで削除する。

### 5. キャッシュ状態が見えず、安全に掃除しづらい

**問題**

古いキャッシュや廃止済み機能のキャッシュが残っても、ユーザーが状態を確認しづらかった。

**対応**

- `ticker cache status` を追加
- `ticker cache prepare` / `ticker cache catchup` / `ticker cache refresh` を追加
- `ticker cache clean` をdry-runデフォルトで追加
- EDINET-onlyスモークテスト用の検索/XBRLキャッシュ準備処理を追加

**主なファイル**

- `blue_ticker/services/cache_pruner.py`
- `blue_ticker/app/cli/cache.py`

**現在の扱い**

EDINET検索キャッシュ、年次インデックス、XBRL展開ディレクトリ、EDINET書類リスト、XBRL parse結果、分析結果キャッシュは `cache status` と `cache clean` の dry-run でカテゴリ別に確認できる。内部の audit は削除対象分類に使い、CLIコマンドとしては公開していない。XBRL展開ディレクトリは保存時にも容量上限を確認し、自動整理する。

### 6. XBRL抽出器追加時の変更箇所が多かった

**問題**

新しいEDINET抽出指標を足すたびに、`EdinetFetcher` と `IndividualAnalyzer` の複数箇所を手で増やす必要があり、漏れや重複が起きやすかった。

**対応**

- `ExtractorSpec` レジストリを導入
- 年次抽出器を `_EXTRACTOR_SPECS` に集約
- `extract_all_by_year` と `_METRIC_APPLIERS` で呼び出しを整理

**主なファイル**

- `blue_ticker/services/edinet_fetcher.py`
- `blue_ticker/services/analyzer.py`

**現在の扱い**

年次抽出器はレジストリで管理する。半期固有のH1/H2計算は `half_year_data_service.py` に残しつつ、書類検索・ダウンロード・パースは共有化している（`#10` を参照）。

### 7. XBRL parse が指標ごとに重複していた

**問題**

同じXBRL文書を、売上総利益、有利子負債、税金、従業員数などの抽出器がそれぞれ parse すると、対象年度数に比例して無駄が増える。

**対応**

- `predownload_and_parse()` で文書ごとに一度だけ parse
- `pre_parsed` を各抽出器に渡す
- XML parse を複数指標で共有

**主なファイル**

- `blue_ticker/services/edinet_fetcher.py`
- `blue_ticker/analysis/xbrl_utils.py`
- `blue_ticker/analysis/*.py`

**現在の扱い**

`_download_and_parse_docs` の共有化で年次/半期の重複を解消。型は `XbrlTagElements = dict[str, dict[str, float]]` で固定済み。

## キャッシュ設計

### 8. EDINETキャッシュを正式なキャッシュ層にする

**問題**

`CacheManager` 管理のJSONキャッシュと、EDINET配下のファイルキャッシュは性質が違う。取得系ファイルキャッシュ、書類リスト、XBRL parse結果、最終分析結果を混同すると、削除や再計算の意図が分かりにくくなる。

**対応済み**

- `EdinetCacheStore` でAPI通信からファイル管理を分離
- cache status/clean で容量と古いEDINETキャッシュを見られるようにした
- 検索キャッシュのTTL: 空結果1日・ヒットあり30日（`EDINET_SEARCH_EMPTY_TTL_DAYS` / `EDINET_SEARCH_HIT_TTL_DAYS`）
- 過去日検索キャッシュのTTL: 3650日（`EDINET_SEARCH_PAST_TTL_DAYS`）
- 年次インデックスのバージョン: `EDINET_DOCUMENT_INDEX_VERSION`
- XBRL展開ディレクトリの容量上限: `EDINET_XBRL_MAX_BYTES`（2GB）を設定し、mtime LRU で古い順に eviction
- LRUまたは日数ベースの自動整理: mtime ベースの LRU eviction を実装済み
- EDINET書類リストとXBRL parse結果は `CacheManager` 経由で独立キャッシュ

**現在の扱い**

取得系ファイルキャッシュは `EdinetCacheStore`、分析系JSONキャッシュは `CacheManager` が担当する。CLIでは `cache status/clean` で横断的に確認・整理できるようにする。

### 9. 型安全性

**問題**

主要な `CalculatedData` / `YearEntry` は型定義されたが、EDINET抽出器の戻り値はまだ `dict[str, Any]` が多い。抽出器ごとの `current`, `prior`, `method`, `docID`, `components` などが型で固定されていない。

**対応済み**

- `utils/metrics_types.py` に主要metrics系 `TypedDict` を追加
- `utils/xbrl_result_types.py` に全XBRL抽出器の戻り値 `TypedDict` を定義
- 全 `extract_*` 関数の戻り値型として適用、pyright 0 errors
- `pre_parsed` の型は `XbrlTagElements = dict[str, dict[str, float]]` で固定
- Pyright は dev依存に追加済み、変更対象モジュール単位で型を見る方針をルール化

**対応済み（追加分）**

- `ci.yml` に `poetry run pyright blue_ticker/` を追加。main へのpush・PR時に全体型チェックが常時実行される
- `pyrightconfig.json` で `typeCheckingMode: "basic"`、全 `*.py` を対象に設定済み

## パイプラインと粒度

### 10. 年次/半期のEDINET補完パイプライン統合

**問題**

年次分析と半期分析で、EDINET書類検索、XBRL取得、GP/IBD/CF補完の呼び方が別経路になっている。似た処理がある一方で、半期固有のFY-H1計算もあり、単純には共通化しづらい。

**対応済み**

- `_download_and_parse_docs(docs, code) -> _PreParsedMap` を共有ヘルパーとして抽出
- 年次の `predownload_and_parse()` と半期の `extract_half_year_edinet_data()` が同じダウンロード+パース処理を使うように統一
- `_prepare_q2_records()` で 2Q レコード抽出・重複排除を切り出し
- `_get_half_year_docs()` を追加。`_doc_cache` / `_doc_locks` で年次と同じキャッシュ機構に乗せた（キー: `(code, max_years, "2Q")`）
- `extract_half_year_edinet_data()` を `_get_half_year_docs()` 呼び出しに切り替え

**対応済み（追加分）**

- `HalfYearEdinetEntry` TypedDict を新設し、`extract_half_year_edinet_data` の戻り値を `dict[str, HalfYearEdinetEntry]` に型付け
- `GrossProfitResult` に `docID: NotRequired[str]` を追加（サービス層での後付けを型定義に反映）
- `_to_gross_profit_result` 正規化ヘルパーで `fy_gp` を `dict[str, GrossProfitResult]` に変換
- H1/H2/FY-only 補完ロジックを `_apply_h1_edinet_data` / `_apply_h2_edinet_data` / `_apply_fy_only_edinet_data` に切り出し
- CFO/CFI の `_set_metric_source` から存在しないキー (`method`/`docID`) への参照を削除

### 11. 個別分析キャッシュの粒度見直し

**問題**

`individual_analysis_{code}` は最終成果物を丸ごとキャッシュする。便利だが、XBRL抽出ロジック、WACCロジック、公開JSON整形を改善しても、キャッシュヒット時は古い分析結果が残りうる。

**対応済み**

- EDINET由来の書類・XBRLパースキャッシュを使い、分析キャッシュ更新時の再取得を抑制
- 分析キャッシュ（`individual_analysis_{code}`）バージョンをバンプしても不要なEDINET再取得が発生しにくくなった
- `IndividualAnalyzer.fetch_analysis_data()` に `prefetched_stock_info` / `prefetched_financial_data` を追加

**対応済み（追加分）**

- `EdinetFetcher` に `cache_manager: CacheManager | None` を追加
- `_get_annual_docs` / `_get_half_year_docs` で `CacheManager` 経由の永続キャッシュ読み書きを実装（バージョン: `__version__`、形状検証付き）
- キャッシュキー: `derived/document_discovery/edinet_docs_{code}_{max_years}.json`（年次）/ `derived/document_discovery/edinet_docs_{code}_{max_years}_2Q.json`（半期）
- `HalfYearDataService` / `IndividualAnalyzer` / `DataService.get_analyzer()` から `cache_manager` を伝播

**対応済み（追加分）**

- `_download_and_parse_docs` の `_dl_parse` に parse result キャッシュを追加（キー: `derived/xbrl_numeric_index/xbrl_parsed_{docID}.json`、バージョン: `__version__ + ":xbrl-parse"`）
- `_is_valid_xbrl_parse_cache` で `dict[str, dict[str, float]]` 相当の shape バリデーション（`bool` 除外含む）
- download は HTML fallback のため常に実行し、parse（`collect_all_numeric_elements`）のみスキップする設計

**見送り**

- 最終metricsの年度別粒度化: 指標別バージョン管理が必要で実装複雑度が高い。`_apply_*` 再計算は純 CPU で実際のコストは小さく、XBRL パース・書類リストはすでに独立キャッシュ済みのため恩恵が薄いと判断し見送り。

## 公開契約

### 12. 公開JSONスキーマの固定

**対応**

- `tests/test_output_serializer.py` に `PUBLIC_CALCULATED_DATA_KEYS` / `HALF_YEAR_PUBLIC_DATA_KEYS` 定数を定義
- 年次・半期標準JSON のゴールデンテスト（公開キーの完全一致チェック）を追加
- `_DEBUG_FIELDS` の集合を `frozenset` で固定するテストを追加
- 入力dict不変性テスト、外部構造保持テストを追加

**主なファイル**

- `tests/test_output_serializer.py`

## 当面触らない

### 13. XBRLタグ候補の大規模整理

**理由**

企業別・会計基準別の知見が詰まっている。タグ候補をきれいに並べ替えるだけでも抽出精度に影響する可能性がある。

**触る条件**

実企業サンプルと会計基準別ゴールデンケースを先に用意する。

### 14. EDINET検索ウィンドウの短縮

**理由**

97日 + 127日フォールバックは遅く見えるが、提出遅延や半期/四半期差異を拾うための安全側の設計。速度だけで短縮すると取りこぼしが出る可能性がある。

**触る条件**

実データで検索日数とヒット率を測ってから判断する。

### 15. `CalculatedData` の公開キー削除

**理由**

CLI利用者への互換性影響が大きい。今回のように標準JSONからデバッグフィールドを落とす場合も、内部構造と明示デバッグ出力には残している。

**触る条件**

alias期間、利用者向けの変更案内、契約テストを用意する。

## 次のおすすめ順

1. J-GAAP、IFRS、US-GAAPの実企業サンプルで回帰テストを増やす
2. `CalculatedData` の公開キー削除やrenameは、alias期間と契約テストを用意してから判断する
