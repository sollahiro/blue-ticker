import BlueTickerCore
import Foundation

// AsyncParsableCommand.main() はエラー時のみ exit() を呼び、成功時は return する。
// exit(0) を呼ばないと RunLoop.main.run() が回り続けプロセスが終了しない。
Task {
    await Ticker.main()
    exit(0)
}
RunLoop.main.run()
