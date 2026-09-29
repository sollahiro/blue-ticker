// 手動 XBRL 上書き行。会社-FY-item ごとに payload JSONB を持つ。
// 公開契約ではなくサーバー内部スキーマ。有効行は revoked_at IS NULL の部分ユニーク。

import BlueTickerCore
import Fluent
import Foundation

final class ManualXbrlOverrideRow: Model, @unchecked Sendable {
    static let schema = "manual_xbrl_overrides"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "edinet_code")
    var edinetCode: String

    @Field(key: "period_end")
    var periodEnd: String

    @Field(key: "item")
    var item: String

    @Field(key: "payload")
    var payload: ManualXbrlOverrideJSONObject

    @Field(key: "source_doc_id")
    var sourceDocID: String

    @Field(key: "source_page")
    var sourcePage: String

    @Field(key: "reason")
    var reason: String

    @Field(key: "created_by")
    var createdBy: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    init() {}

    convenience init(record: ManualXbrlOverrideRecord) {
        self.init()
        self.id = UUID()
        self.edinetCode = record.edinetCode
        self.periodEnd = record.periodEnd
        self.item = record.item.rawValue
        self.payload = ManualXbrlOverrideJSONObject(record.payload)
        self.sourceDocID = record.sourceDocID
        self.sourcePage = record.sourcePage
        self.reason = record.reason
        self.createdBy = record.createdBy
    }

    func validatedRecord() throws -> ManualXbrlOverrideRecord {
        let parsedItem = try parseManualXbrlOverrideItem(item)
        let payload = try parseManualXbrlOverridePayload(
            item: parsedItem, object: self.payload.jsonObject())
        return ManualXbrlOverrideRecord(
            edinetCode: edinetCode, periodEnd: periodEnd, item: parsedItem, payload: payload,
            sourceDocID: sourceDocID, sourcePage: sourcePage, reason: reason, createdBy: createdBy)
    }
}

/// JSONB に item 固有オブジェクトをそのまま置くための Codable ラッパ（未知キーは読取時に検証する）。
struct ManualXbrlOverrideJSONObject: Codable, Equatable, Sendable {
    var object: [String: ManualXbrlJSON]

    init(_ payload: ManualXbrlOverridePayload) {
        let json = manualXbrlOverridePayloadJSONObject(payload)
        object = json.mapValues(ManualXbrlJSON.init(any:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        object = try container.decode([String: ManualXbrlJSON].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(object)
    }

    func jsonObject() -> [String: Any] {
        object.mapValues(\.anyValue)
    }
}

enum ManualXbrlJSON: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: ManualXbrlJSON])
    case array([ManualXbrlJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String: ManualXbrlJSON].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([ManualXbrlJSON].self) {
            self = .array(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let flag as Bool:
            self = .bool(flag)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            if double.rounded() == double, let int = Int(exactly: double) {
                self = .int(int)
            } else {
                self = .double(double)
            }
        case let string as String:
            self = .string(string)
        case let object as [String: Any]:
            self = .object(object.mapValues(ManualXbrlJSON.init(any:)))
        case let array as [Any]:
            self = .array(array.map(ManualXbrlJSON.init(any:)))
        default:
            self = .string(String(describing: value))
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.anyValue)
        case .array(let value): return value.map(\.anyValue)
        case .null: return NSNull()
        }
    }
}
