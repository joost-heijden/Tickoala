import Combine
import Foundation
import TickoalaCore

/// Occasionally checks whether a newer version tag exists on GitHub and remembers it.
///
/// This is the only place in the app that goes onto the network. Deliberately
/// frugal: at most one request per 24 hours, short timeout, no retries. If it
/// fails, it stays quiet — a menu bar app should not nag about a flaky network.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var availableVersion: String?
    /// Is the daily check enabled? The menu uses this to show the right button.
    @Published private(set) var isEnabled: Bool

    /// Key in UserDefaults with which the user turns the check off. Deliberately
    /// not in the settings table: that is Int-based, is shared with the adapter
    /// command and concerns tracking, not the app itself.
    static let disabledKey = "update-check-disabled"
    /// The project page on GitHub.
    static let repositoryURL = URL(string: "https://github.com/joost-heijden/Tickoala")!
    /// The tag page on GitHub, so you can immediately see what is new.
    static func tagURL(for tag: String) -> URL? {
        URL(string: "https://github.com/joost-heijden/Tickoala/tree/\(tag)")
    }

    // Versions live in tags, not in releases: one tag is enough to report an
    // update. The order from the API says nothing about the version; VersionCheck
    // picks the highest itself.
    private static let tagsURL = URL(string: "https://api.github.com/repos/joost-heijden/Tickoala/tags?per_page=100")!
    private static let lastCheckKey = "update-last-checked"
    private static let interval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let session: URLSession
    /// The running version; also visible in the menu so you know what you have.
    let currentVersion: String
    private var isFetching = false

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        currentVersion: String = UpdateChecker.bundleVersion()
    ) {
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion
        self.isEnabled = !defaults.bool(forKey: Self.disabledKey)
    }

    /// Safe to call often; the AppModel timer does so every second. The network
    /// request itself only happens once the day since the previous one has passed.
    func checkIfNeeded(now: Date = Date()) {
        guard isEnabled, !isFetching else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(last) < Self.interval {
            return
        }
        // Record it immediately, even if the request fails later: that keeps it to
        // one attempt per day instead of hammering repeatedly.
        defaults.set(now, forKey: Self.lastCheckKey)
        startFetch()
    }

    /// Manual check from the menu; ignores the day, because the user explicitly asks now.
    func checkNow() {
        guard isEnabled, !isFetching else { return }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        availableVersion = nil
        startFetch()
    }

    /// Turns the check off. From the menu, because there is no settings screen.
    func disable() {
        defaults.set(true, forKey: Self.disabledKey)
        isEnabled = false
        availableVersion = nil
    }

    /// Turns the check back on and immediately looks for something new.
    func enable() {
        defaults.set(false, forKey: Self.disabledKey)
        isEnabled = true
        checkNow()
    }

    private func startFetch() {
        isFetching = true
        Task { await fetch() }
    }

    private func fetch() async {
        defer { isFetching = false }

        var request = URLRequest(url: Self.tagsURL)
        request.timeoutInterval = 10
        // GitHub rejects requests without a User-Agent with a 403. Beyond that we
        // send nothing: only which version is asking, no id and no data.
        request.setValue("Tickoala/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            // No tags or a different status: then there is nothing new to report.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            availableVersion = VersionCheck.newerVersion(current: currentVersion, available: Self.tagNames(in: data))
        } catch {
            // No network or a timeout: visibly doing nothing is exactly the point.
        }
    }

    private static func tagNames(in data: Data) -> [String] {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { $0["name"] as? String }
    }

    /// The version from Info.plist. Outside a real bundle (a `swift run` during
    /// development) it doesn't exist; then we pretend to be 0.0.0, so the
    /// comparison keeps quiet.
    nonisolated static func bundleVersion(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}
