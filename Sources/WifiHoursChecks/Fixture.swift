import Foundation
import WifiHoursCore

/// Elke check krijgt een eigen databasebestand, zodat ze los van elkaar draaien.
final class Fixture {
    let path: String
    let store: Store
    let tracker: Tracker
    let profileA: Profile
    let profileB: Profile

    init() throws {
        path = NSTemporaryDirectory() + "wifihours-check-\(UUID().uuidString).sqlite3"
        store = try Store(path: path)
        tracker = Tracker(store: store)
        profileA = try store.createProfile(name: "Organisatie A", contextName: "Kantoor A")
        profileB = try store.createProfile(name: "Organisatie B", contextName: "Kantoor B")
    }

    deinit {
        Fixture.remove(path)
    }

    static func remove(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Maakt een project en zet het meteen als actief project.
    @discardableResult
    func project(_ profile: Profile, number: String = "2401", name: String = "Migratie") throws -> Project {
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
        fatalError("ongeldige testdatum: \(text)")
    }
    return date
}

extension EventOutcome {
    var isStarted: Bool {
        if case .started = self { return true }
        return false
    }
}
