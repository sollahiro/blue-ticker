// Feed RSS の抽出条件。`/v1/feed/updates`（Sources/BltServerCore/FeedServe.swift と
// Sources/BlueTicker/Server/FeedAssembly.swift）の listed 選択と揃える。
// 違いは同日過多の安定サンプリングをしないことだけ（RSS は窓内を時系列で全部出す）。

// Api.feedAllowedDocTypes（= 同期対象の全書類種別）。
export const FEED_DOC_TYPES = ["120", "130", "140", "160"];

// 直近 7 暦日（今日を含む）。`feedInclusiveCutoffDateString(days: 7)` に対応。
export const FEED_DAYS = 7;
export const FEED_ITEM_LIMIT = 200;

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

// listed 行の抽出。$1: 書類種別 text[]、$2: 下限日（含む）text、$3: 件数上限 int。
// 府令 010・5 桁 sec_code 末尾 0・00000 以外は Swift の feedListedQuery と同じ。
export const FEED_SQL = `SELECT doc_id, sec_code, filer_name, doc_type_code, ordinance_code, period_end, submit_date_time, doc_description
FROM edinet_documents
WHERE doc_type_code = ANY($1::text[])
  AND ordinance_code = '010'
  AND sec_code LIKE '____0'
  AND sec_code <> '00000'
  AND submit_date_time >= $2
ORDER BY submit_date_time DESC, doc_id DESC
LIMIT $3`;

// 有報（120）は期間に関係なく、新しい順にこの件数を必ず載せる。
// 7 暦日の窓は閑散期に有報が数件しか無く、iOS の Top feed（有報だけを出す）が
// REST の既定（有報 10 件）より少なくなるため。期間ではなく件数で区切るのは、
// 6 月の決算期に期間を延ばすと有報だけで FEED_ITEM_LIMIT を超えるから。
export const FEED_ANNUAL_DOC_TYPE = "120";
export const FEED_ANNUAL_MIN = 10;

// 有報の直近行。$1: 書類種別 text、$2: 件数 int。listed 条件は FEED_SQL と同じで、期間の下限だけ無い。
export const ANNUAL_SQL = `SELECT doc_id, sec_code, filer_name, doc_type_code, ordinance_code, period_end, submit_date_time, doc_description
FROM edinet_documents
WHERE doc_type_code = $1
  AND ordinance_code = '010'
  AND sec_code LIKE '____0'
  AND sec_code <> '00000'
ORDER BY submit_date_time DESC, doc_id DESC
LIMIT $2`;

// 窓の行と有報の直近行を doc_id で重複除去し、submit_date_time 降順・doc_id 降順に並べる。
// limit を超えたら有報の直近行以外を古い方から落とす（有報の直近行は必ず残る）。
export function mergeFeedRows(windowRows, annualRows, limit) {
  const byId = new Map();
  for (const row of [...annualRows, ...windowRows]) {
    if (row && typeof row.doc_id === "string" && !byId.has(row.doc_id)) {
      byId.set(row.doc_id, row);
    }
  }
  const pinned = new Set(annualRows.map((row) => row?.doc_id));
  const sorted = [...byId.values()].sort(compareRowsDesc);
  let excess = sorted.length - limit;
  if (excess <= 0) return sorted;
  const kept = [];
  for (let index = sorted.length - 1; index >= 0; index -= 1) {
    const row = sorted[index];
    if (excess > 0 && !pinned.has(row.doc_id)) {
      excess -= 1;
      continue;
    }
    kept.push(row);
  }
  return kept.reverse();
}

function compareRowsDesc(a, b) {
  const at = String(a.submit_date_time ?? "");
  const bt = String(b.submit_date_time ?? "");
  if (at !== bt) return at < bt ? 1 : -1;
  return a.doc_id < b.doc_id ? 1 : a.doc_id > b.doc_id ? -1 : 0;
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
