import Foundation

// Stand-ins for the app's `Config` and `Log` (Sources/Config.swift) in the headless voice harness: the bridge is the
// fake sync server named by the environment, the token comes from a temp file, and the log goes to stderr (never the
// real ~/Library/Logs/samrabbit-desktop.log, never the app's defaults).

enum Config {
    static var origin: URL {
        let raw = ProcessInfo.processInfo.environment["SAMRABBIT_APP_URL"] ?? "http://127.0.0.1:3790/app/"
        var components = URLComponents(string: raw) ?? URLComponents()
        components.path = ""
        components.query = nil
        return components.url ?? URL(string: "http://127.0.0.1:3790")!
    }

    static func token() -> String? {
        guard let path = ProcessInfo.processInfo.environment["SAMRABBIT_DESKTOP_TOKEN_FILE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count >= 16 ? token : nil
    }
}

enum Log {
    static let started = Date()

    static func write(_ message: String) {
        let line = String(format: "%7.2f ", Date().timeIntervalSince(started)) + message + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
