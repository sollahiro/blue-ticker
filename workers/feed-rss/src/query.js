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
