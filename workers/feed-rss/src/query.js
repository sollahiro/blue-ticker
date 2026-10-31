// Feed RSS の抽出条件。`/v1/feed/updates`（Sources/BltServerCore/FeedServe.swift と
// Sources/BlueTicker/Server/FeedAssembly.swift）の listed 判定と揃える。
// 違いは 2 つ。RSS に載せる書類種別は有報（120）だけ（RSS_DOC_TYPES）で、
// 同日過多の安定サンプリングもしない（RSS は窓内を時系列で全部出す）。

// Api.feedAllowedDocTypes（= 同期対象の全書類種別）。parity.test.js が fixture / Swift と照合する。
// RSS の抽出には使わない（同期・REST / MCP のフィードの種別はこちら）。
export const FEED_DOC_TYPES = ["120", "130", "140", "160"];

// 公開 RSS に載せる書類種別。有価証券報告書（120）だけ。訂正（130）・四半期（140）・半期（160）は出さない。
// FEED_DOC_TYPES の部分集合であること（parity.test.js）。
export const RSS_DOC_TYPES = ["120"];

// 直近 14 暦日（今日を含む）。iOS の Top feed（ホームのキュレーション）が直近 2 週間を出すため。
// 下限の数え方は `feedInclusiveCutoffDateString(days:)` と同じ。REST / MCP のフィードの期間とは別。
export const FEED_DAYS = 14;
export const FEED_ITEM_LIMIT = 200;

// 有報は期間に関係なく、新しい順にこの件数を必ず載せる。
// 14 暦日の窓でも閑散期は有報が数件しか無く、iOS の Top feed（有報だけを出す）が
// REST の既定（有報 10 件）より少なくなるため。期間ではなく件数で区切るのは、
// 6 月の決算期に期間を延ばすと有報だけで FEED_ITEM_LIMIT を超えるから。
export const FEED_LATEST_MIN = 10;

// 会社開示府令（Api.ordinanceCompanyDisclosure）。
export const ORDINANCE_COMPANY_DISCLOSURE = "010";

// 今日を含む UTC 暦日数の下限（YYYY-MM-DD、下限含む）。
// Swift の feedInclusiveCutoffDateString と同じ: 今日から days-1 日前。
export function feedCutoffDateString(days, now = new Date()) {
  const back = Math.max(days, 1) - 1;
  const ms = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) -
    back * 24 * 60 * 60 * 1000;
  return new Date(ms).toISOString().slice(0, 10);
}

// listed 行の抽出。$1: 書類種別 text[]、$2: 件数上限 int。期間の下限は selectFeedRows で切る。
// 府令 010・5 桁 sec_code 末尾 0・00000 以外は Swift の feedListedQuery と同じ。
export const FEED_SQL = `SELECT doc_id, sec_code, filer_name, doc_type_code, ordinance_code, period_end, submit_date_time, doc_description
FROM edinet_documents
WHERE doc_type_code = ANY($1::text[])
  AND ordinance_code = '010'
  AND sec_code LIKE '____0'
  AND sec_code <> '00000'
ORDER BY submit_date_time DESC, doc_id DESC
LIMIT $2`;

// FEED_SQL の行（submit_date_time 降順・doc_id 降順、最大 FEED_ITEM_LIMIT 件）から、
// 先頭 minCount 件か、下限日（含む）以降の行を残す。行は新しい順なので結果は先頭からの連続区間。
// 「窓（下限日以降を最大 limit 件）＋有報の直近 minCount 件を doc_id で重複除去し、
// 上限超過時は直近 minCount 件以外を古い方から落とす」と同じ結果になる（query.test.js）。
export function selectFeedRows(rows, cutoff, minCount) {
  return rows.filter(
    (row, index) => index < minCount || String(row?.submit_date_time ?? "") >= cutoff
  );
}

// 会社アイコンの R2 オブジェクトキー。$1: 4 桁コード text[]。
// company_icons は 1 社 1 行（主キー code）。公開 URL は REST の icon_url と同じく
// `{公開ベース URL}/{r2_object_key}`（Swift R2PublicURLConfig.publicURL(forKey:)）。
export const ICON_SQL = `SELECT code, r2_object_key
FROM company_icons
WHERE code = ANY($1::text[])`;

// Swift buildR2PublicURL(baseURL:key:) と同じ連結。
export function iconPublicUrl(baseUrl, key) {
  return `${baseUrl}/${key}`;
}

// 上場の 4 桁コード。5 桁かつ末尾 0 のときだけ。`00000`（未割当）は上場にしない。
// Swift の listedTickerCode(fromSecCode:) と同じ。
export function listedTickerCode(secCode) {
  if (typeof secCode !== "string" || secCode.length !== 5 || !secCode.endsWith("0")) {
    return null;
  }
  const code = secCode.slice(0, 4);
  if (![...code].some((ch) => ch !== "0")) return null;
  return code;
}

// EDINET 書類種別コード → 表示ラベル。Swift の docTypeLabel(_:) と同じ。
export const DOC_TYPE_LABELS = {
  "120": "有価証券報告書",
  "130": "訂正有価証券報告書",
  "140": "四半期報告書",
  "150": "訂正四半期報告書",
  "160": "半期報告書",
  "170": "訂正半期報告書",
};

// 未知コードは docDescription へフォールバック。
export function docTypeLabel(code, docDescription) {
  return DOC_TYPE_LABELS[code] ?? docDescription;
}

// 1 書類の公開フィード行。Swift の feedFilingItem / filingDict と同じ形。
// 会社開示府令以外・上場コードが取れない行は null（呼び出し側で落とす）。
// fy_end は期末日（YYYY-MM-DD）の先頭 7 文字（YYYY-MM）。
export function toFeedItem(row) {
  if (
    row.ordinance_code !== undefined &&
    row.ordinance_code !== ORDINANCE_COMPANY_DISCLOSURE
  ) {
    return null;
  }
  const code = listedTickerCode(row.sec_code);
  if (!code) return null;
  const rawFyEnd = row.period_end ?? "";
  const fyEnd = rawFyEnd.length >= 7 ? rawFyEnd.slice(0, 7) : rawFyEnd;
  const docType = row.doc_type_code ?? "";
  return {
    code,
    name: row.filer_name,
    doc_id: row.doc_id,
    doc_type: docType,
    doc_type_label: docTypeLabel(docType, row.doc_description ?? ""),
    fy_end: fyEnd,
    submitted_at: row.submit_date_time,
  };
}
