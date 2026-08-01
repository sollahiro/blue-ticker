#!/bin/zsh
# blt-server 定期同期ジョブ（ローカル launchd 用）。
#
# sync (書類一覧 → Neon) → financials/filing-sections/breakdowns (ingest: 計算済み財務サマリ・
# 有報セクション・事業別内訳 → Neon) をローカルで実行する。重い ingest を Fly(1GB) で
# 走らせると OOM するため、計算はローカル・Fly は company_financials 等を読むだけ。
# XBRL 数値 fact（facts）は停止中（issue #22。Neon 512MB 対策で消費者ができるまで
# 蓄積を止める）。再開する場合は下の ingest に --with-facts を付ける。
#
# breakdowns は日経225構成銘柄（assets/nikkei225.csv）限定・business→geography の2パス。
# LLM は軸別（XAI_BUSINESS_* / XAI_GEOGRAPHY_*。business のみ旧 XAI_* フォールバック可）。
# 未設定でも xbrl_facts 経路は動くが、html_table 経路は notApplicable になる。
# REST/MCP は business / geography の両軸を公開する（2026-07-27、品質ゲート通過後に解禁）。
#
# 機密（DATABASE_URL / BLT_EDINET_API_KEY / XAI_* 等）はリポジトリ直下 .env から読む。
# バイナリはリリースビルドを使う。コード変更後は手動で再ビルドすること:
#   swift build -c release --product blt-server
#
# ingest 件数は対象別に .env で上書きできる（既定: financials=80 /
# filing-sections=50 / breakdowns=30）。BLT_INGEST_LIMIT がある場合は後方互換として全対象既定値に使う。
#
# 各対象には実行時間の上限（既定 90 分）を設け、超過時は SIGTERM→SIGKILL で
# 強制終了して次の対象へ進む（Neon 接続不安定によるハング対策）。上書きは
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
# BLT_INGEST_LIMIT_FINANCIALS / _FILING_SECTIONS / _BREAKDOWNS（または BLT_INGEST_LIMIT）の上書きも .env に書けば反映される（plist はテンプレートから
# 生成する共有ファイルのため、マシン固有のチューニング値は .env 側に置く）。
set -a
. "$REPO/.env"
set +a

DEFAULT_LIMIT="${BLT_INGEST_LIMIT:-}"
LIMIT_FINANCIALS="${BLT_INGEST_LIMIT_FINANCIALS:-${DEFAULT_LIMIT:-80}}"
LIMIT_FILING_SECTIONS="${BLT_INGEST_LIMIT_FILING_SECTIONS:-${DEFAULT_LIMIT:-50}}"
LIMIT_BREAKDOWNS="${BLT_INGEST_LIMIT_BREAKDOWNS:-${DEFAULT_LIMIT:-30}}"
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
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest financials --limit $LIMIT_FINANCIALS 開始 ====="
  run_with_timeout "$BIN" ingest --stages financials --limit "$LIMIT_FINANCIALS"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest filing-sections --limit $LIMIT_FILING_SECTIONS 開始 ====="
  run_with_timeout "$BIN" ingest --stages filing-sections --limit "$LIMIT_FILING_SECTIONS"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest breakdowns --limit $LIMIT_BREAKDOWNS 開始 ====="
  run_with_timeout "$BIN" ingest --stages breakdowns --limit "$LIMIT_BREAKDOWNS"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 完了 ====="

  # RO 子ブランチを WRITE 親へ reset（Neon API）。Secrets 未設定ならスキップ。
  # 失敗しても ingest 本体の成否には影響させない（AGENTS.md「Neon Secrets」）。
  if [ -n "${NEON_API_KEY:-}" ] && [ -n "${NEON_PROJECT_ID:-}" ] \
    && [ -n "${NEON_RO_BRANCH_ID:-}" ] && [ -n "${NEON_WRITE_BRANCH_ID:-}" ]; then
    echo "===== $(date '+%Y-%m-%d %H:%M:%S') neon RO reset-from-parent 開始 ====="
    if "$REPO/scripts/neon-reset-ro-from-parent.sh"; then
      echo "===== $(date '+%Y-%m-%d %H:%M:%S') neon RO reset-from-parent 完了 ====="
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: neon RO reset-from-parent に失敗しました（ingest 本体の成否には影響しません）"
    fi
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: NEON_* 未設定のため RO reset-from-parent をスキップ"
  fi

  # 公開ステータスページ（assets/apex-site/status.html）の再生成・push。
  # ingest 本体は既に成功しているため、ここが失敗しても全体は失敗扱いにしない
  # （DATABASE_URL は上の set -a; . .env; set +a で既に読み込み済み）。
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') status-page 生成 開始 ====="
  if "$REPO/scripts/generate-status-page.sh"; then
    echo "===== $(date '+%Y-%m-%d %H:%M:%S') status-page 生成 完了 ====="
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: status-page 生成に失敗しました（ingest 本体の成否には影響しません）"
  fi
} >> "$LOG" 2>&1
