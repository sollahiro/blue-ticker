// 銘柄ニュース（Brave）クライアントの Application 配線。テストは stub を注入する。

import Vapor

private struct CompanyNewsBoxKey: StorageKey {
    typealias Value = CompanyNewsBox
}

final class CompanyNewsBox: @unchecked Sendable {
    let client: any CompanyNewsClient
    init(client: any CompanyNewsClient) {
        self.client = client
    }
}

func installCompanyNewsDefaults(_ app: Application) {
    guard app.storage[CompanyNewsBoxKey.self] == nil else { return }
    if app.environment == .testing {
        app.storage[CompanyNewsBoxKey.self] = CompanyNewsBox(client: UnconfiguredCompanyNewsClient())
        return
    }
    app.storage[CompanyNewsBoxKey.self] = CompanyNewsBox(
        client: HTTPCompanyNewsClient.fromEnvironment())
}

func setCompanyNewsClient(_ app: Application, client: any CompanyNewsClient) {
    app.storage[CompanyNewsBoxKey.self] = CompanyNewsBox(client: client)
}

func companyNewsBox(for app: Application) -> CompanyNewsBox {
    installCompanyNewsDefaults(app)
    return app.storage[CompanyNewsBoxKey.self]!
}
