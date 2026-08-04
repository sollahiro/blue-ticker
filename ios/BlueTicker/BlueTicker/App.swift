import SwiftUI

@main
struct BlueTickerApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let code = ProcessInfo.processInfo.environment["BLT_DEBUG_SEED_CODE"] {
                    // スクリーンショット検証用の一時的なデバッグフック(later removed)。
                    CubeView(
                        company: CompanySearchResult(
                            code: code,
                            name: ProcessInfo.processInfo.environment["BLT_DEBUG_SEED_NAME"] ?? code,
                            sector: "", market: "", location: ""),
                        client: .local)
                } else {
                    SearchView()
                }
            }
        }
    }
}
