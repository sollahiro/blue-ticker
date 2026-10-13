// RSS 2.0 組み立て。テキストはすべて escapeXml 済みで埋め込む。
// pubDate / lastBuildDate は JST（+0900）の RFC 822 形式。

// XML 1.0 で使えない制御文字（タブ・LF・CR 以外の C0 と DEL・サロゲート領域）は除去する。
// eslint-disable-next-line no-control-regex
const INVALID_XML_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/g;

export function escapeXml(value) {
  return String(value ?? "")
    .replace(INVALID_XML_CHARS, "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

const pad2 = (n) => String(n).padStart(2, "0");

// JST 暦日時の部品から RFC 822 文字列。曜日は UTC 暦日から求める（JST は DST なし）。
function formatRfc822Jst(year, month, day, hour, minute, second) {
  const weekday = WEEKDAYS[new Date(Date.UTC(year, month - 1, day)).getUTCDay()];
  return `${weekday}, ${pad2(day)} ${MONTHS[month - 1]} ${year} ` +
    `${pad2(hour)}:${pad2(minute)}:${pad2(second)} +0900`;
}

// EDINET の submit_date_time（JST の壁時計）を RFC 822 へ。
// 受け付ける形: "YYYY-MM-DD HH:MM"、"YYYY-MM-DD HH:MM:SS"、区切りは "T" でもよい。
// 日付だけのときは 00:00 とみなす。パースできなければ null。
export function jstToRfc822(submittedAt) {
  if (typeof submittedAt !== "string") return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?$/.exec(
    submittedAt.trim()
  );
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = match[4] === undefined ? 0 : Number(match[4]);
  const minute = match[5] === undefined ? 0 : Number(match[5]);
  const second = match[6] === undefined ? 0 : Number(match[6]);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) {
    return null;
  }
  return formatRfc822Jst(year, month, day, hour, minute, second);
}

// JS Date（絶対時刻）を JST の RFC 822 へ。lastBuildDate 用。
export function utcToRfc822Jst(date) {
  const jst = new Date(date.getTime() + 9 * 60 * 60 * 1000);
  return formatRfc822Jst(
    jst.getUTCFullYear(),
    jst.getUTCMonth() + 1,
    jst.getUTCDate(),
    jst.getUTCHours(),
    jst.getUTCMinutes(),
    jst.getUTCSeconds()
  );
}

// EDINET 提出書類内容照会画面（doc_id で書類内容を見られる公開ビューア。API キー不要）。
// `?` は XML 上そのまま書いてよい（`&` が出る場合は escapeXml が `&amp;` にする）。
export const EDINET_VIEWER_URL_BASE =
  "https://disclosure2.edinet-fsa.go.jp/WZEK0040.aspx?";

export function edinetDocumentUrl(docId) {
  return EDINET_VIEWER_URL_BASE + encodeURIComponent(docId);
}

// RSS 2.0 本文。items は toFeedItem の戻り値。ヘッドラインのみ（アイコン・画像なし）。
export function buildRss({ items, now = new Date(), feedUrl }) {
  const lines = [];
  lines.push('<?xml version="1.0" encoding="UTF-8"?>');
  lines.push('<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">');
  lines.push("  <channel>");
  lines.push("    <title>Blue Ticker — EDINET 提出書類（上場）</title>");
  // チャネル link はアプリ紹介ページ。sollahiro.com/blue-ticker/ は
  // workers/legal（src/index.js の assetPathFor が /blue-ticker を privacy へ回す）
  // が実際に配信しているので、この URL を使う（存在しない場合は feedUrl にする想定だった）。
  lines.push("    <link>https://sollahiro.com/blue-ticker/</link>");
  lines.push(
    "    <description>EDINET に提出された上場会社の開示書類のヘッドラインのみを配信します。" +
      "毎日 19:15（JST）に更新。対象は有価証券報告書（120）・訂正有価証券報告書（130）・" +
      "四半期報告書（140）・半期報告書（160）の直近7日分です。</description>"
  );
  lines.push("    <language>ja</language>");
  lines.push(`    <lastBuildDate>${utcToRfc822Jst(now)}</lastBuildDate>`);
  lines.push("    <ttl>1440</ttl>");
  lines.push(
    `    <atom:link href="${escapeXml(feedUrl)}" rel="self" type="application/rss+xml"/>`
  );
  for (const item of items) {
    lines.push("    <item>");
    lines.push(
      `      <title>${escapeXml(`${item.name}（${item.code}） ${item.doc_type_label}`)}</title>`
    );
    lines.push(`      <link>${escapeXml(edinetDocumentUrl(item.doc_id))}</link>`);
    lines.push(`      <guid isPermaLink="false">${escapeXml(item.doc_id)}</guid>`);
    const pubDate = jstToRfc822(item.submitted_at);
    if (pubDate !== null) {
      lines.push(`      <pubDate>${pubDate}</pubDate>`);
    }
    lines.push(
      `      <category domain="edinet:doc_type">${escapeXml(item.doc_type)}</category>`
    );
    lines.push(
      `      <category domain="jp:sec_code">${escapeXml(item.code)}</category>`
    );
    lines.push(
      `      <description>${escapeXml(`決算期: ${item.fy_end} / 証券コード: ${item.code}`)}</description>`
    );
    lines.push("    </item>");
  }
  lines.push("  </channel>");
  lines.push("</rss>");
  return lines.join("\n") + "\n";
}
