import Testing

@testable import BlueTickerCore

/// 親 / 子の行は親を subtotal にし、資産の調整表の行は reconciling にする。
struct SegmentRowKindLabelTests {
    private func row(_ label: String, kind: String = "segment") -> BreakdownRow {
        BreakdownRow(
            labelRaw: label, label: label, amount: 100, share: nil, profit: 10, rowKind: kind,
            description: nil)
    }

    @Test func parentRowsWithChildrenBecomeSubtotals() {
        let rows = [
            row("はせがわ / 仏壇仏具・墓石 / 東日本"),
            row("はせがわ / 仏壇仏具・墓石 / 西日本"),
            row("はせがわ / 仏壇仏具・墓石"),
            row("はせがわ / 屋内墓苑"),
            row("はせがわ"),
            row("現代仏壇"),
            row("調整額", kind: "reconciling"),
        ]
        let kinds = SegmentInfoLLMNormalizer.demotingParentRowsWithChildren(rows)
            .map { "\($0.labelRaw)=\($0.rowKind)" }
        #expect(kinds == [
            "はせがわ / 仏壇仏具・墓石 / 東日本=segment",
            "はせがわ / 仏壇仏具・墓石 / 西日本=segment",
            "はせがわ / 仏壇仏具・墓石=subtotal",
            "はせがわ / 屋内墓苑=segment",
            "はせがわ=subtotal",
            "現代仏壇=segment",
            "調整額=reconciling",
        ])
    }

    @Test func rowsWithoutChildrenAreUntouched() {
        let rows = [row("流通"), row("流通サービス"), row("運輸")]
        #expect(
            SegmentInfoLLMNormalizer.demotingParentRowsWithChildren(rows).allSatisfy {
                $0.rowKind == "segment"
            })
    }

    @Test func assetReconciliationMembersAreReconciling() {
        for label in ["全社資産（注）", "その他の調整額", "セグメント間取引消去等", "事業セグメントに配分していない資産"] {
            let raw = "\(SegmentAssetsDifferenceTable.labelRawPrefix)\(label)"
            let kind = SegmentMemberKind.classify(localName: raw, label: label)
            #expect(SegmentMemberKind.rowKind(kind) == "reconciling", "\(label)")
        }
    }
}
