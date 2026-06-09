// XBRL コンテキスト判定ユーティリティ
// Python の blue_ticker/analysis/context_helpers.py 相当

enum ContextHelpers {

    /// 連結の当期損益コンテキストかどうか。セグメント軸メンバー（Member末尾）は除外する。
    static func isConsolidatedDuration(_ ctx: String) -> Bool {
        Xbrl.durationContextPatterns.contains(where: { ctx.contains($0) })
            && !ctx.contains("_NonConsolidated")
            && !ctx.hasSuffix("Member")
    }

    /// 連結の前期損益コンテキストかどうか。
    static func isConsolidatedPriorDuration(_ ctx: String) -> Bool {
        Xbrl.priorDurationContextPatterns.contains(where: { ctx.contains($0) })
            && !ctx.contains("_NonConsolidated")
            && !ctx.hasSuffix("Member")
    }

    /// 個別の当期損益コンテキストかどうか。
    static func isNonConsolidatedDuration(_ ctx: String) -> Bool {
        Xbrl.durationContextPatterns.contains(where: { ctx.contains($0) })
            && ctx.contains("_NonConsolidated")
    }

    /// 個別の前期損益コンテキストかどうか。
    static func isNonConsolidatedPriorDuration(_ ctx: String) -> Bool {
        Xbrl.priorDurationContextPatterns.contains(where: { ctx.contains($0) })
            && ctx.contains("_NonConsolidated")
    }

    /// セグメント修飾のない完全一致コンテキストかどうか。
    static func isPureContext(_ ctx: String, patterns: [String]) -> Bool {
        patterns.contains(ctx)
    }

    /// 個別財務諸表のセグメント修飾なしコンテキストかどうか。
    static func isPureNonConsolidatedContext(_ ctx: String, patterns: [String]) -> Bool {
        patterns.contains(where: {
            ctx == "\($0)_NonConsolidatedMember" || ctx == "\($0)_NonConsolidated"
        })
    }

    /// 連結の期末残高コンテキストかどうか。
    static func isConsolidatedInstant(_ ctx: String) -> Bool {
        Xbrl.instantContextPatterns.contains(where: { ctx.contains($0) })
            && !ctx.contains("_NonConsolidated")
            && !ctx.hasSuffix("Member")
    }

    /// 連結の前期末残高コンテキストかどうか。
    static func isConsolidatedPriorInstant(_ ctx: String) -> Bool {
        Xbrl.priorInstantContextPatterns.contains(where: { ctx.contains($0) })
            && !ctx.contains("_NonConsolidated")
            && !ctx.hasSuffix("Member")
    }

    /// 個別の期末残高コンテキストかどうか。
    static func isNonConsolidatedInstant(_ ctx: String) -> Bool {
        Xbrl.instantContextPatterns.contains(where: { ctx.contains($0) })
            && ctx.contains("_NonConsolidated")
    }

    /// 個別の前期末残高コンテキストかどうか。
    static func isNonConsolidatedPriorInstant(_ ctx: String) -> Bool {
        Xbrl.priorInstantContextPatterns.contains(where: { ctx.contains($0) })
            && ctx.contains("_NonConsolidated")
    }

    /// 連結財務諸表ありの書類かどうかを返す。
    ///
    /// True の場合、この書類は連結グループを持つため、単体フォールバックを抑止すべき。
    static func hasNonConsolidatedContexts(_ tagElements: XbrlTagElements) -> Bool {
        let allPureConsolidated = Set(Xbrl.durationContextPatterns + Xbrl.instantContextPatterns)

        // 条件1: 同一タグに連結+NonConsolidated
        for ctxMap in tagElements.values {
            let hasCons = ctxMap.keys.contains(where: { allPureConsolidated.contains($0) })
            let hasNC = ctxMap.keys.contains(where: { $0.contains("_NonConsolidated") })
            if hasCons && hasNC { return true }
        }

        // 条件2: IFRS/US-GAAP タグが存在し、かつ任意タグに NonConsolidated がある
        let hasIfrsUsgaap = tagElements.keys.contains(where: { $0.contains("IFRS") || $0.contains("USGAAP") })
        if hasIfrsUsgaap {
            return tagElements.values.contains(where: {
                $0.keys.contains(where: { $0.contains("_NonConsolidated") })
            })
        }
        return false
    }
}
