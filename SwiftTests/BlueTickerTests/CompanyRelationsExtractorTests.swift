// 関係（顧客・関係会社・出資先・大株主）抽出の検証。
// HTML 断片の単体テストと、実書類（キャッシュが無ければ SKIP）での形の確認。
// 期待値は実害が出た行・課題の Spec に挙がった行だけ（網羅的な golden にしない）。

import Foundation
import Testing

@testable import BlueTickerCore

private func realXbrlDir(_ docID: String) async -> URL? {
    await SmokeCacheSupport.ensureCached([docID])
    let dir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
    guard FileManager.default.fileExists(atPath: dir.path) else {
        print("SKIP   \(docID): XBRL キャッシュなし")
        return nil
    }
    return dir
}

private func rows(_ result: CompanyRelationsExtractor.Result, section: String) -> [CompanyRelationDraft] {
    result.extraction.rows.filter { $0.section == section }
}

@Suite struct CompanyRelationsExtractorTests {
    // MARK: - 顧客表

    @Test func customerTableReadsNameAmountSegmentAndUnit() {
        let html = """
            <p>３．主要な顧客ごとの情報</p>
            <table>
            <tr><td></td><td></td><td>(単位：千円)</td></tr>
            <tr><td>顧客の名称又は氏名</td><td>売上高</td><td>関連するセグメント名</td></tr>
            <tr><td>株式会社エー</td><td>1,534,174</td><td>装置事業</td></tr>
            <tr><td>ＴＯＰＰＡＮ株式会社 (注)</td><td>667,154</td><td>装置事業</td></tr>
            <tr><td>合計</td><td>2,201,328</td><td></td></tr>
            </table>
            """
        let rows = CompanyRelationsExtractor.parseMainCustomers(html: html)
        #expect(rows.map(\.nameRaw) == ["株式会社エー", "ＴＯＰＰＡＮ株式会社"])
        #expect(rows.map(\.amountYen) == [1_534_174_000, 667_154_000])
        #expect(rows.allSatisfy { $0.segmentLabel == "装置事業" && $0.kind == relationKindCustomer })
    }

    @Test func customerTableKeepsOnlyCurrentPeriodWhenBothPeriodsInOneBlock() {
        let html = """
            <p>前連結会計年度（自 2024年4月1日 至 2025年3月31日）</p>
            <table><tr><td>相手先</td><td>売上高(百万円)</td></tr><tr><td>前期社</td><td>10</td></tr></table>
            <p>当連結会計年度（自 2025年4月1日 至 2026年3月31日）</p>
            <table><tr><td>相手先</td><td>売上高(百万円)</td></tr><tr><td>当期社</td><td>20</td></tr></table>
            """
        let rows = CompanyRelationsExtractor.parseMainCustomers(html: html)
        #expect(rows.map(\.nameRaw) == ["当期社"])
        #expect(rows.first?.amountYen == 20_000_000)
    }

    @Test func omissionSentenceIsOmittedNotUnextracted() {
        let html = "<p>外部顧客への売上高のうち、連結損益計算書の売上高の10％以上を占める相手先がないため、記載を省略しております。</p>"
        #expect(CompanyRelationsExtractor.parseMainCustomers(html: html).isEmpty)
        #expect(CompanyRelationsExtractor.omissionStatus(html) == relationSectionStatusOmitted)
    }

    // MARK: - 関係会社表

    @Test func groupTableHeadingRowsSetKindAndRatioColumns() {
        let html = """
            <table>
            <tr><td rowspan="2">名称</td><td rowspan="2">住所</td><td rowspan="2">主要な事業の内容</td>
                <td colspan="2">議決権の所有(被所有)割合</td><td rowspan="2">関係内容</td></tr>
            <tr><td>所有割合(％)</td><td>被所有割合(％)</td></tr>
            <tr><td>(親会社)</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>株式会社オヤ</td><td>東京都</td><td>持株会社</td><td>―</td><td>51.2</td><td>―</td></tr>
            <tr><td>(連結子会社)</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>㈱コー (注)４，６</td><td>東京都</td><td>日本</td><td>100.0 (25.0)</td><td>―</td><td>―</td></tr>
            <tr><td>(持分法適用関連会社)</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>カンレン㈱ ※１</td><td>大阪市</td><td>日本</td><td>33.4</td><td>―</td><td>―</td></tr>
            <tr><td>その他54社</td><td></td><td></td><td></td><td></td><td></td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.pending.isEmpty)
        #expect(parsed.rows.map(\.nameRaw) == ["株式会社オヤ", "㈱コー", "カンレン㈱"])
        #expect(parsed.rows.map(\.kind) == [relationKindParent, relationKindSubsidiary, relationKindAffiliate])
        #expect(parsed.rows.map(\.votingRatio) == [51.2, 100.0, 33.4])
        #expect(parsed.rows.allSatisfy { $0.decidedBy == relationDecidedByRule && !$0.needsReview })
    }

    @Test func groupKindFromNamePrefixAndOutsideHeading() {
        let prefixed = """
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>議決権の所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>（連結子会社） Example U.S.A., Inc. （注）2</td><td>米国</td><td>400千米ドル</td><td>販売</td><td>100</td><td>販売</td></tr>
            <tr><td>（持分法適用関連会社） 株式会社オークション</td><td>横浜市</td><td>212</td><td>事業</td><td>33.5</td><td>取引</td></tr>
            </table>
            """
        let p = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: prefixed, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(p.rows.map(\.nameRaw) == ["Example U.S.A., Inc.", "株式会社オークション"])
        #expect(p.rows.map(\.kind) == [relationKindSubsidiary, relationKindAffiliate])

        let outside = """
            <p>４【関係会社の状況】</p><p>(1）連結子会社</p>
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>所有持分割合（％）</td><td>関係内容</td></tr>
            <tr><td>コー㈱ （注）３</td><td>東京都</td><td>50</td><td>日本</td><td>100.00</td><td>有</td></tr>
            </table>
            <p>（注）１ 「主要な事業の内容」欄には、セグメントの名称を記載しております。</p>
            <p>(2）持分法適用会社</p>
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>議決権の所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>カンレン㈱</td><td>東京都</td><td>50</td><td>日本</td><td>49.00 (49.00)</td><td>有</td></tr>
            </table>
            """
        let o = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: outside, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(o.rows.map(\.kind) == [relationKindSubsidiary, relationKindAffiliate])
        #expect(o.rows.map(\.votingRatio) == [100.0, 49.0])
    }

    @Test func namePrefixKindCarriesToFollowingRowsAndTables() {
        // 区分語は区分の先頭行の名称にだけ付き、続く行（改ページ後の続きの表も）は同じ区分になる。
        // 表の中に入った注記の文は行にしない。
        let html = """
            <table>
            <tr><td>会社名</td><td>住所</td><td>資本金</td><td>主な事業の内容</td><td>議決権の所有割合又は被所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>（連結子会社） コー㈱</td><td>東京都</td><td>50</td><td>製造</td><td>100.0</td><td>有</td></tr>
            <tr><td>コーニ㈱</td><td>東京都</td><td>50</td><td>販売</td><td>100.0</td><td>有</td></tr>
            </table>
            <table>
            <tr><td>会社名</td><td>住所</td><td>資本金</td><td>主な事業の内容</td><td>議決権の所有割合又は被所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>コーサン㈱</td><td>大阪市</td><td>50</td><td>製造</td><td>91.7</td><td>有</td></tr>
            <tr><td>（持分法適用会社） カンレン㈱</td><td>大阪市</td><td>50</td><td>部品</td><td>30.0</td><td>有</td></tr>
            <tr><td>カンレンニ㈱</td><td>大阪市</td><td>50</td><td>販売</td><td>20.0</td><td>有</td></tr>
            <tr><td>（その他の関係会社） オヤ AG</td><td>ドイツ</td><td>100</td><td>製造</td><td>被所有 44.26</td><td>有</td></tr>
            <tr><td>オヤニ㈱</td><td>愛知県</td><td>100</td><td>製造</td><td>被所有 37.46</td><td>有</td></tr>
            <tr><td>「主な事業の内容」欄には、セグメントの名称を記載しております。</td><td></td><td></td><td></td><td></td><td></td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.pending.isEmpty)
        #expect(parsed.rows.map(\.nameRaw) == ["コー㈱", "コーニ㈱", "コーサン㈱", "カンレン㈱", "カンレンニ㈱", "オヤ AG", "オヤニ㈱"])
        #expect(parsed.rows.map(\.kind) == [
            relationKindSubsidiary, relationKindSubsidiary, relationKindSubsidiary,
            relationKindAffiliate, relationKindAffiliate, relationKindOtherRelated, relationKindOtherRelated,
        ])
        #expect(parsed.rows.allSatisfy { $0.decidedBy == relationDecidedByRule && !$0.needsReview })
    }

    @Test func votingRatioCellSplitsTotalIndirectAndCloseParties() {
        typealias Cell = CompanyRelationsExtractor.VotingRatioCell
        let cases: [(String, Cell?)] = [
            ("100.0", Cell(total: 100.0)),
            ("100.0 (66.5)", Cell(total: 100.0, indirect: 66.5)),
            ("(0.79) 51.49", Cell(total: 51.49, indirect: 0.79)),
            ("(100.0)", Cell(total: 100.0, indirect: 100.0)),
            ("100.0％ (100.0％)", Cell(total: 100.0, indirect: 100.0)),
            ("※2 100.0 [66.5]", Cell(total: 100.0, closeParties: 66.5)),
            ("※１ 45.0", Cell(total: 45.0)),
            ("※15.01", Cell(total: 15.01)),
            ("(注２) 100.0 (100.0)", Cell(total: 100.0, indirect: 100.0)),
            ("100.0(1.0)(注)3、6", Cell(total: 100.0, indirect: 1.0)),
            ("20.0(注6)", Cell(total: 20.0)),
            ("被所有 46.3 (14.9) [0.6]", Cell(total: 46.3, indirect: 14.9, closeParties: 0.6)),
            ("被所有66.1(注)2", Cell(total: 66.1)),
            ("20.6 (0.1) 〔0.8〕", Cell(total: 20.6, indirect: 0.1, closeParties: 0.8)),
            ("－ [100.0]", Cell(closeParties: 100.0)),
            ("100.0 (－) [－]", Cell(total: 100.0)),
            ("(被所有)", nil),
            ("―", nil),
            ("6,022,109", nil),
            ("千US$ 14,662", nil),
        ]
        for (text, expected) in cases {
            #expect(CompanyRelationsExtractor.votingRatioCell(text) == expected, "\(text)")
        }
    }

    @Test func financialInfoTablesCountsAndSpanningLabelsAreNotRows() {
        // 「主要な損益情報等」の表は列数が同じでも続きの表ではない。「12社」の集計行と全列にまたがる見出しも相手ではない。
        let html = """
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>議決権の所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>（連結子会社）</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td colspan="6">●製造等</td></tr>
            <tr><td>コー㈱</td><td>東京都</td><td>50</td><td>製造</td><td>100.0</td><td>有</td></tr>
            <tr><td>12社</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>(販売カンパニー) 24社</td><td></td><td></td><td></td><td></td><td></td></tr>
            </table>
            <table>
            <tr><td></td><td>売上高</td><td>経常利益</td><td>当期純利益</td><td>純資産額</td><td>総資産額</td></tr>
            <tr><td>コー㈱</td><td>182,260</td><td>14,289</td><td>6,176</td><td>133,915</td><td>185,994</td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.rows.map(\.nameRaw) == ["コー㈱"])
        #expect(parsed.rows.map(\.votingRatio) == [100.0])
    }

    @Test func bracketedLabelsAndCountRowsAreNotRows() {
        // 括弧で囲んだ事業区分の見出し・横結合の見出し・社数の集計行は相手ではない。社名を含む集計の行は残す。
        let html = """
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>議決権の所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>（連結子会社）</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>（繊維）</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td colspan="2">国内</td><td></td><td></td><td></td><td></td></tr>
            <tr><td>コー㈱</td><td>東京都</td><td>50</td><td>製造</td><td>100.0</td><td>有</td></tr>
            <tr><td>コーニ㈱ その他６社</td><td>東京都</td><td>50</td><td>販売</td><td>54.0</td><td>有</td></tr>
            <tr><td>その他（27社）</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>合 計 127社</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>〔物流などのサービス〕 合計３社</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>持分法適用関連会社 ２社</td><td></td><td></td><td></td><td></td><td></td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.rows.map(\.nameRaw) == ["コー㈱", "コーニ㈱ その他６社"])
        #expect(parsed.rows.allSatisfy { $0.kind == relationKindSubsidiary })
    }

    @Test func bracketedKindHeadingSwitchesKindEvenWithValuesInTheRow() {
        // 「＜親会社＞」の見出しのセルに、縦結合した隣の列の値が入っていても見出しとして読む。
        let html = """
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>議決権の所有又は被所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>＜親会社＞</td><td>東京都</td><td>60百万円</td><td>持株</td><td rowspan="2">被所有 60.9</td><td>－</td></tr>
            <tr><td>オヤ㈱</td><td>東京都</td><td>60百万円</td><td>持株</td><td>－</td></tr>
            <tr><td>《連結子会社》</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>コー㈱</td><td>大阪市</td><td>10百万円</td><td>販売</td><td>100.0</td><td>有</td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.pending.isEmpty)
        #expect(parsed.rows.map(\.nameRaw) == ["オヤ㈱", "コー㈱"])
        #expect(parsed.rows.map(\.kind) == [relationKindParent, relationKindSubsidiary])
        #expect(parsed.rows.map(\.votingRatio) == [60.9, 100.0])
    }

    @Test func tableInsideRelationCellDoesNotSplitTheOuterTable() {
        // 「関係内容」欄の中の表で外側の表を切らない（切ると後ろの会社の行を落とし、中の表の項目名を会社にする）。
        let html = """
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>議決権の所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>（連結子会社）</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>コー㈱</td><td>東京都</td><td>450</td><td>製造</td><td>100</td>
            <td><table><tr><td>役員の兼任等</td><td>兼任１名</td></tr><tr><td>営業上の取引</td><td>製品の製造</td></tr></table></td></tr>
            <tr><td>コーニ㈱</td><td>東京都</td><td>100</td><td>販売</td><td>100</td>
            <td><table><tr><td>役員の兼任等</td><td>兼任２名</td></tr></table></td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.rows.map(\.nameRaw) == ["コー㈱", "コーニ㈱"])
        #expect(parsed.rows.map(\.votingRatio) == [100, 100])
    }

    @Test func transposedFinancialInfoTableIsNotRead() {
        // 会社を列に並べた損益情報の表（「名称」の見出しがあり、行が「①売上収益」）。
        let html = """
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>議決権の所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>（連結子会社）</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td>コー㈱</td><td>東京都</td><td>50</td><td>製造</td><td>100.0</td><td>有</td></tr>
            </table>
            <table>
            <tr><td>名称</td><td>コー㈱（日本基準）</td><td>コーニ Inc.（IFRS）</td></tr>
            <tr><td>①売上収益</td><td>61,932百万円</td><td>101,832百万円</td></tr>
            <tr><td>②経常利益</td><td>4,432百万円</td><td>－</td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.rows.map(\.nameRaw) == ["コー㈱"])
    }

    @Test func secondLineOfRowSpannedNameAddsToThePreviousRow() {
        // 名称を縦に結合した表では、合計の下の段に間接所有の内数が来る。
        let html = """
            <table>
            <tr><td>会社名</td><td>住所</td><td>資本金</td><td>主な事業の内容</td><td>議決権所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>（連結子会社）</td><td></td><td></td><td></td><td></td><td></td></tr>
            <tr><td rowspan="2">コー㈱</td><td rowspan="2">大阪市</td><td>百万元</td><td rowspan="2">卸売</td><td>52.6</td><td rowspan="2">有</td></tr>
            <tr><td>4,923</td><td>(0.1)</td></tr>
            <tr><td>コーニ㈱</td><td>東京都</td><td>50</td><td>販売</td><td>100.0</td><td>有</td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.rows.map(\.nameRaw) == ["コー㈱", "コーニ㈱"])
        #expect(parsed.rows.map(\.votingRatio) == [52.6, 100.0])
        #expect(parsed.rows.map(\.votingRatioIndirect) == [0.1, nil])
        #expect(parsed.rows.map(\.position) == [0, 1])
    }

    @Test func unmarkedGroupTableIsPendingForJev() {
        let html = """
            <table>
            <tr><td>名称</td><td>住所</td><td>資本金</td><td>主要な事業の内容</td><td>議決権の所有割合（％）</td><td>関係内容</td></tr>
            <tr><td>コー㈱</td><td>東京都</td><td>50</td><td>日本</td><td>100.00</td><td>有</td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        #expect(parsed.rows.map(\.kind) == [relationKindUnclassified])
        #expect(parsed.rows.first?.decidedBy == relationDecidedByJev)
        #expect(parsed.rows.first?.needsReview == true)
        #expect(parsed.pending.map(\.rowIndices) == [[0]])
    }

    @Test func jevBelowThresholdKeepsNeedsReviewAndAcceptedSetsDecidedBy() async {
        let html = """
            <table>
            <tr><td>名称</td><td>住所</td><td>議決権の所有割合（％）</td></tr>
            <tr><td>コー㈱</td><td>東京都</td><td>100.00</td></tr>
            </table>
            """
        let parsed = CompanyRelationsExtractor.parseAffiliatedEntities(
            html: html, section: relationSectionAffiliatedEntities, defaultKind: nil)
        let result = CompanyRelationsExtractor.Result(
            extraction: CompanyRelationsExtraction(rows: parsed.rows, fyEnd: nil),
            pendingGroupTables: parsed.pending)

        let low = await RelationKindJev.apply(
            result, decider: FakeRelationKindDecider(selected: relationKindSubsidiary, probability: 0.8),
            docID: "S100TEST")
        #expect(low.rows.first?.kind == relationKindUnclassified)
        #expect(low.rows.first?.needsReview == true)
        #expect(low.rows.first?.decidedBy == relationDecidedByJev)
        #expect(!isPubliclyServableRelation(
            kind: low.rows[0].kind, decidedBy: low.rows[0].decidedBy,
            needsReview: low.rows[0].needsReview, resolution: nil, warning: nil))

        let high = await RelationKindJev.apply(
            result, decider: FakeRelationKindDecider(selected: relationKindSubsidiary, probability: 0.97),
            docID: "S100TEST")
        #expect(high.rows.first?.kind == relationKindSubsidiary)
        #expect(high.rows.first?.needsReview == false)
        #expect(high.rows.first?.decidedBy == relationDecidedByJev)
    }

    // MARK: - 実書類

    @Test func showaShinkuMainCustomersCurrentPeriod() async {
        guard let dir = await realXbrlDir("S100YKGJ") else { return }
        let result = CompanyRelationsExtractor.extract(xbrlDir: dir)
        let customers = rows(result, section: relationSectionMainCustomers)
        #expect(customers.map(\.nameRaw) == ["Largan Precision Co.Ltd", "株式会社大真空", "三生電子株式会社"])
        #expect(customers.map(\.amountYen) == [2_060_814_000, 1_534_174_000, 1_373_043_000])
        #expect(customers.allSatisfy { $0.segmentLabel == "真空技術応用装置事業" })
        let group = rows(result, section: relationSectionAffiliatedEntities)
        #expect(group.contains { $0.kind == relationKindOtherRelated && $0.nameRaw == "株式会社アルバック" })
        #expect(group.contains { $0.kind == relationKindSubsidiary && $0.nameRaw == "株式会社エフ・イー・シー" })
    }

    @Test func tvAsahiMainCustomerDentsu() async {
        guard let dir = await realXbrlDir("S100YCD2") else { return }
        let customers = rows(CompanyRelationsExtractor.extract(xbrlDir: dir), section: relationSectionMainCustomers)
        #expect(customers.first?.nameRaw == "㈱電通")
        #expect(customers.first?.amountYen == 95_235_000_000)
    }

    @Test func dentsuGroupSubsidiaryNoteMarkerIsDropped() async {
        guard let dir = await realXbrlDir("S100XS0O") else { return }
        let group = rows(CompanyRelationsExtractor.extract(xbrlDir: dir), section: relationSectionAffiliatedEntities)
        let dentsu = group.first { $0.nameRaw == "㈱電通" }
        #expect(dentsu?.kind == relationKindSubsidiary)
        #expect(dentsu?.votingRatio == 100.0)
        #expect(!group.contains { $0.nameRaw.contains("注") })
    }

    @Test func toyotaPolicyHoldingsAndMajorShareholders() async {
        guard let dir = await realXbrlDir("S100Y8NY") else { return }
        let result = CompanyRelationsExtractor.extract(xbrlDir: dir)
        let investees = rows(result, section: relationSectionPolicyHoldings)
        #expect(investees.count > 10)
        #expect(investees.first?.shares == 363_365_900)
        #expect(investees.first?.bookValueYen == 989_627_000_000)
        #expect(investees.allSatisfy { $0.kind == relationKindInvestee && $0.holder != nil })
        #expect(investees.contains { $0.isDeemed == true })
        let majors = rows(result, section: relationSectionMajorShareholders)
        #expect(majors.map(\.rank) == Array(1...10).map { Optional($0) })
        #expect(majors.first?.nameRaw == "日本マスタートラスト信託銀行㈱")
        #expect(majors.first?.shares == 1_667_971_000)
        #expect(majors.first?.ratio == 0.128)
        #expect(majors.allSatisfy { $0.address != nil })
        // 見出し行だけを繰り返した続きの表（海外の連結子会社）は前の表の区分を引き継ぐ。
        let group = rows(result, section: relationSectionAffiliatedEntities)
        #expect(group.first { $0.nameRaw == "トヨタ モータークレジット㈱" }?.kind == relationKindSubsidiary)
        #expect(!group.contains { $0.kind == relationKindUnclassified })
    }
}

@Suite struct RelationCustomerRowspanTests {
    @Test func rowspanCustomerWithPerRowSegmentsIsOneRow() {
        let html = """
            <p>（単位：百万円）</p>
            <table>
            <tr><td>顧客の名称又は氏名</td><td>売上高</td><td>関連するセグメント名</td></tr>
            <tr><td rowspan="2">ＮＴＴ東日本㈱</td><td rowspan="2">91,494</td><td>Ａ</td></tr>
            <tr><td>Ｂ</td></tr>
            <tr><td>㈱ＮＴＴドコモ</td><td>36,147</td><td>Ａ</td></tr>
            </table>
            """
        let rows = CompanyRelationsExtractor.parseMainCustomers(html: html)
        #expect(rows.map(\.nameRaw) == ["ＮＴＴ東日本㈱", "㈱ＮＴＴドコモ"])
        #expect(rows.first?.segmentLabel == "Ａ、Ｂ")
        #expect(rows.first?.amountYen == 91_494_000_000)
        #expect(rows.map(\.position) == [0, 1])
    }
}

@Suite struct RelationOutsideHeadingTests {
    @Test func notesBetweenTablesAreNotHeadings() {
        #expect(CompanyRelationsExtractor.outsideHeadingKind(["(2) 持分法適用関連会社"]) == relationKindAffiliate)
        #expect(CompanyRelationsExtractor.outsideHeadingKind(["※特定子会社です"]) == nil)
        #expect(CompanyRelationsExtractor.outsideHeadingKind(["(注) 子会社に該当します"]) == nil)
        #expect(CompanyRelationsExtractor.outsideHeadingKind(["連結子会社", "＊１：特定子会社に該当します。"]) == relationKindSubsidiary)
    }
}

struct FakeRelationKindDecider: RelationKindDeciding {
    var selected: String?
    var probability: Double?

    func classifyGroupTable(
        table: CompanyRelationsExtractor.PendingGroupTable, docID: String
    ) async -> JevChoiceAggregate.Sample {
        JevChoiceAggregate.Sample(
            selected: selected, probability: probability,
            probabilities: selected.map { [$0: probability ?? 0] } ?? [:],
            options: relationGroupKinds, model: "fake")
    }
}
