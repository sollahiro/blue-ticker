#!/usr/bin/env bash
# 本番 ingest 後に Linear Project「JP 機能サイクル」へ件数スナップショットを投稿する。
#
# 既存の `blt-server status-report`（公開 status ページと同じ集計）を Markdown にし、
# Linear の Project status update にする。Issue への自動コメントはしない
# （6h 周期でスレッドが埋まるため。履歴は Project の Updates）。
#
# 呼び出し: ingest_post_hooks（定期サイクル末尾。失敗しても ingest 成否に影響させない）。
#
# 使い方:
#   set -a; . ./.env; set +a
#   BLT_INGEST_WRITE=1 ./scripts/post-ingest-linear.sh
#   BLT_INGEST_WRITE=1 ./scripts/post-ingest-linear.sh --dry-run   # 投稿せず本文を出す
#
# 環境変数:
#   DATABASE_URL            必須（WRITE 接続。呼び出し側が束縛済み）
#   LINEAR_API_KEY          未設定なら skip（Settings → Account → Security & Access）
#   BLT_INGEST_WRITE        1 以外なら skip（使い捨て件数を Linear に載せない）
#   LINEAR_INGEST_PROJECT   既定「JP 機能サイクル」。UUID でも可
#
# 終了コード: 0=投稿/skip/dry-run / 1=設定・集計・API 失敗

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BLT_SERVER="${BLT_SERVER:-$REPO/.build/release/blt-server}"
PROJECT_REF="${LINEAR_INGEST_PROJECT:-JP 機能サイクル}"
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

if [[ -z "${LINEAR_API_KEY:-}" && "$DRY_RUN" -eq 0 ]]; then
  echo "post-ingest-linear: skip (LINEAR_API_KEY unset)"
  exit 0
fi

if [[ "${BLT_INGEST_WRITE:-}" != "1" && "$DRY_RUN" -eq 0 ]]; then
  echo "post-ingest-linear: skip (BLT_INGEST_WRITE!=1)"
  exit 0
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL が未設定です" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq が必要です" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl が必要です" >&2
  exit 1
fi

if [[ ! -x "$BLT_SERVER" ]]; then
  echo "ERROR: $BLT_SERVER がありません" >&2
  exit 1
fi

report_json="$("$BLT_SERVER" status-report)"
if [[ -z "$report_json" ]] || ! echo "$report_json" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: blt-server status-report の出力が JSON ではありません" >&2
  exit 1
fi

generated_at="$(echo "$report_json" | jq -r '.generated_at')"
any_stale="$(echo "$report_json" | jq -r '[.stages[].stale] | any')"
if [[ "$any_stale" == "true" ]]; then
  health="atRisk"
else
  health="onTrack"
fi

stage_rows="$(echo "$report_json" | jq -r '
  .stages[] |
  "| \(.key) | \(.companies_covered)/\(.companies_target) (\(.coverage_pct)%) | \(.latest_covered)/\(.latest_target) (\(.latest_coverage_pct)%) | \(.latest_current_pct)% | \(.current_version_pct)% | \(.servable_covered) (\(.servable_pct)%) | \(if .stale then "stale" else "ok" end) |"
')"

body="$(cat <<EOF
ingest 後スナップショット（${generated_at}）。\`blt-server status-report\` と同じ集計。

| stage | 社カバー（全窓） | 最新年度 | 最新・現行版 | 全窓・現行版 | servable | 鮮度 |
|---|---|---|---|---|---|---|
${stage_rows}

- 社カバー（全窓）: 保持窓内で行がある社（前年だけの行でも 100% になりうる）
- 最新年度: 各社の最新有報（yearRank 0）。financials は \`high_water >=\` その提出日時。母数は最新 120 がある社／件（120 が無い上場社は含めない）
- 最新・現行版: 最新有報スライスのうち、いまの Contract \`cache_version\` 一致率
- 全窓・現行版: 保持窓全体の現行版一致率（financials は社、他は書類）
- servable: read 床以上（現行より古いが配信可能な行を含む）
- 鮮度 stale: 最終更新が閾値より古い（版ずれとは別）
- statements（上場）/ notes・unpublished 軸（日経225）は本表に含めない（件数は下の histogram）
EOF
)"

histogram=""
if command -v psql >/dev/null 2>&1; then
  md_hist() {
    local title="$1"
    local sql="$2"
    local rows
    if ! rows="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F $'\t' -c "$sql" 2>/dev/null)"; then
      return 0
    fi
    [[ -z "$rows" ]] && return 0
    printf '\n**%s**\n\n' "$title"
    echo "| key | n |"
    echo "|---|---|"
    while IFS=$'\t' read -r k n; do
      [[ -z "${k:-}" ]] && continue
      echo "| ${k} | ${n} |"
    done <<< "$rows"
    echo
  }

  histogram="$(
    {
      echo
      echo "### cache_version 件数"
      echo
      md_hist "company_financials" \
        "SELECT cache_version, count(*)::text FROM company_financials GROUP BY 1 ORDER BY 1"
      md_hist "company_filing_sections" \
        "SELECT cache_version, count(*)::text FROM company_filing_sections GROUP BY 1 ORDER BY 1"
      md_hist "company_statements" \
        "SELECT cache_version, count(*)::text FROM company_statements GROUP BY 1 ORDER BY 1"
      md_hist "company_statement_notes (note_type / version)" \
        "SELECT note_type || ' / ' || cache_version, count(*)::text FROM company_statement_notes GROUP BY 1 ORDER BY 1"
      md_hist "company_breakdowns (axis / version)" \
        "SELECT axis || ' / ' || cache_version, count(*)::text FROM company_breakdowns GROUP BY 1 ORDER BY 1"
      md_hist "company_breakdowns needs_review" \
        "SELECT axis || ' review=' || needs_review::text, count(*)::text FROM company_breakdowns GROUP BY 1 ORDER BY 1"
    } | sed '/^$/N;/^\n$/D'
  )"
fi

body="${body}${histogram}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$body"
  echo "post-ingest-linear: dry-run (health=${health} project=${PROJECT_REF})"
  exit 0
fi

linear_gql() {
  local payload="$1"
  curl -fsS https://api.linear.app/graphql \
    -H "Authorization: ${LINEAR_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

if [[ "$PROJECT_REF" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  project_id="$PROJECT_REF"
else
  lookup_payload="$(jq -n --arg name "$PROJECT_REF" '{
    query: "query($name: String!) { projects(filter: { name: { eq: $name } }) { nodes { id name } } }",
    variables: { name: $name }
  }')"
  lookup_json="$(linear_gql "$lookup_payload")"
  if echo "$lookup_json" | jq -e '.errors' >/dev/null 2>&1; then
    echo "ERROR: Linear project 検索に失敗しました" >&2
    echo "$lookup_json" | jq . >&2
    exit 1
  fi
  project_id="$(echo "$lookup_json" | jq -r '.data.projects.nodes[0].id // empty')"
  if [[ -z "$project_id" ]]; then
    echo "ERROR: Linear project '${PROJECT_REF}' が見つかりません" >&2
    exit 1
  fi
fi

create_payload="$(jq -n \
  --arg projectId "$project_id" \
  --arg body "$body" \
  --arg health "$health" '{
    query: "mutation($input: ProjectUpdateCreateInput!) { projectUpdateCreate(input: $input) { success projectUpdate { id url } } }",
    variables: { input: { projectId: $projectId, body: $body, health: $health } }
  }')"
create_json="$(linear_gql "$create_payload")"
if echo "$create_json" | jq -e '.errors' >/dev/null 2>&1 \
  || [[ "$(echo "$create_json" | jq -r '.data.projectUpdateCreate.success // false')" != "true" ]]; then
  echo "ERROR: Linear projectUpdateCreate に失敗しました" >&2
  echo "$create_json" | jq . >&2
  exit 1
fi

url="$(echo "$create_json" | jq -r '.data.projectUpdateCreate.projectUpdate.url')"
echo "post-ingest-linear: posted ${url} (health=${health})"
