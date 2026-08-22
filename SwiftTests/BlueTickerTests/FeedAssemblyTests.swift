// Feed Update / Trend の公開 JSON 組み立て（DB 非依存）。

import Foundation
import Testing

@testable import BlueTickerCore

private func rec(
    _ docID: String,
    secCode: String? = "72030",
    filerName: String = "トヨタ自動車株式会社",
    docType: String = "120",
    periodEnd: String = "2025-03-31",
    submit: String
) -> EdinetDocumentRecord {
    EdinetDocumentRecord(
        docID: docID, edinetCode: "E00001", secCode: secCode, filerName: filerName,
        docTypeCode: docType, ordinanceCode: "010", formCode: "030000",
        periodStart: "2024-04-01", periodEnd: periodEnd,
        submitDateTime: submit, docDescription: "有価証券報告書")
}

@Suite struct FeedAssemblyTests {
    @Test func parseLimitClampsAndDefaults() {
        #expect(parseFeedLimit(nil) == Api.feedLimitDefault)
        #expect(parseFeedLimit(0) == Api.feedLimitDefault)
        #expect(parseFeedLimit(-3) == Api.feedLimitDefault)
        #expect(parseFeedLimit(20) == 20)
        #expect(parseFeedLimit(Api.feedLimitMax + 50) == Api.feedLimitMax)
    }

    @Test func parseDaysClampsAndDefaults() {
        #expect(parseFeedDays(nil) == Api.feedTrendDaysDefault)
        #expect(parseFeedDays(0) == Api.feedTrendDaysDefault)
        #expect(parseFeedDays(30) == 30)
        #expect(parseFeedDays(Api.feedTrendDaysMax + 1) == Api.feedTrendDaysMax)
    }

    @Test func parseDocTypesDropsUnknownAndDefaultsToAnnual() {
        #expect(parseFeedDocTypes(nil) == Api.feedDefaultDocTypes)
        #expect(parseFeedDocTypes("") == Api.feedDefaultDocTypes)
        #expect(parseFeedDocTypes("999") == Api.feedDefaultDocTypes)
        #expect(parseFeedDocTypes("120,160,120,999") == ["120", "160"])
        #expect(parseFeedDocTypes(" 130 ") == ["130"])
    }

    @Test func listedTickerCodeRequiresFiveDigitSuffixZero() {
        #expect(listedTickerCode(fromSecCode: "72030") == "7203")
        #expect(listedTickerCode(fromSecCode: nil) == nil)
        #expect(listedTickerCode(fromSecCode: "7203") == nil)
        #expect(listedTickerCode(fromSecCode: "72031") == nil)
    }

    @Test func updatesAreChronologicalDocumentsAndSkipUnlisted() {
        let records = [
            rec("S1", submit: "2026-06-20 09:00"),
            rec("S2", secCode: nil, filerName: "某ファンド", submit: "2026-06-21 10:00"),
            rec("S3", secCode: "67580", filerName: "ソニーグループ株式会社", submit: "2026-06-19 08:00"),
        ]
        let json = assembleFeedUpdates(from: records, limit: 10, docTypes: ["120"])
        #expect(json["schema_version"] as? Int == Api.feedSchemaVersion)
        #expect(json["doc_types"] as? [String] == ["120"])
        let items = json["items"] as? [[String: Any]]
        #expect(items?.compactMap { $0["doc_id"] as? String } == ["S1", "S3"])
        #expect(items?.first?["code"] as? String == "7203")
        #expect(items?.first?["name"] as? String == "トヨタ自動車株式会社")
        #expect(items?.first?["doc_type"] as? String == "120")
        #expect(items?.first?["submitted_at"] as? String == "2026-06-20 09:00")
        #expect(items?.first?["filing_count"] == nil)
    }

    @Test func updatesRespectLimit() {
        let records = (0..<8).map { rec("S\($0)", submit: "2026-06-2\(7 - $0) 09:00") }
        let json = assembleFeedUpdates(from: records, limit: 3, docTypes: ["120"])
        let items = json["items"] as? [[String: Any]]
        #expect(items?.count == 3)
        #expect(items?.compactMap { $0["doc_id"] as? String } == ["S0", "S1", "S2"])
    }

    @Test func trendRanksByCountThenRecency() {
        let records = [
            rec("T-late", submit: "2026-08-20 18:00"),
            rec("S-2", secCode: "67580", filerName: "ソニーグループ株式会社", submit: "2026-08-19 12:00"),
            rec("S-1", secCode: "67580", filerName: "ソニーグループ株式会社", docType: "160",
                periodEnd: "2025-09-30", submit: "2026-08-18 09:00"),
            rec("U-1", secCode: "99840", filerName: "ソフトバンクグループ株式会社", submit: "2026-08-10 09:00"),
        ]
        let json = assembleFeedTrend(from: records, limit: 10, days: 30, docTypes: ["120", "160"])
        #expect(json["days"] as? Int == 30)
        let items = json["items"] as? [[String: Any]]
        #expect(items?.compactMap { $0["code"] as? String } == ["6758", "7203", "9984"])
        #expect(items?.first?["filing_count"] as? Int == 2)
        #expect(items?.first?["doc_id"] as? String == "S-2")
        #expect(items?[1]["filing_count"] as? Int == 1)
        #expect(items?[1]["doc_id"] as? String == "T-late")
    }

    @Test func feedCutoffDateStringIsUTCHyphenated() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 7))!
        #expect(feedCutoffDateString(days: 7, now: now) == "2026-08-15")
    }
}
