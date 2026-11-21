import Foundation

/// `GET /v1/companies/{code}/waterfall/segment` の公開 JSON の手書き。画面が読むキーだけ持つ。
struct SegmentWaterfallResponse: Codable {
    var code: String?
    var metric: String?
    var years: [Year]

    struct Year: Codable {
        var docId: String?
        var fiscalYear: Int?
        var fyEnd: String?
        /// true の年は、前年との線を切る合図。
        var lineCut: Bool?
        var segments: [Segment]

        enum CodingKeys: String, CodingKey {
            case docId = "doc_id"
            case fiscalYear = "fiscal_year"
            case fyEnd = "fy_end"
            case lineCut = "line_cut"
            case segments
        }
    }

    struct Segment: Codable {
        var label: String
        var segmentKey: String?
        var value: Double?
        var prior: Prior?

        enum CodingKeys: String, CodingKey {
            case label
            case segmentKey = "segment_key"
            case value, prior
        }
    }

    /// 前年のどの行と結ぶか。`decision` は connect / rename / reorg / break。
    /// `segmentKey` は connect / rename のときだけ前年の行のキー。
    struct Prior: Codable {
        var decision: String?
        var segmentKey: String?

        enum CodingKeys: String, CodingKey {
            case decision
            case segmentKey = "segment_key"
        }
    }
}

/// `GET /v1/companies/{code}/breakdown?axis=segment|geography` の公開 JSON の手書き。
struct BreakdownResponse: Codable {
    var docId: String?
    var breakdown: Body?

    enum CodingKeys: String, CodingKey {
        case docId = "doc_id"
        case breakdown
    }

    struct Body: Codable {
        var rows: [Row]
        var segmentStructure: String?

        enum CodingKeys: String, CodingKey {
            case rows
            case segmentStructure = "segment_structure"
        }
    }

    struct Row: Codable {
        var label: String
        var rowKind: String?
        var segmentKey: String?
        /// `business` / `geographic`（`segment` 軸のみ）。
        var segmentBasis: String?
        /// `geography` 軸の売上高。
        var amount: Double?
        /// `segment` 軸のセル。
        var externalSales: Cell?
        var profit: Cell?

        enum CodingKeys: String, CodingKey {
            case label
            case rowKind = "row_kind"
            case segmentKey = "segment_key"
            case segmentBasis = "segment_basis"
            case amount
            case externalSales = "external_sales"
            case profit
        }
    }

    struct Cell: Codable {
        var value: Double?
    }
}
