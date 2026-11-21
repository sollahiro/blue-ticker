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
        /// 前年と結べなかった旧区分と新区分の組。古いサーバーには無い。
        var reorgs: [Reorg]?
        /// 連結合計。報告セグメントの無い年（単一セグメント）でも、あれば返る。
        var consolidated: Consolidated?

        enum CodingKeys: String, CodingKey {
            case docId = "doc_id"
            case fiscalYear = "fiscal_year"
            case fyEnd = "fy_end"
            case lineCut = "line_cut"
            case segments, reorgs, consolidated
        }
    }

    struct Consolidated: Codable {
        var value: Double?
    }

    /// `kind` は merge（旧 2 以上・新 1）/ split / replace / regroup。
    struct Reorg: Codable {
        var kind: String?
        var from: [Ref]?
        var to: [Ref]?
    }

    struct Ref: Codable {
        var label: String?
        var segmentKey: String?
        var value: Double?

        enum CodingKeys: String, CodingKey {
            case label
            case segmentKey = "segment_key"
            case value
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

/// `GET /v1/companies/{code}/waterfall/geography` の公開 JSON の手書き。画面が読むキーだけ持つ。
struct GeographyWaterfallResponse: Codable {
    var years: [Year]

    struct Year: Codable {
        var fyEnd: String?
        var fiscalYear: Int?
        /// 地域の切り方が同じ（または持ち上げて同じにできる）年どうしの塊の番号。同じ値の年どうしは比べられる。
        var comparableGroup: Int?
        /// 塊の境目の年で true。
        var lineCut: Bool?
        /// 開示のままの地域。`region` は正規化コード（辞書に無いときは null）。
        var regions: [Region]?
        /// 塊の全年で同じキーにそろえた地域。
        var comparableRegions: [Block]?

        enum CodingKeys: String, CodingKey {
            case fyEnd = "fy_end"
            case fiscalYear = "fiscal_year"
            case comparableGroup = "comparable_group"
            case lineCut = "line_cut"
            case regions
            case comparableRegions = "comparable_regions"
        }
    }

    struct Region: Codable {
        var label: String
        var region: String?
        var value: Double?
    }

    struct Block: Codable {
        var region: String
        var members: [String]?
        var value: Double?
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
