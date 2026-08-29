// Feed Update の公開 JSON 組み立て（DB 非依存）。

import Foundation
import Testing

@testable import BlueTickerCore

private func rec(
    _ docID: String,
    secCode: String? = "72030",
    filerName: String = "トヨタ自動車株式会社",
    docType: String = "120",
    ordinanceCode: String? = "010",
    periodEnd: String = "2025-03-31",
    submit: String
) -> EdinetDocumentRecord {
    EdinetDocumentRecord(
        docID: docID, edinetCode: "E00001", secCode: secCode, filerName: filerName,
        docTypeCode: docType, ordinanceCode: ordinanceCode, formCode: "030000",
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
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 12))!
        let records = [
            rec("S1", submit: "2026-06-20 09:00"),
            rec("S2", secCode: nil, filerName: "某ファンド", submit: "2026-06-20 10:00"),
            rec("S3", secCode: "67580", filerName: "ソニーグループ株式会社", submit: "2026-06-19 08:00"),
        ]
        let json = assembleFeedUpdates(
            from: records, limit: 10, days: 7, docTypes: ["120"], now: now)
        #expect(json["schema_version"] as? Int == Api.feedSchemaVersion)
        #expect(json["date"] as? String == "2026-06-20")
        #expect(json["days"] as? Int == 7)
        let total = json["total"] as? [String: Any]
        #expect(total?["day"] as? Int == 1)
        #expect(total?["week"] as? Int == 2)
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
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 12))!
        let records = (0..<8).map { rec("S\($0)", submit: "2026-06-2\(7 - $0) 09:00") }
        let json = assembleFeedUpdates(
            from: records, limit: 3, days: 7, docTypes: ["120"], now: now)
        let items = json["items"] as? [[String: Any]]
        let total = json["total"] as? [String: Any]
        #expect(items?.count == 3)
        #expect(total?["day"] as? Int == 1)
        #expect(total?["week"] as? Int == 7)
        #expect(items?.compactMap { $0["doc_id"] as? String } == ["S0", "S1", "S2"])
    }

    @Test func updatesTotalSplitsTodayAndWeekIndependentOfItemDays() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 8))!
        let records = [
            rec("TODAY", submit: "2026-08-22 09:00"),
            rec("YDAY", secCode: "67580", filerName: "ソニーグループ株式会社", submit: "2026-08-21 09:00"),
            rec("WEEK", secCode: "99840", filerName: "ソフトバンクグループ株式会社",
                submit: "2026-08-16 09:00"),
            rec("OLD", submit: "2026-08-10 09:00"),
        ]
        let json = assembleFeedUpdates(
            from: records, limit: 10, days: 1, docTypes: ["120"], now: now)
        let total = json["total"] as? [String: Any]
        #expect(json["date"] as? String == "2026-08-22")
        #expect(total?["day"] as? Int == 1)
        #expect(total?["week"] as? Int == 3)
        let items = json["items"] as? [[String: Any]]
        #expect(items?.compactMap { $0["doc_id"] as? String } == ["TODAY"])
    }

    @Test func feedInclusiveCutoffDateStringIsUTCHyphenated() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 7))!
        #expect(feedDateString(now) == "2026-08-22")
        #expect(feedInclusiveCutoffDateString(days: 1, now: now) == "2026-08-22")
        #expect(feedInclusiveCutoffDateString(days: 7, now: now) == "2026-08-16")
        #expect(feedSubmitDatePrefix("2026-08-22 09:00") == "2026-08-22")
    }

    @Test func updatesSkipTrustBeneficiaryOrdinance030() {
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 12))!
        let records = [
            rec("S100YCDE", submit: "2026-06-16 11:38"),
            rec("S100YZ8K", ordinanceCode: "030", submit: "2026-08-28 16:00"),
        ]
        let json = assembleFeedUpdates(
            from: records, limit: 10, days: 7, docTypes: ["120"], now: now)
        let items = json["items"] as? [[String: Any]]
        #expect(items?.compactMap { $0["doc_id"] as? String } == [])
        let total = json["total"] as? [String: Any]
        #expect(total?["day"] as? Int == 0)
        #expect(total?["week"] as? Int == 0)
    }
}
