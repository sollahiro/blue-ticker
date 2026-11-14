import SwiftData
import SwiftUI

@main
struct BlueTickerApp: App {
    private let modelContainer: ModelContainer
    /// Intent（アプリと同じプロセスで動く）も同じ保存領域を使う。
    static let sharedContainer: ModelContainer = makeWatchlistContainer()

    init() {
        Theme.applyChrome()
        modelContainer = Self.sharedContainer
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }

    /// 同じ Apple ID の端末へリストを同期する。
    /// CloudKit が使えないときは、既存のローカル店に落とす。
    private static func makeWatchlistContainer() -> ModelContainer {
        let schema = Schema([WatchedCompany.self])
        let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        do {
            return try ModelContainer(for: schema, configurations: [cloud])
        } catch {
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [local])
            } catch {
                fatalError("SwiftData の保存領域を開けませんでした: \(error)")
            }
        }
    }
}
