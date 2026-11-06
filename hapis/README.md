# HAPIS カタログ（有報LAB）

`catalog.json` は、有報LAB の REST を HAPIS ゲートウェイと公開 MCP コネクタでどこまで出すかの正本。HAPIS（sollahiro/hapis）は有報LAB のカタログを持たず、ここから同期する。依存は blue-ticker → HAPIS の一方向。

- `endpoints[]`: ゲートウェイが通すルート。`visibility: "private"` はゲートウェイで通すが、公開 OpenAPI・skills・MCP ツールには出さず、API キー（開発者キー・コネクタ）からは 404 になる（iOS の App Attest は通る）
- クエリ引数の `schema.enum`: API キーからの呼び出しで許す値。`required: true` なら省略も不可。例: `get_breakdown` の `axis` は `segment` / `geography` / `employees` だけ
- `rate_per_minute` / `rate_per_day`: そのルートだけの上限（共通の上限に上乗せ）
- `description` は公開コネクタの利用者（Claude 等）に見える文。実装メモを書かない

同期と反映:

```bash
export HAPIS_BASE_URL=https://hapis.sollahiro.workers.dev HAPIS_API_TOKEN=...
scripts/hapis-sync-catalog.sh            # 計画だけ表示
scripts/hapis-sync-catalog.sh --apply    # 書き込む（カタログから消したルートは --prune を足したときだけ消す）
```

書き込んだあと HAPIS でゲートウェイを再デプロイすると公開される（`POST /v1/apis/yuholab/environments/production/deploy`）。MCP ツール一覧は最大 5 分で追従する。
