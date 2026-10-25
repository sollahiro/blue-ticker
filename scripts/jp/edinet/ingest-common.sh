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
BLT_INGEST="${BLT_INGEST:-$REPO/.build/release/blt-ingest}"
INGEST_LOCAL_ENV="${INGEST_LOCAL_ENV:-$REPO/scripts/jp/edinet/ingest.local.env}"
# launchd / 手動ジョブの CWD が repo 根でないときも標準ラベル _lab.xml を見つける。
export BLUE_TICKER_ASSETS_PATH="${BLUE_TICKER_ASSETS_PATH:-$REPO/assets}"

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
  if [[ -z "${DATABASE_URL:-}" && -z "${BLT_NEON_WRITE_DATABASE_URL:-}" ]]; then
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
    echo "ERROR: DATABASE_URL 未設定です。本番へ書くなら BLT_INGEST_WRITE=1、検証ならローカル Postgres を DATABASE_URL に指定してください" >&2
    return 1
  elif [[ -n "${BLT_NEON_READ_DATABASE_URL:-}" && "$DATABASE_URL" == "$BLT_NEON_READ_DATABASE_URL" ]]; then
    # 読み取りロールでは migrate も書き込みも拒否される。途中で落ちる前に止める。
    echo "ERROR: DATABASE_URL が読み取り専用（BLT_NEON_READ_DATABASE_URL）です。本番へ書くなら BLT_INGEST_WRITE=1、検証ならローカル Postgres を DATABASE_URL に指定してください" >&2
    return 1
  fi

  if [[ -z "${BLT_EDINET_API_KEY:-}" ]]; then
    echo "ERROR: BLT_EDINET_API_KEY が未設定です" >&2
    return 1
  fi

  if [[ ! -x "$BLT_INGEST" ]]; then
    echo "ERROR: $BLT_INGEST がありません。swift build -c release --product blt-ingest を先に実行してください" >&2
    return 1
  fi

  return 0
}

ingest_run() {
  local job_name="${INGEST_JOB_NAME:-ingest}"
  echo "=== ${job_name}: $* ==="
  "$BLT_INGEST" "$@"
}

# blt-ingest の依存範囲が前回ビルドしたコミットから変わったときだけ release ビルドする（launchd ラッパー用）。
# blt-ingest は Vapor / MCP をリンクしないので、配信側（BltServerCore 等）だけの変更では再ビルドしない。
# 判定はコミット単位（作業ツリーの未コミット変更は見ない）。
BLT_INGEST_BUILD_PATHS=(Sources/BlueTicker Sources/BltStoreCore Sources/BltIngestCore Sources/BltIngest Package.swift Package.resolved)
ingest_build_if_needed() {
  local stamp="$REPO/.build/blt-ingest.built-commit"
  local head
  head="$(git -C "$REPO" rev-parse HEAD)" || return 1
  if [[ -x "$BLT_INGEST" && -f "$stamp" ]]; then
    local built
    built="$(<"$stamp")"
    if git -C "$REPO" cat-file -e "${built}^{commit}" 2>/dev/null \
      && git -C "$REPO" diff --quiet "$built" "$head" -- "${BLT_INGEST_BUILD_PATHS[@]}"; then
      echo "ingest: blt-ingest は最新（built=${built:0:12}）"
      return 0
    fi
  fi
  echo "=== build: swift build -c release --product blt-ingest (head=${head:0:12}) ==="
  (cd "$REPO" && swift build -c release --product blt-ingest) || return 1
  mkdir -p "$REPO/.build"
  printf '%s\n' "$head" > "$stamp"
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
}
