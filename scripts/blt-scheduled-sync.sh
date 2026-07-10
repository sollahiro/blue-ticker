#!/bin/zsh
# blt-server 定期同期ジョブ（ローカル launchd 用）。
#
# Stage 1 (sync: 書類一覧 → Neon) → Stage 4/4-half (ingest: 計算済み財務サマリ
# → Neon) をローカルで実行する。重い ingest を Fly(1GB) で走らせると OOM するため、
# 計算はローカル・Fly は company_financials を読むだけ。
# Stage 3（XBRL 数値 fact）は停止中（issue #22。Neon 512MB 対策で消費者ができるまで
# 蓄積を止める）。再開する場合は下の ingest に --with-facts を付ける。
#
# 機密（DATABASE_URL / BLT_EDINET_API_KEY）はリポジトリ直下 .env から読む。
# バイナリはリリースビルドを使う。コード変更後は手動で再ビルドすること:
#   swift build -c release --product blt-server
#
# ingest 件数はステージ別に .env で上書きできる（既定: Stage4=80 / Stage4-half=80 / Stage5=50）。
# BLT_INGEST_LIMIT がある場合は後方互換として全ステージ既定値に使う。
#
# 各ステージには実行時間の上限（既定 90 分）を設け、超過時は SIGTERM→SIGKILL で
# 強制終了して次のステージへ進む（Neon 接続不安定によるハング対策）。上書きは
# .env の BLT_STAGE_TIMEOUT_SECONDS を使う。
# インストール手順は docs/deploy.md「定期同期（ローカル launchd）」を参照。

set -uo pipefail

# スクリプト位置からリポジトリルートを導出（移植可能にする）
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/.build/release/blt-server"
LOG="$REPO/.build/blt-scheduled.log"

cd "$REPO" || exit 1

# 実行中に Mac がスリープすると Neon 接続が切れてステージがハングするため、
# スクリプトの生存期間だけスリープを抑止する（-w $$ で本プロセス終了時に自動解除）。
caffeinate -i -s -w $$ &

if [ ! -x "$BIN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $BIN がありません。先に 'swift build -c release --product blt-server' を実行してください。" >> "$LOG"
  exit 1
fi

if [ ! -f "$REPO/.env" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $REPO/.env がありません（DATABASE_URL / BLT_EDINET_API_KEY が必要）。" >> "$LOG"
  exit 1
fi

# .env から環境変数を読み込む（裸書きのキー値を想定。クォートで囲まない）。
# BLT_INGEST_LIMIT_STAGE4 / _STAGE4_HALF / _STAGE5（または BLT_INGEST_LIMIT）の上書きも .env に書けば反映される（plist はテンプレートから
# 生成する共有ファイルのため、マシン固有のチューニング値は .env 側に置く）。
set -a
. "$REPO/.env"
set +a

DEFAULT_LIMIT="${BLT_INGEST_LIMIT:-}"
LIMIT_STAGE4="${BLT_INGEST_LIMIT_STAGE4:-${DEFAULT_LIMIT:-80}}"
LIMIT_STAGE4_HALF="${BLT_INGEST_LIMIT_STAGE4_HALF:-${DEFAULT_LIMIT:-80}}"
LIMIT_STAGE5="${BLT_INGEST_LIMIT_STAGE5:-${DEFAULT_LIMIT:-50}}"
STAGE_TIMEOUT_SECONDS="${BLT_STAGE_TIMEOUT_SECONDS:-5400}"

# コマンドをバックグラウンドで実行し、$STAGE_TIMEOUT_SECONDS 秒経っても生きていれば
# SIGTERM、さらに 10 秒待って生きていれば SIGKILL する（Neon 接続ハング対策）。
run_with_timeout() {
  "$@" &
  local pid=$!
  (
    sleep "$STAGE_TIMEOUT_SECONDS"
    if kill -0 "$pid" 2>/dev/null; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: ${STAGE_TIMEOUT_SECONDS}s タイムアウトのため強制終了: $*"
      kill -TERM "$pid" 2>/dev/null
      sleep 10
      kill -KILL "$pid" 2>/dev/null
    fi
  ) &
  local watchdog=$!
  wait "$pid"
  local exit_status=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return $exit_status
}

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') sync 開始 ====="
  run_with_timeout "$BIN" sync
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest stage4 --limit $LIMIT_STAGE4 開始 ====="
  run_with_timeout "$BIN" ingest --stages 4 --limit "$LIMIT_STAGE4"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest stage4-half --limit $LIMIT_STAGE4_HALF 開始 ====="
  run_with_timeout "$BIN" ingest --stages 4half --limit "$LIMIT_STAGE4_HALF"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest stage5 --limit $LIMIT_STAGE5 開始 ====="
  run_with_timeout "$BIN" ingest --stages 5 --limit "$LIMIT_STAGE5"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 完了 ====="
} >> "$LOG" 2>&1
