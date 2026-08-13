# blt-server ロードマップ

現在地と次の意思決定の索引。手順は `deploy.md` / `operations.md`、構成は `architecture.md`、完了経緯は Git。

## 現在地

| 項目 | 状態 |
|---|---|
| 本番 | Fly (nrt) + Neon + Cloudflare Access/Tunnel。`api.*` / `mcp.*`。main push（CI 成功後）で自動デプロイ |
| CLI | 配布 `ticker` 廃止。開発は `TickerDev`、運用は `blt-server` sync/ingest |
| sync | 稼働・日次増分 |
| facts | スキーマあり・取り込み停止中（Neon 容量。`--with-facts` で再開可） |
| financials / filing-sections | バックフィル継続。現行版・read 床は `versioning.md`（定義箇所が正本） |
| breakdowns | 日経225。business/geography 公開済。employees/rd は軸あり未公開。goodwill は Stage1（ingest/REST 未配線） |
| statements | 日経225。DB/ingest/REST/MCP 済（`statement-v1`、BS/PL/CF/SS）。notes はコード配線済・本番 ingest 未 |
| 定期ジョブ | ローカル launchd。Fly は read 専用（ingest は OOM のためローカル） |
| MCP | `POST /` 埋め込み。Managed OAuth は `mcp.*` |

カバレッジ確認例: `SELECT cache_version, count(*) FROM company_financials GROUP BY 1`。

## 方針

- **REST `/v1` が契約の正**。MCP は追従面。新機能は REST 先。
- Core はサーバー専用にしない（`TickerDev`・テストと共有）。
- オンデマンド ingest（404→202＋キュー）は設計あり・未実装（公開スキーマ追加のため着手前確認）。
- 段階 A（自社 REST）→ B（第三者公開）は `docs/public-api-concept.md`。

### financials / filing-sections read 床

現行版完全一致ではなく **min servable 以上**を返す。定数・バンプ規則は `.agents/rules/project/versioning.md`。床の引き上げは旧版 stale 消化後。`/healthz` の `*_min_servable` で確認可。

## データパイプライン

| 対象 | 保存先 | 状態 |
|---|---|---|
| sync | `edinet_documents` / `edinet_sync_state` | 稼働 |
| 生 XBRL | ローカル / Fly Volume | 保持。R2 は延期 |
| facts | `edinet_xbrl_facts` | 停止中 |
| financials | `company_financials` | バックフィル中。read は床以上・未格納 404 |
| filing-sections | `company_filing_sections` | 同上 |

重い ingest はローカル→Neon。Fly serving は read-only。

## ゴール / 非ゴール

**ゴール**: ユーザー向け実行を blt-server（remote）へ集約（達成）。

**非ゴール**: 各サブコマンドへの backend 選択、床の「現行から N つ前」機械オフセット、`CacheManager` と EDINET external の無理な単一抽象化。

## ストレージ（未決）

facts 停止で Neon 512MB を先送り。(a) Neon プラン拡張 vs (b) 生 XBRL/facts のオブジェクトストレージ＋フォールバック。目標 A（タグ系→facts）着手時に決める。

## TODO

- [ ] financials / filing-sections の stale 消化継続
- [ ] オンデマンド ingest（非同期・着手前確認）
- [ ] financials と正本の分離（配線継続）— `docs/financials-summary-separation-concept.md`
- [ ] notes 本番 ingest、goodwill breakdown 配線、employees/rd 公開可否
- [ ] statements 母集団拡大（銀行・保険等の実データ確認後）
- [ ] MCP/REST レイテンシ（Tunnel/Access 区間）
- [ ] ストレージ強化の方式選定
- [ ] REST 第三者公開（段階 B）— `docs/public-api-concept.md`
- [ ] Monetize Gateway（`docs/feature-tiers.md`）
- [ ] filing-sections: 半期(160) 拡張
- [ ] 抽出差分検証ツール / LLM 抜き打ち整合

## 関連

`architecture.md` · `public-api-concept.md` · `api-auth.md` · `api-compatibility.md` · `deploy.md` · `operations.md` · `breakdown-normalization-concept.md` · `statement-normalization-concept.md` · `financials-summary-separation-concept.md` · `.agents/rules/project/versioning.md`
