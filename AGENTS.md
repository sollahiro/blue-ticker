# AGENTS.md
- 詳細設計は `docs/`、禁止事項は `.agents/rules/`、定型作業は `.agents/skills/` を正本とし、該当作業の文書だけ読む。
- XBRL は実データで検証し、注記抽出は原本 HTML と照合する。statement・notes・breakdown には可能な限り由来 XBRL タグを載せる。
- 依存方向は `BltServer` → `BltServerCore` → `BlueTickerCore` / `BltMcpServerCore`。Core は Vapor / Fluent 非依存。
- `BlueTickerCore` の `Analysis/`・`API/`・`Infrastructure/`・`Utils/` から `Services/`・`Server/` を参照しない。`Services/` から `Server/` も参照しない。
- 市場は `JP` / `EU`、開示 Source は `EDINET` / `ESEF` として混同しない。
- 本番 write は `BLT_NEON_WRITE_DATABASE_URL` の明示指定時だけ行う。RO への書き込みと本番 schema の削除は禁止。
- Cursor Cloud の build / test は `-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility` を付ける。
- 新機能・XBRL・本番 ingest・release・tracker 操作は対応する `.agents/skills/` に従う。
- 外部 API・CLI・DB schema・設定・公開契約の変更と、本番 write / 公開範囲の拡張はユーザー確認なしに行わない。
