import Foundation

/// Where the app finds the bridge and its desktop token.
///
/// Base URL (first match wins, loopback only): `--base-url <url>`, `$SAMRABBIT_APP_URL`,
/// `defaults write com.samrabbit.desktop BaseURL <url>`, else `http://127.0.0.1:3780/app/`.
/// Token file: `--token-file <path>`, `$SAMRABBIT_DESKTOP_TOKEN_FILE`, `defaults … TokenFile`,
/// else `~/.config/samrabbit/desktop-token` (created 0600 by install.sh). The token is never logged.
enum Config {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:3780/app/")!
    static let tokenHeader = "X-SamRabbit-Desktop"
    static let tokenCookie = "sr_desktop"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    static let baseURL: URL = resolveBaseURL()
    static let tokenFile: String = resolveTokenFile()

    static var origin: URL {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.url ?? URL(string: "http://127.0.0.1:3780")!
    }

    static var isDefaultBase: Bool { baseURL == defaultBaseURL }

    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: name), index + 1 < args.count { return args[index + 1] }
        if let pair = args.first(where: { $0.hasPrefix(name + "=") }) { return String(pair.dropFirst(name.count + 1)) }
        return nil
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    private static func resolveBaseURL() -> URL {
        let candidates = [argument("--base-url"), ProcessInfo.processInfo.environment["SAMRABBIT_APP_URL"],
                          UserDefaults.standard.string(forKey: "BaseURL")]
        for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespaces) }) where !candidate.isEmpty {
            guard var url = URL(string: candidate), isLoopback(url) else {
                Log.write("ignoring a base URL that is not on this Mac (loopback only)")
                continue
            }
            if !url.hasDirectoryPath, url.query == nil {
                url = URL(string: candidate + "/") ?? url
            }
            return url
        }
        return defaultBaseURL
    }

    private static func resolveTokenFile() -> String {
        let candidates = [argument("--token-file"), ProcessInfo.processInfo.environment["SAMRABBIT_DESKTOP_TOKEN_FILE"],
                          UserDefaults.standard.string(forKey: "TokenFile")]
        let chosen = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? "~/.config/samrabbit/desktop-token"
        return (chosen as NSString).expandingTildeInPath
    }

    /// The desktop token, or nil when the file is missing or malformed.
    static func token() -> String? {
        guard let data = FileManager.default.contents(atPath: tokenFile),
              let text = String(data: data.prefix(4096), encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 16, token.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        return token
    }

    /// A request to the bridge with the desktop token header.
    static func request(_ url: URL, timeout: TimeInterval = 8) -> URLRequest? {
        guard let token = token() else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(token, forHTTPHeaderField: tokenHeader)
        return request
    }

    static func api(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }
}

/// Append-only log at ~/Library/Logs/samrabbit-desktop.log (0600; `$SAMRABBIT_DESKTOP_LOG` for dev runs of a
/// second copy). Never contains tokens or conversation content: only states, HTTP statuses and counts.
enum Log {
    static let url = ProcessInfo.processInfo.environment["SAMRABBIT_DESKTOP_LOG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/samrabbit-desktop.log")
    private static let queue = DispatchQueue(label: "com.samrabbit.desktop.log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > 2_000_000 {
                try? manager.removeItem(at: url)
            }
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
