# Neon ブランチ方針

**子ブランチは使わない。** `.env.example` と同じ。

- 役割つき URL（`BLT_NEON_READ_DATABASE_URL` / `BLT_NEON_WRITE_DATABASE_URL`）は、どちらも Neon の **本番ブランチ**。
- `BLT_NEON_DISPOSABLE_DATABASE_URL` は廃止。使い捨て Neon ブランチは削除済み。
- 探索・検証・スキーマのやり直しは手元のローカル Postgres（`.agents/skills/local-rest-testing/SKILL.md`）。本番ブランチを使い捨ての検証先にしない。
- 本番 write は `BLT_NEON_WRITE_DATABASE_URL` を明示したときだけ。RO への書き込みと本番 schema の削除は禁止（`AGENTS.md`）。
- エージェントは Neon の子ブランチを作らない（TTL 付きの短命ブランチも含む）。本番 default ブランチとその endpoint を変更しない。スナップショット復元の確定、default の付け替え、endpoint の付け替えもしない。
