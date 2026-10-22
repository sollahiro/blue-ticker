import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// Top feed の取得元。公開 RSS（`workers/feed-rss`。日次 19:15 JST に R2 へ生成）を読む。
/// HAPIS・トークン・オリジン・Neon を通らない。出すのは直近の有報（120）10 件だけ
/// （RSS は有報だけで、7 日窓＋期間に関係ない直近 10 件）。
/// 銘柄コードは `<category domain="jp:sec_code">` から取る（タイトルから読まない）。
/// 社名はタイトルの「社名（コード） 書類種別」から、コードの括弧より前を取る。
enum FeedRSS {
    static let url = URL(string: "https://feed.sollahiro.com/blue-ticker/edinet-filings.xml")!
    /// RSS の `Cache-Control: max-age=3600` に合わせる。前回の取得からこの間は再検証しない。
    static let revalidateInterval: TimeInterval = 60 * 60
    /// Top feed に出す書類種別。有報（120）だけ。RSS も有報だけだが、他の種別が混ざっても出さない。
    static let topFeedDocTypes: Set<String> = ["120"]
    /// Top feed に出す件数。REST の既定と同じ 10 件（RSS は有報を期間に関係なく直近 10 件載せる）。
    static let topFeedLimit = 10

    /// 解析した RSS から Top feed に出す行だけを残す（RSS の新しい順のまま先頭 `topFeedLimit` 件）。
    static func topFeed(_ items: [Item]) -> [Item] {
        Array(items.lazy.filter { topFeedDocTypes.contains($0.docType) }.prefix(topFeedLimit))
    }

    struct Item: Hashable, Identifiable, Sendable {
        var docId: String
        var code: String
        var name: String
        var docType: String
        var docTypeLabel: String
        /// JST の `YYYY-MM-DD HH:mm`（REST の `submitted_at` と同じ形）。`pubDate` が無ければ空。
        var submittedAt: String
        /// `<media:thumbnail url>`。アイコンの無い会社は `nil`。
        var iconURL: String?

        var id: String { docId }
    }

    /// 端末に保存する生の XML と検証子（`ETag` / `Last-Modified`）と取得時刻。
    struct Record: Codable, Equatable, Sendable {
        var xml: Data
        var etag: String?
        var lastModified: String?
        var fetchedAt: Date
    }

    enum Outcome: Equatable, Sendable {
        /// 304。保存済みの XML を使い続け、取得時刻（と届いた検証子）だけ進める。
        case notModified(Record)
        /// 200 で解析できた。保存を差し替えて画面を更新する。
        case replaced(Record, [Item])
        /// HTTP・解析の失敗。保存済みの分を出し続ける。
        case failed
    }

    /// 保存が無い、または前回の取得から `revalidateInterval` 以上経っていれば再検証する。
    /// 端末の時計が戻って取得時刻が未来になったときも再検証する。
    static func needsRevalidation(_ record: Record?, now: Date) -> Bool {
        guard let record else { return true }
        let age = now.timeIntervalSince(record.fetchedAt)
        return age < 0 || age >= revalidateInterval
    }

    /// 条件付き GET のヘッダ。保存が無ければ検証子を付けない（全件取得）。
    static func requestHeaders(for record: Record?) -> [String: String] {
        var headers = ["Accept": "application/rss+xml, application/xml;q=0.9, */*;q=0.1"]
        if let etag = record?.etag, !etag.isEmpty {
            headers["If-None-Match"] = etag
        }
        if let lastModified = record?.lastModified, !lastModified.isEmpty {
            headers["If-Modified-Since"] = lastModified
        }
        return headers
    }

    static func outcome(
        status: Int,
        etag: String?,
        lastModified: String?,
        body: Data,
        previous: Record?,
        now: Date
    ) -> Outcome {
        switch status {
        case 304:
            guard var record = previous else { return .failed }
            record.fetchedAt = now
            if let etag, !etag.isEmpty { record.etag = etag }
            if let lastModified, !lastModified.isEmpty { record.lastModified = lastModified }
            return .notModified(record)
        case 200..<300:
            guard let items = parse(body) else { return .failed }
            let record = Record(xml: body, etag: etag, lastModified: lastModified, fetchedAt: now)
            return .replaced(record, items)
        default:
            return .failed
        }
    }

    /// RSS 2.0 を解析する。XML として壊れている・`<rss>` でない・`</rss>` まで届いていなければ `nil`
    /// （途中で切れた本文で保存を差し替えない。Linux の `XMLParser` は途中切れでも成功を返す）。
    /// `guid`（doc_id）か `jp:sec_code` の無い item は飛ばす。
    static func parse(_ data: Data) -> [Item]? {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.closedRSS else { return nil }
        let dates = PubDateFormatter()
        return delegate.items.compactMap { raw in
            let docId = raw.guid.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = raw.secCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !docId.isEmpty, !code.isEmpty else { return nil }
            let title = splitTitle(raw.title, code: code)
            let icon = raw.thumbnail?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Item(
                docId: docId,
                code: code,
                name: title.name,
                docType: raw.docType.trimmingCharacters(in: .whitespacesAndNewlines),
                docTypeLabel: title.label,
                submittedAt: dates.jstMinute(raw.pubDate) ?? "",
                iconURL: (icon?.isEmpty ?? true) ? nil : icon
            )
        }
    }

    /// 「社名（コード） 書類種別」を分ける。コードの括弧が無ければタイトル全体を社名とみなす。
    static func splitTitle(_ raw: String, code: String) -> (name: String, label: String) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = title.range(of: "（\(code)）", options: .backwards) else {
            return (title, "")
        }
        let name = title[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? title : name, label)
    }

    /// `pubDate`（RFC 822。Worker は `+0900`）を JST の `YYYY-MM-DD HH:mm` にする。
    struct PubDateFormatter {
        private let input: DateFormatter
        private let output: DateFormatter

        init() {
            let posix = Locale(identifier: "en_US_POSIX")
            let jst = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 60 * 60)!
            input = DateFormatter()
            input.locale = posix
            input.calendar = Calendar(identifier: .gregorian)
            input.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            output = DateFormatter()
            output.locale = posix
            output.calendar = Calendar(identifier: .gregorian)
            output.timeZone = jst
            output.dateFormat = "yyyy-MM-dd HH:mm"
        }

        func jstMinute(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let date = input.date(from: trimmed) else { return nil }
            return output.string(from: date)
        }
    }

    private struct RawItem {
        var title = ""
        var guid = ""
        var pubDate = ""
        var docType = ""
        var secCode = ""
        var thumbnail: String?
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var items: [RawItem] = []
        var closedRSS = false
        private var openedRSS = false
        private var current: RawItem?
        private var field: String?
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "rss" {
                openedRSS = true
                return
            }
            if elementName == "item" {
                current = RawItem()
                return
            }
            guard current != nil else { return }
            switch elementName {
            case "title", "guid", "pubDate":
                field = elementName
            case "category":
                switch attributeDict["domain"] {
                case "jp:sec_code": field = "sec_code"
                case "edinet:doc_type": field = "doc_type"
                default: field = nil
                }
            case "media:thumbnail":
                if let url = attributeDict["url"] {
                    current?.thumbnail = url
                }
                field = nil
            default:
                field = nil
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard field != nil else { return }
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "rss" {
                closedRSS = openedRSS
                return
            }
            if elementName == "item" {
                if let current { items.append(current) }
                current = nil
                field = nil
                return
            }
            guard let name = field else { return }
            switch name {
            case "title": current?.title = text
            case "guid": current?.guid = text
            case "pubDate": current?.pubDate = text
            case "sec_code": current?.secCode = text
            case "doc_type": current?.docType = text
            default: break
            }
            field = nil
            text = ""
        }
    }
}
