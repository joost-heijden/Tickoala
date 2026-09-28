import Foundation
import TickoalaCore

/// Every check gets its own database file, so they run independently of each other.
final class Fixture {
    let path: String
    let store: Store
    let tracker: Tracker
    let profileA: Profile
    let profileB: Profile

    init() throws {
        path = NSTemporaryDirectory() + "tickoala-check-\(UUID().uuidString).sqlite3"
        store = try Store(path: path)
        tracker = Tracker(store: store)
        profileA = try store.createProfile(name: "Organization A", contexts: ["Office A"])
        profileB = try store.createProfile(name: "Organization B", contexts: ["Office B"])
        // A complete invoice needs sender details and a client address.
        var settings = try store.invoiceSettings()
        settings.senderName = "Studio Koala"
        settings.senderAddress = "Keizersgracht 1, 1015 CJ Amsterdam"
        try store.updateInvoiceSettings(settings)
        try store.updateProfileInvoicing(
            id: profileA.id, billingAddress: "Client Street 1\n1234 AB City",
            vatNumber: "NL000000001B01", vatRatePercent: 21, poNumber: ""
        )
        try store.updateProfileInvoicing(
            id: profileB.id, billingAddress: "Client Street 2\n5678 CD City",
            vatNumber: "NL000000002B01", vatRatePercent: 21, poNumber: ""
        )
    }

    deinit {
        Fixture.remove(path)
    }

    static func remove(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Creates a project and immediately sets it as the active project.
    @discardableResult
    func project(_ profile: Profile, number: String = "2401", name: String = "Migration") throws -> Project {
        let project = try store.createProject(profileId: profile.id, number: number, name: name)
        _ = try tracker.selectProject(profileId: profile.id, projectId: project.id)
        return project
    }

    @discardableResult
    func event(_ context: String, _ kind: EventKind, _ moment: String) throws -> EventOutcome {
        let date = at(moment)
        return try tracker.handle(ContextEvent(context: context, kind: kind, at: date), now: date)
    }

    func entries(_ day: String = "2026-09-10") throws -> [TimeEntry] {
        let start = at(day)
        let end = start.addingTimeInterval(24 * 3600)
        return try store.entries(from: start, to: end)
    }
}

func at(_ text: String) -> Date {
    guard let date = Formatting.parseDate(text) else {
        fatalError("invalid test date: \(text)")
    }
    return date
}

extension EventOutcome {
    var isStarted: Bool {
        if case .started = self { return true }
        return false
    }
}
