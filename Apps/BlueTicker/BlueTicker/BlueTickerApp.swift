import SwiftData
import SwiftUI

@main
struct BlueTickerApp: App {
    init() {
        Theme.applyChrome()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: WatchedCompany.self)
    }
}
