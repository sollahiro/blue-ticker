#!/bin/zsh
# ingest ジョブ共通。source 専用（直接実行不可）。
#
#   source "$(dirname "$0")/ingest-common.sh"
#   ingest_require_ready
#   ingest_run ingest --stages statements --limit 80

if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file* && "${ZSH_EVAL_CONTEXT:-}" != *:cmdsubst* ]]; then
  if [[ "$(basename "$0")" == "ingest-common.sh" ]]; then
    echo "ERROR: ingest-common.sh は source して使ってください" >&2
    exit 1
  fi
fi

REPO="${REPO:-$(cd "$(dirname "${(%):-%x}")/../../.." && pwd)}"
BLT_SERVER="${BLT_SERVER:-$REPO/.build/release/blt-server}"
INGEST_LOCAL_ENV="${INGEST_LOCAL_ENV:-$REPO/scripts/jp/edinet/ingest.local.env}"

# 手元チューニング（limit / skip / write）。ingest.local.env は .gitignore。
ingest_load_local_config() {
  if [[ -f "$INGEST_LOCAL_ENV" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$INGEST_LOCAL_ENV"
    set +a
    echo "ingest: loaded $INGEST_LOCAL_ENV"
  fi
}

ingest_load_local_config

ingest_require_ready() {
  if [[ -z "${DATABASE_URL:-}" && -z "${BLT_NEON_WRITE_DATABASE_URL:-}" && -z "${BLT_NEON_DISPOSABLE_DATABASE_URL:-}" ]]; then
    echo "ERROR: DATABASE_URL 未設定。.env を load してください（set -a; . ./.env; set +a）" >&2
    return 1
  fi

  if [[ "${BLT_INGEST_WRITE:-}" == "1" ]]; then
    if [[ -z "${BLT_NEON_WRITE_DATABASE_URL:-}" ]]; then
      echo "ERROR: BLT_INGEST_WRITE=1 ですが BLT_NEON_WRITE_DATABASE_URL が未設定です" >&2
      return 1
    fi
    export DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL"
    echo "ingest: WRITE 接続（BLT_NEON_WRITE_DATABASE_URL）"
  elif [[ -z "${DATABASE_URL:-}" ]]; then
    export DATABASE_URL="${BLT_NEON_DISPOSABLE_DATABASE_URL:-}"
    echo "ingest: disposable 接続（DATABASE_URL 未設定のため BLT_NEON_DISPOSABLE_DATABASE_URL）"
  fi

  if [[ -z "${BLT_EDINET_API_KEY:-}" ]]; then
    echo "ERROR: BLT_EDINET_API_KEY が未設定です" >&2
    return 1
  fi

  if [[ ! -x "$BLT_SERVER" ]]; then
    echo "ERROR: $BLT_SERVER がありません。swift build -c release --product blt-server を先に実行してください" >&2
    return 1
  fi

  return 0
}

ingest_run() {
  local job_name="${INGEST_JOB_NAME:-ingest}"
  echo "=== ${job_name}: $* ==="
  "$BLT_SERVER" "$@"
}

ingest_post_hooks() {
  if [[ "${BLT_INGEST_SKIP_POST:-}" == "1" ]]; then
    echo "ingest: post hooks skipped (BLT_INGEST_SKIP_POST=1)"
    return 0
  fi

  if [[ -x "$REPO/scripts/generate-status-page.sh" ]]; then
    echo "=== post: generate-status-page ==="
    if ! "$REPO/scripts/generate-status-page.sh"; then
      echo "WARN: generate-status-page.sh failed (ingest 成否には影響させない)" >&2
    fi
  fi

  if [[ -x "$REPO/scripts/post-ingest-linear.sh" ]]; then
    echo "=== post: post-ingest-linear ==="
    if ! "$REPO/scripts/post-ingest-linear.sh"; then
      echo "WARN: post-ingest-linear.sh failed (ingest 成否には影響させない)" >&2
    fi
  fi

  if [[ -x "$REPO/scripts/neon-reset-ro-from-parent.sh" ]]; then
    echo "=== post: neon-reset-ro-from-parent ==="
    if ! "$REPO/scripts/neon-reset-ro-from-parent.sh"; then
      echo "WARN: neon-reset-ro-from-parent.sh failed (ingest 成否には影響させない)" >&2
    fi
  fi
}
