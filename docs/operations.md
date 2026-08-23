# 外部サービス依存と運用保守

手順は `deploy.md`、構成は `architecture.md`。

## 大前提

Neon / Fly Volume の内容は EDINET から `sync`→`ingest` で再導出可能。失われる一次データはない。全社再バックフィルは重いので移行時は dump/restore が現実的。

## サービス別

### Neon（代替容易）

結合点はプロセス束縛の `DATABASE_URL` のみ（手元では `BLT_NEON_DISPOSABLE_DATABASE_URL` 等を代入）。標準 Postgres（JSONB）。`withDbRetry` は cold start 対策で他 Postgres でも無害。切替: dump/restore または再 ingest → secret 差し替え。

### 内訳 LLM（切替容易）

結合点は軸共通の `LLM_PROVIDER`（`openai` / `xai`）と、プロバイダ×軸のキー（`OPENAI_*` / `XAI_*`）。現行は `LLM_PROVIDER=openai` + GPT-5.6 Luna。Grok に戻すときは `LLM_PROVIDER=xai`（xAI 側のキーはそのまま残せる）。`BASE_URL` 省略時はプロバイダの既定 URL。html_table 経路のみ使用。切替後の再計算は `docs/breakdown.md`（`needs_review` または行削除）。

### Fly.io（代替容易）

結合は `fly.toml` / Volume / secrets / deploy。アプリは素の OCI イメージ（Dockerfile）。方式A（Tunnel）のため Fly LB 非依存。切替: 新ホストで同イメージ＋secrets＋Tunnel トークン。

### Cloudflare（撤退経路なし・SSO）

Tunnel + Access（SSO / Service Token / MCP OAuth）。Bearer は廃止済み。安全性は **Tunnel ＋ 公開ポート閉鎖 ＋ Access** の3点セット。どれか欠けると無認証素通り。R2 は会社アイコン（`BLT_R2_ICONS_BUCKET`＋公開 URL）と生 XBRL ZIP（`BLT_R2_XBRL_BUCKET`、私有 L2。ingest のみ）でバケットを分ける。アカウントと鍵は共有。

## 定常運用

- ログは JSON 1行（`ingest_summary` / `db_retry` / `http_access`）。レイテンシ切り分けは `duration_ms`（サーバー内）とクライアント往復を比較。乖離が大きいときは Tunnel/Access 側を疑う。
- 重い ingest はローカル。鮮度監視: `scripts/check-ingest-freshness.sh`。
- デプロイ: CI 成功後 `deploy.yml` が自動（手動は `workflow_dispatch`）。`/healthz` の `cache_versions` で版確認。
- cloudflared は Dockerfile で版固定。数ヶ月に一度更新。
- Fly serviceless 後は stopped になり得る → deploy ワークフローが `machine start`。
- Neon scale-to-zero: `withDbRetry` ＋プール待ち 45s。プラン変更時に再確認。
- Linux: MemberImportVisibility 回避フラグ（`dependencies.md`）。swift-nio 修正後に除去。

## Git の外にある状態

| 場所 | 内容 | 復旧 |
|---|---|---|
| Fly secrets | API キー / DB / Access / Tunnel | 再発行・`fly secrets set` |
| Neon | 全テーブル | dump または再 ingest |
| Cloudflare | Tunnel / Access / IdP / R2（icons 公開バケット・生 XBRL 私有バケット） | `deploy.md` で再作成。ZIP は EDINET 再取得可 |
| ローカル Mac | 手元スケジュール・`.env` | `deploy.md` 定期同期 |
| Fly Volume `/data` | EDINET キャッシュ（L1） | 再取得または R2 L2 |
| Cloudflare Pages（apex） | Git 連携は切断済み（作り直し中。`assets/apex-site` はリポジトリから削除） | 新サイトを置く場所が決まってから再接続 |
