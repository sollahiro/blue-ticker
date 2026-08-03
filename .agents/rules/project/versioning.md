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

バージョンの単一の真実源は `Sources/BlueTicker/Constants/Version.swift` の `blueTickerVersion`。CLI の `--version`・MCP サーバー・derived キャッシュの `_cache_version` はすべてこの定数を参照する。したがって、同じ月内でも `Micro` を上げると derived キャッシュは再生成される。

外部取得キャッシュ（`analysis_cache/external/`）は原則としてグローバルバージョンに連動させない。TTL、取得日、外部API用の個別バージョンで管理する。

## リリース手順

バージョン更新を依頼されたら、以下のステップをすべて実行すること。

0. **バンプは機能コミットとは分離し、後続の独立コミットとして行う**
1. **対象コミットを main へプッシュし、CI（macOS + Linux）がグリーンであることを確認する**
   - ローカルの `swift test` 合格だけでタグを切らない。CI のツールチェーンはローカルより古く、ローカルで通るコードが CI で落ちることがある（実例: swift-testing マクロと SwiftSoup の `Comment` 型衝突で v26.6.1/26.6.2 を破棄）
   - `blt-server` の本番反映は main push → CI 成功 → `.github/workflows/deploy.yml`（デプロイ関連パスに差分がある場合）。**`v*` タグではデプロイも成果物生成も走らない**
2. `Sources/BlueTicker/Constants/Version.swift` の `blueTickerVersion` を更新する
3. バンプコミットを作成する（`chore: bump version to YY.M.Micro`）
4. タグを作成する（`git tag vYY.M.Micro`）— Git 上の版印のみ（Homebrew / 配布バイナリ用ではない）
5. コミットとタグをリモートへプッシュする

```bash
git push origin main
git push origin vYY.M.Micro
```

- `git push origin main` ではタグは送られない。**タグは必ず `git push origin <tag>` で明示的にプッシュする**
- `blueTickerVersion` は MCP 表示・ローカル derived キャッシュ無効化などに使う。**Homebrew / 配布 `ticker` の release パイプライン（旧 `release.yml`）は廃止済み**
- タグは軽量タグ（annotated 不要）で統一
- **既存タグの付け直しは禁止**。必ず新しいバージョンに上げて新タグを切ること
- タグ後に間違いを見つけた場合もタグを削除せず、バージョンを上げて新タグを切ること

## キャッシュバージョンの埋め込み（derived キャッシュ）

derived キャッシュには `_cache_version` フィールドを埋め込み、`blueTickerVersion` と照合することで古いキャッシュの混入を防ぐ。

```swift
private let _cacheVersion = blueTickerVersion  // 例: "26.6.0"

// 保存時
dict["_cache_version"] = _cacheVersion

// 読み込み時
if let c = cached, (c["_cache_version"] as? String) == _cacheVersion {
    return c  // _cache_version を除いて返す
}
// バージョン不一致 → フォールスルーして再取得・上書き
```

## Neon キャッシュバージョン（グローバル非連動）

`blt-server` の Neon テーブルの staleness 判定は **`blueTickerVersion` と独立した専用定数**で行う。ローカル derived とコスト構造が逆（再生成に EDINET からの XBRL 再ダウンロード＋再パース／再計算が伴い高コスト）なため、月内 Micro バンプで毎回全件再 ingest が走らないよう、グローバルバージョンから切り離している。facts・financials で別定数を持つ。

| テーブル | 定数 | 置き場所 | 現在値 |
|---|---|---|---|
| `edinet_xbrl_facts`（facts RAW） | `xbrlFactsCacheVersion` | `Models/XbrlFactRecord.swift` | `"facts-v1"` |
| `company_financials`（financials derived） | `companyFinancialsCacheVersion` | `Models/FinancialsContract.swift` | `"fin-v4"` |
| （同上・read 床） | `companyFinancialsMinServableVersion` | 同上 | `4`（`fin-v4` 以上を 200。2026-07-28、上場廃止47社のfin-v2/v3行をDELETEで消化した後に引き上げ） |
| `company_filing_sections`（filing-sections 有報セクション本文） | `filingSectionsCacheVersion` | `Models/FilingSectionsContract.swift` | `"sections-v5"`（geography: 地域報告セグメントの OperatingSegments フォールバック＋APAC、issue #163） |
| （同上・read 床） | `filingSectionsMinServableVersion` | 同上 | `1`（`sections-v1` 以上を 200） |
| `company_breakdowns`（breakdowns business 軸） | `businessBreakdownCacheVersion` | `Models/BreakdownContract.swift` | `"breakdown-business-v8"`（旧共通 `breakdown-v7` から軸分離、2026-07-27。business の決定的ロジック変更時のみバンプ。LLM 行はバンプ非連動。ingest は business→geography の2パス。REST/MCP は business / geography 両軸を公開（2026-07-27解禁）。詳細は `docs/breakdown-normalization-concept.md`。v8: xbrl_facts 経路の行に XBRL ラベルリンクベース由来の日本語 `label` フィールドを追加、2026-08-03） |
| （同上・read 床。xbrl_facts / not_applicable 経由のみ） | `businessBreakdownMinServableVersion` | 同上 | `1`（`…-v1` 以上を 200。LLM 経由の行は cache_version でゲートしない） |
| `company_breakdowns`（breakdowns geography 軸） | `geographyBreakdownCacheVersion` | 同上 | `"breakdown-geography-v9"`（電通型: 地域報告セグメント facts フォールバック、issue #163。決定的ロジック変更時のみバンプ。v9: business軸v8と同時、日本語 `label` フィールド追加、2026-08-03） |
| （同上・read 床） | `geographyBreakdownMinServableVersion` | 同上 | `1` |

### バンプ規則

いずれも `blueTickerVersion` のバンプでは上げない。次のときのみ上げる。

- `xbrlFactsCacheVersion`: XBRL fact のパースロジック（`parseXbrlFactIndex`）、または RAW スキーマ（`XbrlFactRecord` / `XbrlFactIndexPayload`）を変更したとき
- `companyFinancialsCacheVersion`: 財務計算ロジック（`computeFinancials` / `Analysis` 抽出器）、または公開契約型（`FinancialsResponse` / `FinancialsYear`）の意味を変更したとき
- `companyFinancialsMinServableVersion`: **serving ポリシー変更**（再計算トリガーではない）。financials read が 200 を返す最低世代 N を人手で上げるとき。現行から N つ前の機械オフセットにはしない。引き上げは該当旧版の stale 消化完了後（servable 穴を作らない）。不変条件: 床 ≤ 現行 `fin-vN` の N。比較は数値パース（文字列辞書順禁止）
- `filingSectionsCacheVersion`: セクション抽出ロジック（`XBRLParser.extractSections` / `BreakdownExtractor` / `cleanText` の cap 等）、または格納契約型（`FilingSectionsPayload` / `ExtractedBreakdownPayload`）の意味を変更したとき。**セクションの「追加」はバンプ不要**（`section_keys` 列の不一致で当該行のみ自動再抽出される）
- `filingSectionsMinServableVersion`: **serving ポリシー変更**（再計算トリガーではない）。filing-content read の最低世代 N。規則は financials 床と同型
- `businessBreakdownCacheVersion`: business 軸の xbrl_facts 経路の分類・正規化ロジック（`BreakdownNormalizer` / member 分類定数）、`BreakdownExtractor.classifyNotApplicableReason`（business の E/F/unknown）、または business 向け `BreakdownSnapshotPayload` の意味を変える破壊的変更のとき。geography 軸の行は巻き込まない。LLM 経由の行はバンプだけでは再計算しない（needs_review=false の行は据え置き。詳細は `docs/breakdown-normalization-concept.md`「今後の検討事項8」）
- `businessBreakdownMinServableVersion`: **serving ポリシー変更**（再計算トリガーではない）。business の xbrl_facts / not_applicable 行にのみ適用
- `geographyBreakdownCacheVersion`: geography 軸の決定的経路（`not_applicable`/`not_found` 判定等）または geography 向け payload 意味の破壊的変更のとき。business 軸の行は巻き込まない。LLM（`geography_llm`）はバンプ非連動
- `geographyBreakdownMinServableVersion`: **serving ポリシー変更**。geography の決定的行にのみ適用

### 運用上の注意（バンプ時の一度きり再 ingest）

`companyFinancialsCacheVersion` / `filingSectionsCacheVersion` 等の**現行版**を上げると、既存の Neon 行は全件が一度だけ stale 判定され、次回 `blt-server ingest` で再パース／再計算される。これは想定どおりの移行コスト。XBRL ダウンロードが重い（9MB/件）ため、必要なら `--limit` でバッチ分割して取り込む。

financials / filing-sections read は現行版完全一致ではなく各 min servable 以上を返すため、現行版バンプ直後も床以上の旧行は 200 のまま（バンプの崖を避ける）。ingest は引き続き現行版へ収束する。

### 軸分離後の移行（`breakdown-v7` → `breakdown-business-v7` / `breakdown-geography-v7`）

2026-07-27 の軸別 cache_version 分離以前に `breakdown-v7`（共通）で格納されていた **決定的 source**（`xbrl_facts` / `not_applicable`）の行は、初回 ingest で各軸の現行版（`breakdown-business-v7` / `breakdown-geography-v7`）と文字列が一致しないため **一度だけ stale** となり再計算される（`breakdownCacheVersionNumber` は旧 `breakdown-vN` も受理するが、ingest の書き込み先は軸別現行版）。**LLM 経由**（`segment_info_llm` / `geography_llm` 等）は cache_version バンプ非連動のため、needs_review=false の行はこの移行でも据え置き。

business 軸の `businessBreakdownCacheVersion` バンプは geography 軸の行を stale にせず、逆も同様（ingest は軸パラメータごとに独立して staleness 判定する）。

### filing-sections / extractor 修正と geography LLM 行の再計算

`filingSectionsCacheVersion`（sections-v4 等）のバンプや `BreakdownExtractor` の geography 抽出修正だけでは、**既存の `geography_llm` 行（needs_review=false）は再計算されない**（LLM 行は content_hash + needs_review でのみ再試行。`docs/breakdown-normalization-concept.md`「今後の検討事項8」）。抽出ロジック改善の恩恵を geography LLM 行に届けるには、該当軸の LLM 行を `needs_review=true` に更新するか削除してから `blt-server ingest --stages breakdowns` を実行する（business 軸の `segment_info_llm` も同型）。
