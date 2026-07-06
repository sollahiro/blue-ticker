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

    /// `fetchToken(appURL:)` の結果。失敗理由ごとに呼び出し元が原因を切り分けられるようにする。
    enum TokenFetchResult {
        case success(String)
        case binaryNotFound
        /// `cloudflared access token` が非ゼロ終了。stderr を診断用に保持する。
        case processFailed(exitCode: Int32, stderr: String)
        /// exit 0 だが stdout にトークンが無い。トークン未保存時の cloudflared は
        /// exit 0・stdout 空で stderr に理由（"Unable to find token ..."）を出すため、
        /// stderr を診断用に保持する。
        case emptyToken(stderr: String)
    }

    /// 診断メッセージに含める stderr の最大文字数。cloudflared が大量にログを吐いても
    /// エラーメッセージが肥大化しないよう、末尾のみを残す。
    private static let maxStderrCaptureLength = 500

    /// `cloudflared access token -app=<appURL>` でキャッシュ済み JWT を取得する。
    /// 未ログイン・失効時は失敗理由付きで返す（呼び出し元が再ログインを促す）。
    ///
    /// - Parameter binaryPathOverride: テスト専用。指定時は `resolveBinaryPath()` を経由せず
    ///   直接このパスを実行する。本番呼び出しでは指定しない（デフォルト nil で従来どおり解決）。
    static func fetchToken(appURL: String, binaryPathOverride: String? = nil) -> TokenFetchResult {
        let bin: String
        if let binaryPathOverride {
            bin = binaryPathOverride
        } else {
            guard let resolved = resolveBinaryPath() else { return .binaryNotFound }
            bin = resolved
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["access", "token", "-app=\(appURL)"]

        // stdout（JWT 本体）は Pipe＝メモリ内のみで受ける。一時ファイル経由にすると
        // 認証情報が短時間でもディスク（Linux では共有 /tmp・umask 依存の権限）に
        // 残るため不可。waitUntilExit() より先に readDataToEndOfFile() で読み切れば、
        // stdout 側のパイプバッファ詰まりによるデッドロックは起きない。
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        // stderr は一時ファイルへ書かせる。stderr も Pipe にして stdout →
        // stderr の順に逐次読みすると、stderr がパイプバッファ上限（通常 64KB）を
        // 超えた時点で子の書き込みがブロックし、stdout が閉じられず永久に返らなく
        // なる（元実装が stderr を /dev/null に捨てていた理由）。ファイル書き込みに
        // バッファ上限はなく子はブロックしないため、終了後に安全にまとめて読める。
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-cfaccess-stderr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        guard
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil),
            let stderrHandle = FileHandle(forWritingAtPath: stderrURL.path)
        else {
            return .processFailed(exitCode: -1, stderr: "一時ファイルの作成に失敗しました")
        }
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stderrHandle.close()
            return .processFailed(exitCode: -1, stderr: "\(error)")
        }
        // 書き込み側ディスクリプタは子プロセスへ複製済みなので親側は即クローズしてよい。
        try? stderrHandle.close()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let errData = (try? Data(contentsOf: stderrURL)) ?? Data()

        guard process.terminationStatus == 0 else {
            return .processFailed(exitCode: process.terminationStatus, stderr: capturedStderrText(from: errData))
        }
        let token = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else {
            return .emptyToken(stderr: capturedStderrText(from: errData))
        }
        return .success(token)
    }

    /// stderr の生データを診断メッセージ用に整形する（trim ＋ 長大な出力は末尾のみへキャップ）。
    private static func capturedStderrText(from data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.count > maxStderrCaptureLength else { return text }
        return "…(truncated)…" + text.suffix(maxStderrCaptureLength)
    }
}
