# 訂正有報（130）

- sync は 130 を別行で取り込む。`parent_doc_id` に EDINET `parentDocID`（訂正対象）を保持する。
- 通常 ingest の**行の identity**（`company_statement_notes.doc_id` / financials の年度帰属 / 公開 `doc_id`）は原本 120 のまま。
- **overlay**: 同一会社・同一期間・同一親有報の 130 を、提出が古い順に原本の XBRL へ重ねる。キーは element + context（期間/member/dimension）。訂正に無い項目は原本の値を残す。複数あれば後勝ち。パースできない 130 は飛ばす。
- **行メンバー表**（`Row{N}Member`、政策保有株式など）: 訂正がその表の fact を含めば行ごと置換する（セル混在しない）。
- **TextBlock**: 訂正に同じ要素があればその本文で置き換える。無ければ原本。HTML 見出し抽出（filing-sections の honbun、US-GAAP 0105010 本表）は原本 HTML を読む。
- 財務 high-water に 130 を含める（再計算トリガ）。読む ZIP は原本＋ overlay。
- 150 / 170 は対象外。専用キューや自動統合経路は作らない。
- 対象会社-FY の再 ingest は `--doc-ids <原本120>`（`--codes` と併用可）。保持窓外でも指定 doc は残し、他 FY は purge しない。
- ingest の訂正引き当ては in-flight の原本 `doc_id`（keep / `--doc-ids`）または証券コード（`--codes` / 会社単位ステージ）に限定する。全件 120/130 は読まない。
