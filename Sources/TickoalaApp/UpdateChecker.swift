import Combine
import Foundation
import TickoalaCore

/// Kijkt af en toe of er op GitHub een nieuwere release staat en onthoudt die tag.
///
/// Dit is de enige plek in de app die het netwerk opgaat. Bewust spaarzaam: hoogstens
/// één verzoek per 24 uur, korte time-out, geen herhaalpogingen. Lukt het niet, dan
/// blijft het stil — een menubalkapp hoort niet te zeuren over een haperend netwerk.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var beschikbareVersie: String?

    /// Sleutel in UserDefaults waarmee de gebruiker de controle uitzet. Bewust niet
    /// in de settings-tabel: die is Int-gebaseerd, wordt gedeeld met het
    /// adaptercommando en gaat over de registratie, niet over de app zelf.
    static let disabledKey = "update-controle-uit"
    /// Waar de gebruiker de nieuwe versie ophaalt.
    static let releasePageURL = URL(string: "https://github.com/joost-heijden/Tickoala/releases/latest")!
    /// De projectpagina op GitHub.
    static let repositoryURL = URL(string: "https://github.com/joost-heijden/Tickoala")!

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/joost-heijden/Tickoala/releases/latest")!
    private static let lastCheckKey = "update-laatst-gecontroleerd"
    private static let interval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let session: URLSession
    private let currentVersion: String
    private var bezig = false

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        currentVersion: String = UpdateChecker.bundleVersion()
    ) {
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion
    }

    /// Veilig om vaak aan te roepen; de timer van AppModel doet dat elke seconde.
    /// Het netwerkverzoek zelf gebeurt pas als het etmaal sinds de vorige keer voorbij is.
    func checkIfNeeded(now: Date = Date()) {
        guard !defaults.bool(forKey: Self.disabledKey) else { return }
        guard !bezig else { return }
        if let laatste = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(laatste) < Self.interval {
            return
        }
        // Meteen vastleggen, ook als het verzoek straks mislukt: zo blijft het bij
        // één poging per etmaal in plaats van herhaald hameren.
        defaults.set(now, forKey: Self.lastCheckKey)
        bezig = true
        Task { await fetch() }
    }

    /// Zet de controle uit. Vanuit het menu, want er is geen instellingenscherm.
    func disable() {
        defaults.set(true, forKey: Self.disabledKey)
        beschikbareVersie = nil
    }

    private func fetch() async {
        defer { bezig = false }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 10
        // GitHub weigert verzoeken zonder User-Agent met een 403. Verder sturen we
        // niets mee: alleen welke versie het vraagt, geen id en geen gegevens.
        request.setValue("Tickoala/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            // Een 404 betekent "nog geen release" en is geen fout; net als elke
            // andere status doen we dan gewoon niets.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let tag = Self.tagName(in: data) else { return }
            beschikbareVersie = VersionCheck.newerVersion(current: currentVersion, available: [tag])
        } catch {
            // Geen netwerk of een time-out: zichtbaar niets doen is precies de bedoeling.
        }
    }

    private static func tagName(in data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return nil }
        return object["tag_name"] as? String
    }

    /// De versie uit de Info.plist. Buiten een echte bundel (een `swift run` tijdens
    /// het ontwikkelen) bestaat die niet; dan doen we ons voor als 0.0.0, zodat de
    /// vergelijking zich stilhoudt.
    nonisolated static func bundleVersion(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}
