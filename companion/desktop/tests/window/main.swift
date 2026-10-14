import Foundation

// A tiny assert harness (like tests/swift): every test runs, failures are listed, the exit code says.

var failures: [String] = []
var current = ""

func expect(_ condition: Bool, _ message: String = "", line: Int = #line) {
    if !condition { failures.append("\(current) (line \(line)) \(message)") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", line: Int = #line) {
    if a != b { failures.append("\(current) (line \(line)) \(message): \(a) != \(b)") }
}

let tests: [(String, () -> Void)] = [
    ("parsesTheVoiceRequests", parsesTheVoiceRequests),
    ("parsesSettingsAndReady", parsesSettingsAndReady),
    ("leavesTheWindowsOwnMessagesAlone", leavesTheWindowsOwnMessagesAlone),
    ("voiceStateAsThePageReadsIt", voiceStateAsThePageReadsIt),
    ("throttlesOnlyTheLevel", throttlesOnlyTheLevel),
    ("scriptIsSafeJavaScript", scriptIsSafeJavaScript),
    ("shortcutsSayWhenTalkIsTaken", shortcutsSayWhenTalkIsTaken),
]

for (name, test) in tests {
    current = name
    test()
}
if failures.isEmpty {
    print("window tests: \(tests.count) passed")
    exit(0)
}
for failure in failures { print("FAIL \(failure)") }
print("window tests: \(failures.count) failure(s) in \(tests.count) tests")
exit(1)
