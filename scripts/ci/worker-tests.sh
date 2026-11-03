#!/usr/bin/env bash
# Cloudflare Worker の単体テスト（node --test、依存インストール不要）。
# CI の static-checks と、各 Worker のデプロイ workflow（デプロイするのと同じコミットで
# 検証してから出す）の両方がこれを呼ぶ。テストファイルは workers/<name>/src/*.test.js。
# Usage: scripts/ci/worker-tests.sh [worker ...]   （省略時は workers/ 配下の全 Worker）
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [[ $# -eq 0 ]]; then
  set -- $(cd workers && ls -d */ | tr -d /)
fi
for w in "$@"; do
  shopt -s nullglob
  tests=(workers/"$w"/src/*.test.js)
  shopt -u nullglob
  if [[ ${#tests[@]} -eq 0 ]]; then
    echo "::error::workers/$w/src にテストがありません" >&2
    exit 1
  fi
  echo "== $w: ${tests[*]}"
  node --test "${tests[@]}"
done
