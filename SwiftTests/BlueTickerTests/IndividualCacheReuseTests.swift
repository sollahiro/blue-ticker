import Testing
import Foundation
@testable import BlueTickerCore

// individual_analysis derived キャッシュの再利用判定（individualCacheIsReusable）の仕様。
// キャッシュキー（individual_analysis_<code>）は年数を含まないため、バージョン一致に加えて
// 構築時要求年数（_requested_years）>= 今回要求年数 のときのみ再利用できる
// （trimMetrics は縮小のみ可能で、少ない年数で構築したキャッシュは要求年数まで拡張できない）。

@Suite struct IndividualCacheReuseTests {

    private let version = "test-v1"

    private func cached(version: String = "test-v1", requestedYears: Int? = 10) -> [String: Any] {
        var dict: [String: Any] = ["_cache_version": version]
        if let requestedYears { dict["_requested_years"] = requestedYears }
        return dict
    }

    // MARK: - 再利用できる場合

    @Test func reusableWhenVersionMatchesAndStoredYearsCoverRequest() {
        #expect(individualCacheIsReusable(cached(), cacheVersion: version, requestedYears: 5))
    }

    @Test func reusableWhenStoredYearsEqualRequest() {
        #expect(individualCacheIsReusable(
            cached(requestedYears: 5), cacheVersion: version, requestedYears: 5))
    }

    // MARK: - 再利用できない場合

    @Test func notReusableWhenCacheMissing() {
        #expect(!individualCacheIsReusable(nil, cacheVersion: version, requestedYears: 5))
    }

    @Test func notReusableWhenVersionMismatches() {
        #expect(!individualCacheIsReusable(
            cached(version: "old-v0"), cacheVersion: version, requestedYears: 5))
    }

    @Test func notReusableWhenVersionFieldMissing() {
        #expect(!individualCacheIsReusable(
            ["_requested_years": 10], cacheVersion: version, requestedYears: 5))
    }

    @Test func notReusableWhenStoredYearsInsufficient() {
        // 3年分で構築したキャッシュは5年要求に対して再利用できない（拡張不能）
        #expect(!individualCacheIsReusable(
            cached(requestedYears: 3), cacheVersion: version, requestedYears: 5))
    }

    @Test func missingRequestedYearsFieldIsTreatedAsZero() {
        // 旧形式キャッシュ（_requested_years なし）は 0 扱いで再利用しない
        #expect(!individualCacheIsReusable(
            cached(requestedYears: nil), cacheVersion: version, requestedYears: 5))
    }

    @Test func requestedYearsFieldOfWrongTypeIsTreatedAsZero() {
        // 型が壊れたキャッシュ（文字列など）も 0 扱いで再利用しない
        var dict = cached(requestedYears: nil)
        dict["_requested_years"] = "10"
        #expect(!individualCacheIsReusable(dict, cacheVersion: version, requestedYears: 5))
    }
}
