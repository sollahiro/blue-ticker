// 有報セクション取り込み: 有報1件分の抽出済みセクション本文（FilingSectionsPayload）= 1 行。
// filing-content を「serving=read-only」に載せるため、重い SwiftSoup 抽出を ingest 時に済ませて
// 格納し、REST の read 経路は EDINET 取得・パースなしで返す（大企業有報のライブ抽出は 1GB OOM を実測）。
//
// 過去書類も保持するため docID を主キーにする。
// read-by-code のため code（4 桁）と submit_date_time（最新選択）を別カラムに持つ。
// cache_version は filingSectionsCacheVersion（blueTickerVersion 非連動）。公開契約は payload を
// 復元した {code, doc_id, sections} であり、本テーブルはサーバー内部スキーマ。

import BlueTickerCore
import FluentKit
import Foundation

/// 有報1件分の抽出済みセクション。EDINET docID を主キー（user 生成）とする。
package final class CompanyFilingSections: Model, @unchecked Sendable {
    package static let schema = "company_filing_sections"

    /// EDINET docID（例: S100XXXX）。抽出元書類。
    @ID(custom: "doc_id", generatedBy: .user)
    package var id: String?

    /// 4 桁証券コード（例: 7203）。read-by-code の突き合わせに使う。
    @Field(key: "code")
    package var code: String

    /// 提出日時（EDINET の submitDateTime 文字列）。同一 code の最新書類選択に使う。
    @Field(key: "submit_date_time")
    package var submitDateTime: String

    /// 抽出済みセクション（FilingSectionsPayload）。JSONB（SQLite では TEXT）。
    @Field(key: "payload")
    package var payload: FilingSectionsPayload

    /// 抽出時の filingSectionsCacheVersion。読込・取り込みで照合し、不一致なら再抽出する。
    @Field(key: "cache_version")
    package var cacheVersion: String

    /// 抽出時のセクション集合（sorted・カンマ結合）。セクション追加を検知して再抽出するため。
    @Field(key: "section_keys")
    package var sectionKeys: String

    /// 最終更新時刻（抽出・upsert したタイミング）。
    @Timestamp(key: "updated_at", on: .update)
    package var updatedAt: Date?

    package init() {}
}

/// 最新書類の選択用の軽量射影（`payload` の JSONB を転送しない）。
/// filing-content の doc_id 省略経路で候補を選ぶのに使い、ペイロードは選んだ 1 行だけ読む（BLT-201）。
package final class CompanyFilingSectionsSelectionOnly: Model, @unchecked Sendable {
    package static let schema = CompanyFilingSections.schema

    @ID(custom: "doc_id", generatedBy: .user)
    package var id: String?

    @Field(key: "code")
    package var code: String

    @Field(key: "submit_date_time")
    package var submitDateTime: String

    @Field(key: "cache_version")
    package var cacheVersion: String

    package init() {}
}
