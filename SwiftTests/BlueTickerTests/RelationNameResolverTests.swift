// 関係の相手名の正規化と決定論の名前解決（EDINET コードリスト・子会社索引）の仕様。
// コードリストは同梱 CSV（assets/EdinetcodeDlInfo.csv）をそのまま使う。

import Testing

@testable import BlueTickerCore

private func directory() async -> RelationNameDirectory {
    RelationNameDirectory(filers: await edinetFilerNames())
}

private func resolve(
    _ name: String, kind: String = relationKindCustomer, ownCode: String = "9409",
    directory: RelationNameDirectory, subsidiaries: [String: Set<String>] = [:]
) -> RelationNameResolution {
    RelationNameResolver.resolve(
        nameNorm: RelationNameNormalizer.normalize(name), kind: kind, ownCode: ownCode,
        directory: directory, subsidiaryParents: { subsidiaries[$0] ?? [] })
}

@Suite struct RelationNameResolverTests {

    @Test func normalizeStripsCorporateFormAndNoteMarkers() {
        #expect(RelationNameNormalizer.normalize("ＴＯＰＰＡＮ株式会社 (注)") == "TOPPAN")
        #expect(RelationNameNormalizer.normalize("㈱電通") == "電通")
        #expect(RelationNameNormalizer.normalize("株式会社電通総研") == "電通総研")
        #expect(RelationNameNormalizer.normalize("ＴＯＰＰＡＮホールディングス株式会社") == "TOPPANホールディングス")
        #expect(RelationNameNormalizer.normalize("DAISHINKU CORP.") == "DAISHINKU")
        #expect(RelationNameNormalizer.normalize("株式会社電通グループ 及びそのグループ会社") == "電通グループ")
        #expect(RelationNameNormalizer.normalize("Largan Precision Co.,Ltd.") == "LARGANPRECISION")
    }

    @Test func listedFilerNameResolvesExactly() async {
        let dir = await directory()
        let result = resolve("株式会社大真空", ownCode: "6384", directory: dir)
        #expect(result.relatedCode == "6962")
        #expect(result.resolution == relationResolutionNameExact)
        #expect(result.needsReview == false)
    }

    @Test func englishNameResolves() async {
        let dir = await directory()
        let result = resolve("DAISHINKU CORP.", ownCode: "6384", directory: dir)
        #expect(result.relatedCode == "6962")
        #expect(result.resolution == relationResolutionNameEnExact)
    }

    @Test func foreignCustomerIsUnresolved() async {
        let dir = await directory()
        let result = resolve("Largan Precision Co.,Ltd.", ownCode: "6384", directory: dir)
        #expect(result.relatedCode == nil)
        #expect(result.resolution == relationResolutionUnresolved)
    }

    @Test func governmentIsUnresolved() async {
        let dir = await directory()
        let result = resolve("防衛省", ownCode: "6203", directory: dir)
        #expect(result.relatedCode == nil)
        #expect(result.resolution == relationResolutionUnresolved)
    }

    @Test func listedSubsidiaryNameIsNotConfusedWithParent() async {
        let dir = await directory()
        let result = resolve("株式会社電通総研", directory: dir, subsidiaries: ["電通総研": ["4324"]])
        #expect(result.relatedCode == "4812")
        #expect(result.resolution == relationResolutionNameExact)
    }

    @Test func unlistedSubsidiaryResolvesViaListedParent() async {
        let dir = await directory()
        let result = resolve("㈱電通", directory: dir, subsidiaries: ["電通": ["4324"]])
        #expect(result.relatedCode == "4324")
        #expect(result.resolution == relationResolutionViaListedParent)
        #expect(result.needsReview == false)
    }

    @Test func subsidiaryRowIsNotLinkedViaParent() async {
        let dir = await directory()
        let result = resolve(
            "㈱電通", kind: relationKindSubsidiary, ownCode: "1234", directory: dir,
            subsidiaries: ["電通": ["4324"]])
        #expect(result.relatedCode == nil)
    }

    @Test func investeeAndMajorShareholderAreNotLinkedViaParent() async {
        let dir = await directory()
        for kind in [relationKindInvestee, relationKindMajorShareholder] {
            let result = resolve(
                "日本マスタートラスト信託銀行株式会社（信託口）", kind: kind, ownCode: "7203", directory: dir,
                subsidiaries: ["日本マスタートラスト信託銀行": ["8306"]])
            #expect(result.relatedCode == nil)
            #expect(result.resolution != relationResolutionViaListedParent)
        }
    }

    @Test func multipleParentsAreAmbiguous() async {
        let dir = await directory()
        let result = resolve("㈱電通", directory: dir, subsidiaries: ["電通": ["4324", "1111"]])
        #expect(result.relatedCode == nil)
        #expect(result.resolution == relationResolutionAmbiguous)
        #expect(result.needsReview == true)
    }

    @Test func neverLinksToOwnCompany() async {
        let dir = await directory()
        let own = resolve("株式会社大真空", ownCode: "6962", directory: dir)
        #expect(own.relatedCode == nil)
        let viaSelf = resolve("㈱電通", ownCode: "4324", directory: dir, subsidiaries: ["電通": ["4324"]])
        #expect(viaSelf.relatedCode == nil)
    }

    @Test func unlistedEdinetFilerIsMarked() async {
        let dir = await directory()
        let result = resolve("ＴＯＰＰＡＮエッジ株式会社", directory: dir)
        #expect(result.relatedCode == nil)
        #expect(result.resolution == relationResolutionEdinetUnlisted)
    }
}
