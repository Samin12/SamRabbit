import Foundation

// A tiny assert harness: each suite lists named test closures; a failed check prints where and why and the run
// exits non-zero. No XCTest, so it runs with only the command line tools.

enum Harness {
    static var checks = 0
    static var failures: [String] = []
    static var current = ""

    static func check(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString, line: UInt) {
        checks += 1
        if !condition {
            let name = (String(describing: file) as NSString).lastPathComponent
            failures.append("\(current): \(message()) (\(name):\(line))")
        }
    }

    static func run(_ suites: [(String, [(String, () throws -> Void)])], filter: String?) -> Int32 {
        var ran = 0
        for (suite, tests) in suites {
            for (name, body) in tests {
                current = "\(suite).\(name)"
                if let filter, !current.localizedCaseInsensitiveContains(filter) { continue }
                ran += 1
                let before = failures.count
                do { try body() } catch { failures.append("\(current): threw \(error)") }
                print(failures.count == before ? "ok    \(current)" : "FAIL  \(current)")
            }
        }
        for failure in failures { print("  ✗ \(failure)") }
        print("\(ran) tests, \(checks) checks, \(failures.count) failures")
        return failures.isEmpty && ran > 0 ? 0 : 1
    }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true", file: StaticString = #file, line: UInt = #line) {
    Harness.check(condition, message(), file: file, line: line)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ note: String = "", file: StaticString = #file, line: UInt = #line) {
    Harness.check(actual == expected, "expected \(expected), got \(actual)\(note.isEmpty ? "" : " — \(note)")", file: file, line: line)
}

func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat = 0.01, file: StaticString = #file, line: UInt = #line) {
    Harness.check(abs(actual - expected) <= tolerance, "expected ≈\(expected), got \(actual)", file: file, line: line)
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The shared fixture (dev/samples/inbox.json), shifted so its base time is `now`.
enum Fixture {
    static func json() throws -> [String: Any] {
        guard let path = ProcessInfo.processInfo.environment["DOCK_FIXTURE"],
              let data = FileManager.default.contents(atPath: path),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure("DOCK_FIXTURE is missing or unreadable")
        }
        return object
    }

    static func inboxData() throws -> Data {
        let object = try json()
        guard let inbox = object["inbox"] else { throw TestFailure("fixture has no inbox") }
        return try JSONSerialization.data(withJSONObject: inbox)
    }

    static func base() throws -> Date {
        guard let text = try json()["base"] as? String, let date = DockDate.parse(text) else { throw TestFailure("no base") }
        return date
    }
}
