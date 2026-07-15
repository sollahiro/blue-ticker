import ArgumentParser
import Foundation

// Dev*(analyze/summarize) コマンドが共有する財務データ取得ヘルパー。
// API キー検証・銘柄コード検証・クライアント構築・会社名解決をまとめる。

/// 銘柄分析に必要なクライアント群と会社メタ情報。
struct AnalysisContext {
    let code: String
    let name: String
    let client: EdinetAPIClient
    let cacheManager: CacheManager
}

enum MetricsLoader {
    /// API キー検証・銘柄コード検証・クライアント構築・会社名解決をまとめて行う。
    /// 失敗時は stderr へ出力し `ExitCode.failure` を投げる。
    static func prepare(rawCode: String) async throws -> AnalysisContext {
        // キー検証・クライアント構築は EdinetClientLoader に集約（キー未設定を先に弾く）。
        let (client, cacheDir) = try await EdinetClientLoader.make()

        let codeTrimmed = rawCode.trimmingCharacters(in: .whitespaces)
        guard !codeTrimmed.isEmpty else {
            printError("エラー: 銘柄コードを指定してください。\n")
            throw ExitCode.failure
        }

        let cacheManager = CacheManager(cacheDir: derivedCacheDir(cacheDir))

        let masterDataManager = MasterDataManager()
        await masterDataManager.loadIfNeeded()
        let info = await masterDataManager.getByCode(codeTrimmed)

        return AnalysisContext(
            code: codeTrimmed,
            name: info?.coName ?? codeTrimmed,
            client: client,
            cacheManager: cacheManager
        )
    }
}
