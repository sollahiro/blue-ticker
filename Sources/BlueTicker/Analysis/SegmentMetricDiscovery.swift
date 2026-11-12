// 標準 CE / 資産タグに無い提出者拡張を、タグ名の形から拾う。社名リストは持たない。
// コスモ: DecreaseIncreaseInOfPropertyPlantAndEquipmentAndIntangibleAssets
// 板硝子: 標準 CE が無く Overview member fact を資本的支出セルにするのは呼び出し側。

import Foundation

enum SegmentMetricDiscovery {
    static func capitalExpenditureTags(in facts: [BreakdownFact]) -> [String] {
        var tags = Xbrl.segmentCapitalExpenditureTags
        for tag in Set(facts.map(\.tag)).sorted() {
            if tags.contains(tag) { continue }
            if tag.contains("OverviewOfCapitalExpenditures") { continue }
            if tag.contains("CapitalExpenditure")
                || tag.contains("DecreaseIncreaseInOfProperty")
                || (tag.contains("IncreaseInPropertyPlantAndEquipment")
                    && !Xbrl.segmentNoncurrentAssetAdditionTags.contains(tag)
                    && tag.contains("Segment"))
            {
                if hasSegmentMember(facts, tag: tag) { tags.append(tag) }
            }
        }
        return tags
    }

    static func segmentAssetTags(in facts: [BreakdownFact]) -> [String] {
        var tags = Xbrl.segmentAssetsTags
        for tag in Set(facts.map(\.tag)).sorted() {
            if tags.contains(tag) { continue }
            if tag.contains("SegmentAsset") || tag.hasSuffix("AssetsSegmentInformation") {
                if hasSegmentMember(facts, tag: tag) { tags.append(tag) }
            }
        }
        return tags
    }

    static func hasSegmentMember(_ facts: [BreakdownFact], tag: String) -> Bool {
        facts.contains {
            $0.tag == tag && XBRLUtils.primaryBreakdownMember($0.dimensions) != nil
        }
    }
}
