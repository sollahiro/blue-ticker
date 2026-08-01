#!/bin/zsh
# assets/apex-site/status.html（公開ステータスページ）を最新の ingest 状況で再生成する。
#
# blt-scheduled-sync.sh の末尾（全ステージ完了後）から呼ばれる想定。4ステージ
# （financials/filing_sections/breakdown_business/breakdown_geography）の
# カバレッジ・鮮度を「blt-server status-report」（DB read-only、日経225銘柄一覧そのものは
# 出力しない）で取得し、status.html の HTML コメントマーカー間だけを書き換える。
# 差分があれば status.html のみをコミット・push する（他ファイルは触らない）。
#
# 「最終更新」表示は毎回 blt-server status-report 実行時刻（JST）に更新するため、4ステージの
# 数値が前回から一切変わっていなくても diff は毎回発生し、実質ほぼ毎回コミットされる
# （呼び出し元は6時間おき）。これは意図した挙動： ステータスページは「巡回ジョブが生きていて
# 直近いつ確認したか」も伝える情報の一部であり、数値に変化が無い実行を無言でスキップすると、
# ページが古いまま張り付いているのか本当に変化が無いのかを外から区別できなくなる。
#
# 使い方:
#   set -a; . ./.env; set +a
#   ./scripts/generate-status-page.sh
#
# 環境変数:
#   DATABASE_URL（必須。呼び出し側が .env から読み込み済みの前提。ここでは再読込しない）
#
# 終了コード: 0=成功（コミット有無を問わず）/ 1=致命的失敗
#             （binary無し・DATABASE_URL未設定・jq無し・出力がJSONでない・マーカー未検出・
#              git commit/push 失敗）。呼び出し側（blt-scheduled-sync.sh）は
#              ingest 本体が既に成功している前提のため、このスクリプトの失敗で
#              全体を止めない設計にすること（呼び出し側で exit code を無視してログするだけに留める）。

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATUS_HTML="$REPO/assets/apex-site/status.html"
BLT_SERVER="$REPO/.build/release/blt-server"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "ERROR: DATABASE_URL が未設定です" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq が必要です（brew install jq 等）" >&2
  exit 1
fi

if [ ! -x "$BLT_SERVER" ]; then
  echo "ERROR: $BLT_SERVER が見つからないか実行権限がありません（先に 'swift build -c release --product blt-server' を実行してください）" >&2
  exit 1
fi

if [ ! -f "$STATUS_HTML" ]; then
  echo "ERROR: $STATUS_HTML が見つかりません" >&2
  exit 1
fi

report_json="$("$BLT_SERVER" status-report)"
if [ -z "$report_json" ] || ! echo "$report_json" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: blt-server status-report の出力が JSON として解釈できません" >&2
  exit 1
fi

# 開始マーカー〜終了マーカーの間を、$replacement_file の内容（マーカー自体を含む）で
# 丸ごと置き換える。マーカーが見つからない、または置換が実際にヒットしなかった場合は
# ファイルを一切変更せずエラー終了する（sed の複数行置換は改行の扱いが崩れやすいため、
# 環境変数経由で perl のスラープ読み込みに渡す）。
#
# perl の `-i` 直接編集には頼らない： die 時に in-place リネームが走るかは perl の内部実装
# （END ブロックのタイミング）に依存し確実ではないため、標準出力へ書かせて一時ファイルへ
# 保存し、置換ヒット件数（stderr 経由）を明示的に検査してから mv で反映する
# （途中失敗で元ファイルが壊れた状態のまま残る事故を避ける）。
replace_marker() {
  local marker="$1"
  local replacement_file="$2"
  local start="<!-- ${marker} -->"
  local end="<!-- /${marker} -->"

  if ! grep -qF "$start" "$STATUS_HTML" || ! grep -qF "$end" "$STATUS_HTML"; then
    echo "ERROR: マーカー ${marker} が $STATUS_HTML に見つかりません" >&2
    exit 1
  fi

  local out_tmp err_tmp
  out_tmp="$(mktemp "${TMPDIR:-/tmp}/status-out.XXXXXX")"
  err_tmp="$(mktemp "${TMPDIR:-/tmp}/status-err.XXXXXX")"

  STATUS_MARKER_START="$start" STATUS_MARKER_END="$end" STATUS_REPL_FILE="$replacement_file" \
    perl -0777 -pe '
      my $start = quotemeta($ENV{STATUS_MARKER_START});
      my $end   = quotemeta($ENV{STATUS_MARKER_END});
      open(my $fh, "<", $ENV{STATUS_REPL_FILE}) or die $!;
      local $/;
      my $repl = <$fh>;
      close $fh;
      my $n = s/$start.*?$end/$repl/s;
      print STDERR "MATCHCOUNT:$n\n";
    ' "$STATUS_HTML" >"$out_tmp" 2>"$err_tmp"
  local perl_status=$?

  if [ "$perl_status" -ne 0 ] || [ ! -s "$out_tmp" ] || ! grep -q '^MATCHCOUNT:1$' "$err_tmp"; then
    echo "ERROR: マーカー ${marker} の置換に失敗しました（perl_status=${perl_status}）" >&2
    cat "$err_tmp" >&2
    rm -f "$out_tmp" "$err_tmp"
    exit 1
  fi

  mv "$out_tmp" "$STATUS_HTML"
  rm -f "$err_tmp"
}

# generated_at（UTC ISO8601） → JST 表示文字列（"YYYY-MM-DD HH:MM JST"）。
# macOS の `date -j -f` は入力/出力で個別に TZ を切り替えられないため、
# 一度 TZ=UTC でパースして epoch 秒へ落とし、TZ=Asia/Tokyo で出力し直す。
generated_at_iso="$(echo "$report_json" | jq -r '.generated_at')"
epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$generated_at_iso" '+%s' 2>/dev/null)"
if [ -z "$epoch" ]; then
  echo "ERROR: generated_at のパースに失敗しました（値: $generated_at_iso）" >&2
  exit 1
fi
generated_at_jst="$(TZ=Asia/Tokyo date -r "$epoch" '+%Y-%m-%d %H:%M JST')"

gen_tmp="$(mktemp "${TMPDIR:-/tmp}/status-gen.XXXXXX")"
printf '<!-- STATUS_GENERATED_AT -->%s<!-- /STATUS_GENERATED_AT -->' "$generated_at_jst" > "$gen_tmp"
replace_marker "STATUS_GENERATED_AT" "$gen_tmp"
rm -f "$gen_tmp"

# 固定順（financials / filing_sections / breakdown_business / breakdown_geography）。
STAGE_KEYS=(financials filing_sections breakdown_business breakdown_geography)

for key in "${STAGE_KEYS[@]}"; do
  stage_json="$(echo "$report_json" | jq -c --arg k "$key" '.stages[] | select(.key == $k)')"
  if [ -z "$stage_json" ]; then
    echo "ERROR: status-report の出力に stage=${key} がありません" >&2
    exit 1
  fi

  label="$(echo "$stage_json" | jq -r '.label')"
  companies_covered="$(echo "$stage_json" | jq -r '.companies_covered')"
  companies_target="$(echo "$stage_json" | jq -r '.companies_target')"
  coverage_pct="$(printf '%.1f' "$(echo "$stage_json" | jq -r '.coverage_pct')")"
  current_version_pct="$(printf '%.1f' "$(echo "$stage_json" | jq -r '.current_version_pct')")"
  docs_covered="$(echo "$stage_json" | jq -r '.docs_covered')"
  docs_target="$(echo "$stage_json" | jq -r '.docs_target')"
  servable_covered="$(echo "$stage_json" | jq -r '.servable_covered')"
  servable_pct="$(printf '%.1f' "$(echo "$stage_json" | jq -r '.servable_pct')")"
  stale="$(echo "$stage_json" | jq -r '.stale')"

  # servable_covered/servable_pct の分母単位（docs_target があれば書類件数、無ければ対象社数）。
  # current_version_pct/docs_covered と同じ分母を使う。
  if [ "$docs_target" != "null" ]; then
    servable_target="$docs_target"
    servable_unit="件"
  else
    servable_target="$companies_target"
    servable_unit="社"
  fi

  status_class=""
  status_text="最新"
  if [ "$stale" = "true" ]; then
    status_class=" is-stale"
    status_text="更新遅延中"
  fi

  # 開始マーカー直前の字下げは（マッチ範囲の外側のため）置換で触らず元のまま残る。
  # ここで再度字下げを足すと実行のたびに増殖する（実測済みの罠）ため、1行目のみ字下げなしにする。
  # 一方、終了マーカー行の字下げはマッチ範囲に含まれる（`.*?` が最短一致で終了マーカー直前の
  # 空白まで飲み込む）ため、こちらは毎回明示的に付け直す必要がある。
  stage_tmp="$(mktemp "${TMPDIR:-/tmp}/status-stage.XXXXXX")"
  {
    echo "<!-- STATUS_STAGE:${key} -->"
    echo "        <div class=\"light-card stage-card\">"
    echo "          <div class=\"stage-head\">"
    echo "            <span class=\"stage-title\">${label}</span>"
    echo "            <span class=\"stage-status${status_class}\"><span class=\"stage-dot\"></span>${status_text}</span>"
    echo "          </div>"
    echo "          <p class=\"stage-line\">対象社数のうち <span class=\"num\">${companies_covered}</span> 社に反映済み（<span class=\"num\">${coverage_pct}</span>%）</p>"
    echo "          <div class=\"stage-meter\"><div class=\"stage-meter-fill\" style=\"width:${coverage_pct}%\"></div></div>"
    echo "          <p class=\"stage-line\">対象${servable_unit}数あたりの格納済み（serviceable）: <span class=\"num\">${servable_covered}</span>/<span class=\"num\">${servable_target}</span>${servable_unit}（<span class=\"num\">${servable_pct}</span>%）</p>"
    echo "          <div class=\"stage-meter\"><div class=\"stage-meter-fill\" style=\"width:${servable_pct}%\"></div></div>"
    # docs_target がある（financials 以外）ステージのみ、書類ベースの補助行を出す。
    if [ "$docs_target" != "null" ]; then
      echo "          <div class=\"stage-sub\">書類ベースでは <span class=\"num\">${docs_covered}</span>/<span class=\"num\">${docs_target}</span> 件を格納・最新ロジックへの反映: <span class=\"num\">${current_version_pct}</span>%"
      echo "            <div class=\"stage-meter\"><div class=\"stage-meter-fill\" style=\"width:${current_version_pct}%\"></div></div>"
      echo "          </div>"
    fi
    echo "        </div>"
    echo "        <!-- /STATUS_STAGE:${key} -->"
  } > "$stage_tmp"
  # 末尾の余分な改行（echo の "\n"）が次ブロックとの空行間隔を毎回1行ずつ増やさないよう、
  # 置換ファイルの trailing newline を1つに正規化する。
  printf '%s' "$(cat "$stage_tmp")" > "${stage_tmp}.norm"
  mv "${stage_tmp}.norm" "$stage_tmp"

  replace_marker "STATUS_STAGE:${key}" "$stage_tmp"
  rm -f "$stage_tmp"
done

cd "$REPO" || exit 1

if git diff --quiet -- assets/apex-site/status.html; then
  echo "status-page: no change, skipping commit"
  exit 0
fi

git add assets/apex-site/status.html
# パスを明示して commit する（他に何かがステージされていても status.html 以外を巻き込まない。
# `git add` だけでは index 全体が commit 対象になるため、pathspec で明示的に絞る）。
if ! git commit -m "chore: refresh ingest status page" -- assets/apex-site/status.html >/dev/null; then
  echo "ERROR: git commit に失敗しました" >&2
  exit 1
fi

if git push origin main; then
  echo "status-page: committed and pushed"
  exit 0
fi

# push が non-fast-forward で失敗するケース（他 worktree の PR マージ等で origin/main が
# 進んでいた場合）を1回だけ自動リカバリする。--autostash は、たまたま実行タイミングで
# ユーザーが他ファイルを編集中だった場合に rebase が中断しないための保険。
# rebase 自体が失敗する（= status.html 側で本当のコンフリクト）場合は abort して
# ローカルコミットを保持したまま従来どおりエラー終了する。
echo "git push が失敗しました。fetch + rebase して再試行します" >&2
if git fetch origin main --quiet && git rebase --autostash origin/main; then
  if git push origin main; then
    echo "status-page: committed and pushed (rebase retry)"
    exit 0
  fi
else
  git rebase --abort >/dev/null 2>&1
fi

echo "ERROR: git push に失敗しました（コミットはローカルに残っています。次回実行時に確認してください）" >&2
exit 1
