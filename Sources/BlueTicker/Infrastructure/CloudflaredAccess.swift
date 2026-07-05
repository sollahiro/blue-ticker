import Foundation

/// `cloudflared access` を呼び出し、Cloudflare Access への SSO ログイン（ブラウザ）と
/// JWT 取得を行う薄いラッパー。JWT 自体の保管・更新は cloudflared 側に委ねる
/// （blue_ticker は config.json に有効化フラグのみ持つ）。
enum CloudflaredAccess {
    /// `cloudflared` 実行パスを解決する。Homebrew 等の既知の設置場所を優先し、
    /// 無ければ PATH を走査する。見つからなければ nil。
    static func resolveBinaryPath() -> String? {
        let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/cloudflared"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// `cloudflared access login <appURL>` を対話的に実行する（標準入出力を継承しブラウザを開かせる）。
    static func login(appURL: String) -> Bool {
        guard let bin = resolveBinaryPath() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        // -q: 認証成功時に JWT 本体を標準出力へ出さない（ターミナル/ログへの露出防止）。
        // トークン自体は cloudflared のローカルストレージに保存され、fetchToken() で取得できる。
        process.arguments = ["access", "login", "-q", appURL]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// `cloudflared access token -app=<appURL>` でキャッシュ済み JWT を取得する。
    /// 未ログイン・失効時は nil（呼び出し元が再ログインを促す）。
    static func fetchToken(appURL: String) -> String? {
        guard let bin = resolveBinaryPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["access", "token", "-app=\(appURL)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        // stderr は読み捨てる。Pipe のまま放置すると出力がバッファ上限を超えたときに
        // 子プロセスの書き込みがブロックし waitUntilExit() がデッドロックし得るため /dev/null へ流す。
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // 子プロセスの終了（＝パイプの書き込み側クローズ）を待たず先に読み切る。
            // waitUntilExit() を先に呼ぶと、出力がパイプバッファ上限を超えた場合に
            // 子プロセスの書き込みブロック待ちで永久に返らなくなるおそれがある。
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        } catch {
            return nil
        }
    }
}
