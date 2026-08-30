---
name: production-ingest
description: Neon を使った disposable 検証、本番 ingest、RO 同期、訂正有報の手動処理を行うときに使う。
---

# Neon ingest

## 正本

- Stage の順序・ジョブ編成: `docs/ingest-policy.md`
- CLI と障害対応: `.agents/skills/deploy/SKILL.md`
- 接続変数: `.env.example`
- 訂正有報: `.agents/rules/amendments.md`

## 接続境界

- アプリが読む接続スロットは `DATABASE_URL` だけ。通常の手元検証では `BLT_NEON_DISPOSABLE_DATABASE_URL` を束ねる。
- `BLT_NEON_RO_DATABASE_URL` は SELECT 専用で、WRITE 親の自動同期 replica ではない。`autoMigrate` があるため RO を `DATABASE_URL` にしてサーバーを起動しない。
- 本番 write はユーザーが明示した場合だけ、コマンド単位で `DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL"` を指定する。手元 `.env` の既定を WRITE に変更しない。
- Fly は配信 read 専用。本番 write ingest はローカルから実行する。
- 本番および RO で `DROP`、探索 ingest、未検証ロジックの書き込みを行わない。

## 手順

1. `.agents/skills/xbrl-development/SKILL.md` のローカル検証を終え、disposable で対象・件数・配信結果を確認する。
2. 本番対象、Stage、母集団、公開範囲についてユーザー確認を得る。
3. `docs/ingest-policy.md` の分割・順序に従い、WRITE URL をコマンド単位で明示して ingest する。
4. `needs_review`、あいまい失敗、異常欠測、訂正有報130は自動処理せず手動確認する。
5. ingest 成功後、必要な4変数が揃っていれば `scripts/neon-reset-ro-from-parent.sh` で RO を親 HEAD に同期する。同期失敗と ingest 成否は分けて報告する。
6. 件数とゲートの現在地は `.agents/skills/tracker/SKILL.md` に従って Linear へ記録する。

## Disposable の 42P07

テーブルが存在し `_fluent_migrations` が空の場合だけ、接続先が disposable でデータが空であることを確認して schema を再作成する。本番・ROには適用しない。
