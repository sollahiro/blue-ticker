# バージョン管理

## 番号の付け方

バージョンは `YY.M.Micro` 形式にする。

- `YY`: 西暦下2桁（例: 2026年 → `26`）
- `M`: 月。ゼロ埋めしない（5月 → `5`、`05` は使わない）
- `Micro`: 同じ月内のリリース番号。月内初回は `0`

例: 2026年5月の初回リリースは `26.5.0`。

| 変更内容 | 上げ方 | 理由 |
|---|---|---|
| 月が変わった初回リリース | `YY.M.0` | 日付ベースのリリース識別 |
| 同じ月内の追加リリース | `Micro` を +1 | derived キャッシュを確実に無効化するため |

バージョンの単一の真実源は `Sources/BlueTicker/Constants/Version.swift` の `blueTickerVersion`。MCP 表示・ローカル derived キャッシュの `_cache_version` はこれを参照する。同じ月内でも `Micro` を上げると derived キャッシュは再生成される。

外部取得キャッシュ（`analysis_cache/external/`）は原則としてグローバルバージョンに連動させない。

## リリース手順

バージョン更新を依頼されたら、以下をすべて実行する。

0. **バンプは機能コミットとは分離し、後続の独立コミットとして行う**
1. **対象コミットを main へプッシュし、CI（macOS + Linux）がグリーンであることを確認する**
   - ローカルの `swift test` 合格だけでタグを切らない
   - `blt-server` の本番反映は main push → CI 成功 → `.github/workflows/deploy.yml`（デプロイ関連パスに差分がある場合）。**`v*` タグではデプロイも成果物生成も走らない**
2. `Sources/BlueTicker/Constants/Version.swift` の `blueTickerVersion` を更新する
3. バンプコミットを作成する（`chore: bump version to YY.M.Micro`）
4. タグを作成する（`git tag vYY.M.Micro`）— Git 上の版印のみ
5. コミットとタグをリモートへプッシュする（`git push origin main` ではタグは送られない。`git push origin vYY.M.Micro` が必須）

- タグは軽量タグで統一。**既存タグの付け直しは禁止**（間違いは新バージョンで切り直す）

## キャッシュバージョンの埋め込み（derived キャッシュ）

derived キャッシュには `_cache_version` フィールドを埋め込み、`blueTickerVersion` と照合する。不一致はフォールスルーして再取得する。一致時は `_cache_version` を呼び出し元に露出しない（`caching.md`）。

## Neon キャッシュバージョン（グローバル非連動）

`blt-server` の Neon テーブルの staleness 判定は **`blueTickerVersion` と独立した専用定数**で行う。ローカル derived とコスト構造が逆（再生成に EDINET 再取得＋再パースが伴い高コスト）なため、月内 Micro バンプで毎回全件再 ingest が走らないよう切り離している。

**現在値は各定数の定義箇所が正本**（この表は配線の索引のみ。値をここに書かない）。

| テーブル / 軸 | 定数 | 置き場所 |
|---|---|---|
| `edinet_xbrl_facts` | `xbrlFactsCacheVersion` | `Models/XbrlFactRecord.swift` |
| `company_financials` | `companyFinancialsCacheVersion` / `companyFinancialsMinServableVersion` | `Models/FinancialsContract.swift` |
| `company_filing_sections` | `filingSectionsCacheVersion` / `filingSectionsMinServableVersion` | `Models/FilingSectionsContract.swift` |
| `company_breakdowns` business | `businessBreakdownCacheVersion` / `businessBreakdownMinServableVersion` | `Models/BreakdownContract.swift` |
| `company_breakdowns` geography | `geographyBreakdownCacheVersion` / `geographyBreakdownMinServableVersion` | 同上 |
| `company_breakdowns` employees | `employeesBreakdownCacheVersion` / `employeesBreakdownMinServableVersion` | 同上 |
| `company_breakdowns` research_and_development | `researchAndDevelopmentBreakdownCacheVersion` / …MinServable… | 同上 |
| `company_breakdowns` goodwill | `goodwillBreakdownCacheVersion` / `goodwillBreakdownMinServableVersion` | 同上 |
| `company_statements` | `statementCacheVersion` / `statementMinServableVersion` | `Models/StatementContract.swift` |
| `company_statement_notes`（note_type 別） | `*NoteCacheVersion` / `statementNoteMinServableVersion(forType:)` | `Models/StatementNotesContract.swift` |
| company icons | `companyIconsCacheVersion` | `Models/CompanyIconContract.swift` |

business/geography 等の軸は cache_version が分離しており、片方のバンプが他軸を stale にしない。LLM 経由の行は cache_version バンプに連動しない（`needs_review=true` のときのみ再試行）。詳細は `docs/breakdown.md`。

### バンプ規則

いずれも `blueTickerVersion` のバンプでは上げない。次のときのみ上げる。

- `xbrlFactsCacheVersion`: XBRL fact のパースロジック（`parseXbrlFactIndex`）、または RAW スキーマを変更したとき
- `companyFinancialsCacheVersion`: 財務計算ロジック（`computeFinancials` / `Analysis` 抽出器）、または公開契約型の意味を変更したとき
- `companyFinancialsMinServableVersion`: **serving ポリシー変更**（再計算トリガーではない）。financials read が 200 を返す最低世代 N。現行から N つ前の機械オフセットにはしない。引き上げは該当旧版の stale 消化完了後。不変条件: 床 ≤ 現行 `fin-vN` の N。比較は数値パース（文字列辞書順禁止）
- `filingSectionsCacheVersion`: セクション抽出ロジック、または格納契約型の意味を変更したとき。**セクションの「追加」はバンプ不要**（`section_keys` 不一致で当該行のみ再抽出）
- `filingSectionsMinServableVersion`: filing-content read の最低世代 N（financials 床と同型）
- `businessBreakdownCacheVersion` / `geographyBreakdownCacheVersion` 等: 当該軸の決定的経路・payload 意味の破壊的変更。他軸は巻き込まない。LLM 行はバンプだけでは再計算しない
- 各 `*BreakdownMinServableVersion`: 当該軸の serving ポリシー変更
- `statementCacheVersion` / `statementMinServableVersion`: Statement 抽出・契約意味の変更 / read 床
- note_type 別 `*NoteCacheVersion`: 当該 note_type の抽出・契約意味の変更。床は `statementNoteMinServableVersion(forType:)`

### 運用上の注意（バンプ時の一度きり再 ingest）

現行版を上げると既存 Neon 行は一度だけ stale になり、次回 `blt-server ingest` で再計算される。XBRL は重いため必要なら `--limit` で分割する。

financials / filing-sections / statement 等の read は現行版完全一致ではなく各 min servable 以上を返すため、現行版バンプ直後も床以上の旧行は 200 のまま。ingest は現行版へ収束する。

### filing-sections / extractor 修正と geography LLM 行の再計算

`filingSectionsCacheVersion` のバンプや `BreakdownExtractor` の geography 抽出修正だけでは、**既存の `geography_llm` 行（needs_review=false）は再計算されない**。恩恵を届けるには該当 LLM 行を `needs_review=true` にするか削除してから `blt-server ingest --stages breakdowns`（business の `segment_info_llm` も同型）。
