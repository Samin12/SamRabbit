import Foundation

let filter = CommandLine.arguments.dropFirst().first
exit(Harness.run([
    ("Inbox", InboxTests.all),
    ("Placement", PlacementTests.all),
    ("Visibility", VisibilityTests.all),
    ("Expansion", ExpansionTests.all),
    ("Keyboard", KeyboardTests.all),
], filter: filter))
