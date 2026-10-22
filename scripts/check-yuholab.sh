#!/bin/bash
# yuholab.com の公開状態を外から確認する。
#
# - DNS：ゾーンが Cloudflare にあること、iCloud+ のメール用レコード（MX・SPF・DKIM・apple-domain）、
#   MX が Cloudflare Email Routing に書き換わっていないこと、DMARC（任意）
# - Web：https://yuholab.com の / と /privacy と /terms が 200 で有報LAB のページを返すこと、
#   sollahiro.com の旧 6 パスが 301 の 1 回で対応する yuholab.com のページに届くこと
#
# 送受信テスト・自動更新・Email Routing の画面上の状態は外から見えないので、手で確認する。
#
# 使い方:
#   ./scripts/check-yuholab.sh          # DNS と Web の両方
#   ./scripts/check-yuholab.sh --dns    # DNS だけ（法務ページのデプロイ前に使う）
#
# 必要なもの: curl。DNS は DoH（cloudflare-dns.com）で引くので dig は使わない。
#
# 終了コード: 0=すべて OK（WARN は含んでよい） / 1=NG あり / 2=引数・環境エラー

set -uo pipefail

DOMAIN="yuholab.com"
LEGACY_HOST="sollahiro.com"
DOH="https://cloudflare-dns.com/dns-query"

mode="all"
case "${1:-}" in
  "") ;;
  --dns) mode="dns" ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  *) echo "ERROR: 不明な引数: $1" >&2; exit 2 ;;
esac

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl が必要です" >&2
  exit 2
fi

failures=0
ok()   { printf 'OK    %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
ng()   { printf 'NG    %s\n' "$1"; failures=$((failures + 1)); }

# DoH の JSON から Answer の data を 1 行ずつ取り出す（TXT の \" は外す）。
# Authority の SOA を拾わないよう、Answer の配列だけを見る。
dns() {
  curl -sS -m 10 -H 'accept: application/dns-json' "$DOH?name=$1&type=$2" \
    | sed -n 's/.*"Answer":\[\([^]]*\)\].*/\1/p' \
    | grep -o '"data":"\([^"\\]\|\\.\)*"' \
    | sed -e 's/^"data":"//' -e 's/"$//' -e 's/\\"//g'
}

check_dns() {
  echo "== DNS（$DOMAIN）"

  if dns "$DOMAIN" NS | grep -q '\.ns\.cloudflare\.com\.$'; then
    ok "NS が Cloudflare"
  else
    ng "NS が Cloudflare ではない: $(dns "$DOMAIN" NS | tr '\n' ' ')"
  fi

  mx="$(dns "$DOMAIN" MX | sed 's/^[0-9]* //' | sort | tr '\n' ' ')"
  if [ "$mx" = "mx01.mail.icloud.com. mx02.mail.icloud.com. " ]; then
    ok "MX が iCloud の 2 本だけ（Email Routing で書き換わっていない）"
  elif printf '%s' "$mx" | grep -q 'mx\.cloudflare\.net'; then
    ng "MX が Cloudflare Email Routing を向いている（iCloud に届かない）: $mx"
  else
    ng "MX が想定と違う: ${mx:-（なし）}"
  fi

  txt="$(dns "$DOMAIN" TXT)"
  spf="$(printf '%s\n' "$txt" | grep '^v=spf1' || true)"
  if [ "$(printf '%s\n' "$spf" | grep -c '^v=spf1')" -gt 1 ]; then
    ng "SPF が複数ある（どちらも無効になる）: $(printf '%s' "$spf" | tr '\n' '|')"
  elif printf '%s' "$spf" | grep -q 'include:icloud\.com'; then
    ok "SPF: $spf"
  else
    ng "SPF に include:icloud.com がない: ${spf:-（なし）}"
  fi
  if printf '%s\n' "$txt" | grep -q '^apple-domain='; then
    ok "apple-domain の TXT がある"
  else
    ng "apple-domain の TXT がない"
  fi

  dkim="$(dns "sig1._domainkey.$DOMAIN" CNAME)"
  if printf '%s' "$dkim" | grep -q 'icloudmailadmin\.com\.$'; then
    ok "DKIM（sig1._domainkey）: $dkim"
  else
    ng "DKIM の CNAME（sig1._domainkey）が iCloud を向いていない: ${dkim:-（なし）}"
  fi

  dmarc="$(dns "_dmarc.$DOMAIN" TXT | grep '^v=DMARC1' || true)"
  if [ -n "$dmarc" ]; then
    ok "DMARC: $dmarc"
  else
    warn "DMARC がない（任意。候補: v=DMARC1; p=none; rua=mailto:support@$DOMAIN）"
  fi

  if [ -n "$(dns "$DOMAIN" A)$(dns "$DOMAIN" AAAA)" ]; then
    ok "$DOMAIN に A/AAAA がある（Custom Domain が付いている）"
  else
    warn "$DOMAIN に A/AAAA がない（Worker の Custom Domain がまだ）"
  fi

  legacy_mx="$(dns "$LEGACY_HOST" MX | sed 's/^[0-9]* //' | sort | tr '\n' ' ')"
  if printf '%s' "$legacy_mx" | grep -q 'mail\.icloud\.com'; then
    ok "$LEGACY_HOST の MX は iCloud のまま（旧アドレスの受信用）: $legacy_mx"
  else
    warn "$LEGACY_HOST の MX: ${legacy_mx:-（なし）}"
  fi
}

# 1 回だけリクエストして「ステータス Location」を返す（リダイレクトは追わない）。
probe() {
  curl -sS -m 15 -o /dev/null -w '%{http_code} %{redirect_url}' "$1" 2>/dev/null
}

check_web() {
  echo "== Web"

  for path in / /privacy /terms; do
    url="https://$DOMAIN$path"
    body="$(curl -sS -m 15 -w '\n%{http_code}' "$url" 2>/dev/null)"
    code="${body##*$'\n'}"
    if [ "$code" = "000" ]; then
      ng "$url → 接続できない（DNS・証明書がまだの可能性）"
      continue
    elif [ "$code" != "200" ]; then
      ng "$url → $code"
      continue
    fi
    missing=""
    printf '%s' "$body" | grep -q '<title>[^<]*有報LAB' || missing="$missing <title>有報LAB"
    printf '%s' "$body" | grep -q "support@$DOMAIN" || missing="$missing support@$DOMAIN"
    if [ -n "$missing" ]; then
      ng "$url → 200 だが見つからない:$missing"
    else
      ok "$url → 200"
    fi
  done

  for pair in \
    "/blue-ticker /" "/blue-ticker/privacy /privacy" "/blue-ticker/terms /terms" \
    "/yuholab /" "/yuholab/privacy /privacy" "/yuholab/terms /terms"; do
    from="${pair% *}"
    to="https://$DOMAIN${pair#* }"
    for suffix in "" "/"; do
      url="https://$LEGACY_HOST$from$suffix"
      read -r code location <<<"$(probe "$url")"
      if [ "$code" != "301" ] || [ "$location" != "$to" ]; then
        ng "$url → $code ${location:-（Location なし）}（期待: 301 $to）"
        continue
      fi
      read -r code2 location2 <<<"$(probe "$to")"
      if [ "$code2" = "200" ]; then
        ok "$url → 301 $to → 200"
      else
        ng "$url → 301 $to → $code2 ${location2}（1 回で届いていない）"
      fi
    done
  done

  read -r code location <<<"$(probe "https://www.$DOMAIN/")"
  case "$code" in
    301|308) ok "https://www.$DOMAIN/ → $code $location" ;;
    *) warn "https://www.$DOMAIN/ → ${code:-接続できない}（www を使わないなら問題なし）" ;;
  esac
}

check_dns
[ "$mode" = "all" ] && check_web

echo
if [ "$failures" -eq 0 ]; then
  echo "すべて OK"
  exit 0
fi
echo "NG: $failures 件"
exit 1
