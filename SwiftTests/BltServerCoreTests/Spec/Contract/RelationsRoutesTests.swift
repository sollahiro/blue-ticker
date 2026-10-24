// 関係の公開 REST（GET /v1/companies/{code}/relations）の仕様。
// インメモリ SQLite に company_relations を作り、格納行から応答（逆引き・公開可否・省略・ページング）を見る。
// 社名は同梱の EDINET コードリストから引く。

import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import BlueTickerCore
@testable import BltServerCore

private func withRelationsApp(
    databases: Bool = true, _ body: (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        if databases {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CreateCompanyRelations())
            try await app.autoMigrate()
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-relations-tests-\(UUID().uuidString)", isDirectory: true)
        try await registerRoutes(app, context: BltServerContext(apiKey: "test-key", cacheDir: dir))
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

private func send(_ app: Application, _ path: String) async throws -> (HTTPResponseStatus, [String: Any]?) {
    let request = Request(
        application: app, method: .GET, url: URI(string: path), on: app.eventLoopGroup.next())
    let response = try await app.responder.respond(to: request).get()
    var json: [String: Any]?
    if let string = response.body.string, let data = string.data(using: .utf8) {
        json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    return (response.status, json)
}

private func seed(
    _ app: Application, code: String, docID: String = "S100TEST", section: String, kind: String,
    position: Int = 0, name: String, relatedCode: String? = nil, resolution: String? = nil,
    decidedBy: String = relationDecidedByRule, needsReview: Bool = false, amount: Double? = nil,
    votingRatio: Double? = nil, rank: Int? = nil, ratio: Double? = nil, shares: Double? = nil,
    bookValue: Double? = nil, address: String? = nil, sectionStatus: String? = nil,
    warning: String? = nil
) async throws {
    let draft = CompanyRelationDraft(
        section: section, kind: kind, position: position, nameRaw: name, amountYen: amount,
        votingRatio: votingRatio, decidedBy: decidedBy, needsReview: needsReview, shares: shares,
        bookValueYen: bookValue, isDeemed: kind == relationKindInvestee ? false : nil,
        holder: kind == relationKindInvestee ? relationHolderReportingCompany : nil, ratio: ratio,
        rank: rank, address: address, sectionStatus: sectionStatus)
    let row = CompanyRelation(
        code: code, docID: docID, submitDateTime: "2026-06-20 09:00", fyEnd: "2026-03-31",
        draft: draft, warning: warning)
    row.relatedCode = relatedCode
    row.resolution = resolution ?? (kind == relationKindNone ? nil : relatedCode == nil ? relationResolutionUnresolved : relationResolutionNameExact)
    try await row.create(on: app.db)
}

private func relations(_ json: [String: Any]?) -> [[String: Any]] {
    json?["relations"] as? [[String: Any]] ?? []
}

@Suite struct RelationsRoutesTests {

    @Test func returns503WithoutDatabase() async throws {
        try await withRelationsApp(databases: false) { app in
            let (status, _) = try await send(app, "/v1/companies/9409/relations")
            #expect(status == .serviceUnavailable)
        }
    }

    @Test func returns400ForUnknownTypeAndInvalidCode() async throws {
        try await withRelationsApp { app in
            let (unknown, json) = try await send(app, "/v1/companies/9409/relations?type=competitor")
            #expect(unknown == .badRequest)
            #expect((json?["error"] as? String)?.contains("competitor") == true)
            let (badCode, _) = try await send(app, "/v1/companies/94/relations")
            #expect(badCode == .badRequest)
        }
    }

    @Test func returns404WhenNothingIngested() async throws {
        try await withRelationsApp { app in
            let (status, _) = try await send(app, "/v1/companies/9409/relations")
            #expect(status == .notFound)
        }
    }

    @Test func customerWithListedCompanyAndEvidence() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "9409", section: relationSectionMainCustomers, kind: relationKindCustomer,
                name: "㈱電通", relatedCode: "4324", resolution: relationResolutionViaListedParent,
                amount: 95_235_000_000)
            let (status, json) = try await send(app, "/v1/companies/9409/relations?type=customer")
            #expect(status == .ok)
            let items = relations(json)
            #expect(items.count == 1)
            let item = try #require(items.first)
            #expect(item["type"] as? String == "customer")
            #expect(item["basis"] as? String == "disclosed")
            #expect(item["reasons"] as? [String] == [relationResolutionViaListedParent])
            #expect(item["name_raw"] as? String == "㈱電通")
            #expect(item["amount_yen"] as? Double == 95_235_000_000)
            let company = item["company"] as? [String: Any]
            #expect(company?["code"] as? String == "4324")
            #expect(company?["name"] as? String == "株式会社電通グループ")
            let evidence = item["evidence"] as? [String: Any]
            #expect(evidence?["doc_id"] as? String == "S100TEST")
            #expect(evidence?["from_code"] as? String == "9409")
            #expect(evidence?["section"] as? String == relationSectionMainCustomers)
            #expect(item["needs_review"] == nil)
            #expect(Set(item.keys) == Set(CompanyRelationItem.CodingKeys.allCases.map(\.rawValue)))
            #expect(Set(json?.keys.map { $0 } ?? []) == Set(CompanyRelationsResponse.CodingKeys.allCases.map(\.rawValue)))
        }
    }

    @Test func supplierIsReverseLookupOfCounterpartyCustomer() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "9409", section: relationSectionMainCustomers, kind: relationKindCustomer,
                name: "㈱電通", relatedCode: "4324", resolution: relationResolutionViaListedParent,
                amount: 95_235_000_000)
            let (status, json) = try await send(app, "/v1/companies/4324/relations?type=supplier")
            #expect(status == .ok)
            let item = try #require(relations(json).first)
            #expect(item["type"] as? String == "supplier")
            #expect((item["company"] as? [String: Any])?["code"] as? String == "9409")
            #expect(
                item["reasons"] as? [String]
                    == [relationReasonDisclosedByCounterparty, relationResolutionViaListedParent])
            #expect((item["evidence"] as? [String: Any])?["from_code"] as? String == "9409")
        }
    }

    @Test func groupFilterAndReverseParentMerge() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "4324", section: relationSectionAffiliatedEntities, kind: relationKindSubsidiary,
                position: 0, name: "㈱電通", votingRatio: 100)
            try await seed(
                app, code: "4324", section: relationSectionAffiliatedEntities, kind: relationKindAffiliate,
                position: 1, name: "㈱関連", votingRatio: 30)
            try await seed(
                app, code: "4812", section: relationSectionAffiliatedEntities, kind: relationKindParent,
                position: 0, name: "株式会社電通グループ", relatedCode: "4324", votingRatio: 61.8)
            try await seed(
                app, code: "4324", section: relationSectionAffiliatedEntities, kind: relationKindSubsidiary,
                position: 2, name: "株式会社電通総研", relatedCode: "4812", votingRatio: 61.8)

            let (status, json) = try await send(app, "/v1/companies/4324/relations?type=subsidiary")
            #expect(status == .ok)
            let items = relations(json)
            #expect(items.count == 2)
            // 上場（company あり）を先に、自社の行と逆引きは同じ相手でまとめる。
            #expect((items[0]["company"] as? [String: Any])?["code"] as? String == "4812")
            #expect(
                items[0]["reasons"] as? [String]
                    == [relationResolutionNameExact, relationReasonDisclosedByCounterparty])
            #expect(items[0]["voting_ratio"] as? Double == 61.8)
            #expect(items[0]["voting_ratio_basis"] as? String == relationVotingRatioBasisOwned)
            #expect(items[1]["company"] is NSNull)
            #expect(items.allSatisfy { $0["type"] as? String == "group" })

            let (_, affiliate) = try await send(app, "/v1/companies/4324/relations?type=affiliate")
            #expect(relations(affiliate).map { $0["kind"] as? String } == ["affiliate"])

            let (_, parent) = try await send(app, "/v1/companies/4812/relations?type=parent")
            #expect(relations(parent).count == 1)
            #expect((relations(parent).first?["company"] as? [String: Any])?["code"] as? String == "4324")
            // 親会社の行の議決権は被所有（4324 が 4812 の 61.8% を持つ）。
            #expect(relations(parent).first?["voting_ratio_basis"] as? String == relationVotingRatioBasisOwnedBy)
        }
    }

    @Test func jevRowsAreTaggedAndJevNeedsReviewIsHidden() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "1111", section: relationSectionAffiliatedEntities, kind: relationKindSubsidiary,
                position: 0, name: "株式会社ジェブ決定", decidedBy: relationDecidedByJev)
            try await seed(
                app, code: "1111", section: relationSectionAffiliatedEntities, kind: relationKindUnclassified,
                position: 1, name: "株式会社未決定", decidedBy: relationDecidedByJev, needsReview: true)
            try await seed(
                app, code: "1111", section: relationSectionAffiliatedEntities, kind: relationKindAffiliate,
                position: 2, name: "株式会社保留", decidedBy: relationDecidedByJev, needsReview: true)
            let (_, json) = try await send(app, "/v1/companies/1111/relations?type=group")
            let items = relations(json)
            #expect(items.map { $0["name_raw"] as? String } == ["株式会社ジェブ決定"])
            #expect(
                items.first?["reasons"] as? [String]
                    == [relationReasonJevClassified, relationResolutionUnresolved])
        }
    }

    @Test func ambiguousRowIsServedWithNullCompany() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "1111", section: relationSectionMainCustomers, kind: relationKindCustomer,
                name: "株式会社あいまい", resolution: relationResolutionAmbiguous, needsReview: true)
            let (status, json) = try await send(app, "/v1/companies/1111/relations")
            #expect(status == .ok)
            let item = try #require(relations(json).first)
            #expect(item["company"] is NSNull)
            #expect(item["needs_review"] == nil)
            #expect(item["reasons"] as? [String] == [relationResolutionAmbiguous])
        }
    }

    @Test func jevClassifiedRowWithAmbiguousNameIsServed() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "1111", section: relationSectionAffiliatedEntities, kind: relationKindAffiliate,
                name: "株式会社あいまい", resolution: relationResolutionAmbiguous,
                decidedBy: relationDecidedByJev, needsReview: true)
            let (status, json) = try await send(app, "/v1/companies/1111/relations?type=group")
            #expect(status == .ok)
            let item = try #require(relations(json).first)
            #expect(item["company"] is NSNull)
            #expect(item["reasons"] as? [String] == [relationReasonJevClassified, relationResolutionAmbiguous])
        }
    }

    @Test func reverseLookupIsOneItemPerCounterparty() async throws {
        try await withRelationsApp { app in
            // 9409 が顧客欄に 4324 本体と 4324 の子会社を両方載せている。
            try await seed(
                app, code: "9409", section: relationSectionMainCustomers, kind: relationKindCustomer,
                position: 0, name: "㈱電通", relatedCode: "4324", resolution: relationResolutionViaListedParent,
                amount: 95_000_000_000)
            try await seed(
                app, code: "9409", section: relationSectionMainCustomers, kind: relationKindCustomer,
                position: 1, name: "株式会社電通グループ", relatedCode: "4324", amount: 10_000_000_000)
            try await seed(
                app, code: "4324", section: relationSectionMajorShareholders, kind: relationKindMajorShareholder,
                position: 0, name: "テスト", rank: 1, ratio: 0.1)
            let (_, json) = try await send(app, "/v1/companies/4324/relations?type=supplier")
            let items = relations(json)
            #expect(items.count == 1)
            #expect(items.first?["amount_yen"] as? Double == 95_000_000_000)
            #expect(
                items.first?["reasons"] as? [String]
                    == [relationReasonDisclosedByCounterparty, relationResolutionViaListedParent,
                        relationResolutionNameExact])
        }
    }

    @Test func returns404WhenNoRowIsServable() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "1111", section: relationSectionAffiliatedEntities, kind: relationKindAffiliate,
                name: "株式会社保留", decidedBy: relationDecidedByJev, needsReview: true)
            try await seed(
                app, code: "2222", section: relationSectionMainCustomers, kind: relationKindCustomer,
                name: "株式会社訂正", warning: "overlay_regression")
            let (jev, _) = try await send(app, "/v1/companies/1111/relations")
            #expect(jev == .notFound)
            let (overlay, _) = try await send(app, "/v1/companies/2222/relations")
            #expect(overlay == .notFound)
        }
    }

    @Test func omittedSectionIsReported() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "1111", section: relationSectionMainCustomers, kind: relationKindNone,
                name: "", sectionStatus: relationSectionStatusOmitted)
            try await seed(
                app, code: "1111", section: relationSectionAffiliatedEntities, kind: relationKindSubsidiary,
                name: "株式会社子")
            let (status, json) = try await send(app, "/v1/companies/1111/relations")
            #expect(status == .ok)
            #expect(json?["omitted"] as? [String] == ["customer"])
            #expect(json?["next_cursor"] is NSNull)
            let (_, filtered) = try await send(app, "/v1/companies/1111/relations?type=group")
            #expect(filtered?["omitted"] as? [String] == [])
        }
    }

    @Test func investeeCarriesHoldingDetails() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "7203", section: relationSectionPolicyHoldings, kind: relationKindInvestee,
                name: "株式会社デンソー", relatedCode: "6902", shares: 100, bookValue: 5_000_000)
            let (_, json) = try await send(app, "/v1/companies/7203/relations?type=investee")
            let item = try #require(relations(json).first)
            let investee = item["investee"] as? [String: Any]
            #expect(investee?["shares"] as? Double == 100)
            #expect(investee?["book_value_yen"] as? Double == 5_000_000)
            #expect(investee?["is_deemed"] as? Bool == false)
            #expect(investee?["holder"] as? String == relationHolderReportingCompany)
            // 出資先の逆引きはしない。
            let (status, _) = try await send(app, "/v1/companies/6902/relations")
            #expect(status == .notFound)
        }
    }

    @Test func majorShareholdersByRankWithoutAddressAndReverse() async throws {
        try await withRelationsApp { app in
            try await seed(
                app, code: "7203", section: relationSectionMajorShareholders, kind: relationKindMajorShareholder,
                position: 1, name: "株式会社豊田自動織機", relatedCode: "6201", rank: 2, ratio: 0.09,
                shares: 1000, address: "愛知県刈谷市")
            try await seed(
                app, code: "7203", section: relationSectionMajorShareholders, kind: relationKindMajorShareholder,
                position: 0, name: "日本マスタートラスト信託銀行株式会社", rank: 1, ratio: 0.128, shares: 2000,
                address: "東京都港区")
            let (_, json) = try await send(app, "/v1/companies/7203/relations?type=major_shareholder")
            let items = relations(json)
            #expect(items.map { ($0["major_shareholder"] as? [String: Any])?["rank"] as? Int } == [1, 2])
            #expect((items[0]["major_shareholder"] as? [String: Any])?["ratio"] as? Double == 0.128)
            let body = String(data: try JSONSerialization.data(withJSONObject: json ?? [:]), encoding: .utf8) ?? ""
            #expect(!body.contains("address"))
            #expect(!body.contains("愛知県"))

            let (status, reverse) = try await send(app, "/v1/companies/6201/relations?type=major_shareholder_of")
            #expect(status == .ok)
            let held = try #require(relations(reverse).first)
            #expect(held["type"] as? String == "major_shareholder_of")
            #expect((held["company"] as? [String: Any])?["code"] as? String == "7203")
        }
    }

    @Test func paginatesWithCursor() async throws {
        try await withRelationsApp { app in
            for i in 0..<3 {
                try await seed(
                    app, code: "1111", section: relationSectionMainCustomers, kind: relationKindCustomer,
                    position: i, name: "顧客\(i)")
            }
            let (_, first) = try await send(app, "/v1/companies/1111/relations?limit=2")
            #expect(relations(first).count == 2)
            let cursor = try #require(first?["next_cursor"] as? String)
            let (_, second) = try await send(app, "/v1/companies/1111/relations?limit=2&cursor=\(cursor)")
            #expect(relations(second).map { $0["name_raw"] as? String } == ["顧客2"])
            #expect(second?["next_cursor"] is NSNull)
            let (bad, _) = try await send(app, "/v1/companies/1111/relations?cursor=x")
            #expect(bad == .badRequest)
            // 別の type の要求には使えない。
            let (otherType, _) = try await send(app, "/v1/companies/1111/relations?type=customer&cursor=\(cursor)")
            #expect(otherType == .badRequest)
        }
    }

    @Test func servabilityIsPureFunction() {
        #expect(isPubliclyServableRelation(kind: relationKindCustomer, decidedBy: relationDecidedByRule, needsReview: true, resolution: relationResolutionAmbiguous, warning: nil))
        #expect(!isPubliclyServableRelation(kind: relationKindAffiliate, decidedBy: relationDecidedByJev, needsReview: true, resolution: relationResolutionUnresolved, warning: nil))
        #expect(isPubliclyServableRelation(kind: relationKindAffiliate, decidedBy: relationDecidedByJev, needsReview: true, resolution: relationResolutionAmbiguous, warning: nil))
        #expect(!isPubliclyServableRelation(kind: relationKindUnclassified, decidedBy: relationDecidedByJev, needsReview: true, resolution: relationResolutionAmbiguous, warning: nil))
        #expect(!isPubliclyServableRelation(kind: relationKindUnclassified, decidedBy: relationDecidedByRule, needsReview: false, resolution: nil, warning: nil))
        #expect(!isPubliclyServableRelation(kind: relationKindCustomer, decidedBy: relationDecidedByRule, needsReview: false, resolution: nil, warning: "overlay_regression"))
    }
}
