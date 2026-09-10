import AppKit
import Foundation
import CoreLocation
import CoreWLAN
import WifiHoursCore

/// Houdt in de gaten op welk wifinetwerk de Mac zit en zet elke wisseling om in
/// een start- of stopsignaal. Dit vervangt ControlPlane als bron van de events;
/// de tracker krijgt precies dezelfde `ContextEvent`s als voorheen.
///
/// macOS geeft de netwerknaam sinds Sonoma alleen vrij aan programma's met
/// toestemming voor Locatievoorzieningen. Zonder die toestemming levert het
/// systeem `nil` op, wat niet te onderscheiden is van "geen wifi". Daarom worden
/// er alleen events verstuurd zolang de toestemming er is.
@MainActor
final class WifiWatcher: NSObject, ObservableObject {
    enum Access: Equatable {
        case unknown
        case granted
        case denied
        case locationServicesOff

        var needsAttention: Bool { self != .granted }

        var explanation: String? {
            switch self {
            case .granted:
                return nil
            case .unknown:
                return "WifiHours heeft toegang tot Locatievoorzieningen nodig om de netwerknaam te kunnen zien."
            case .denied:
                return "Zonder toegang tot Locatievoorzieningen kan macOS de netwerknaam niet vrijgeven, "
                     + "dus start en stopt de registratie niet vanzelf."
            case .locationServicesOff:
                return "Locatievoorzieningen staan uit op deze Mac; de netwerknaam is daardoor niet te zien."
            }
        }
    }

    @Published private(set) var currentSSID: String?
    @Published private(set) var access: Access = .unknown

    /// Wordt aangeroepen bij elke wisseling van netwerk.
    var onEvent: ((ContextEvent) -> Void)?

    private let locationManager = CLLocationManager()
    private let wifiClient = CWWiFiClient.shared()
    private var timer: Timer?
    /// `nil` = nog niets gemeten; `.some(nil)` = gemeten en geen netwerk.
    private var lastSeen: String??

    /// Hoe vaak er gekeken wordt. De systeemmeldingen over netwerkwissels zijn niet
    /// altijd betrouwbaar, dus dit is bewust gewoon periodiek opvragen.
    private let interval: TimeInterval = 5

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func start() {
        updateAccess()
        if case .unknown = access {
            locationManager.requestWhenInUseAuthorization()
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// Opent de vraag om toestemming, of de systeeminstellingen als die al beantwoord is.
    func requestAccess() {
        switch access {
        case .unknown:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .locationServicesOff:
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
            NSWorkspace.shared.open(url)
        case .granted:
            break
        }
    }

    private func updateAccess() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorized:
            access = .granted
        case .notDetermined:
            access = .unknown
        case .denied, .restricted:
            access = CLLocationManager.locationServicesEnabled() ? .denied : .locationServicesOff
        @unknown default:
            access = .unknown
        }
    }

    private func poll() {
        updateAccess()

        // Zonder toestemming is `nil` betekenisloos: dat zou een vals stopsignaal geven.
        guard access == .granted else {
            currentSSID = nil
            lastSeen = nil
            return
        }

        let ssid = wifiClient.interface()?.ssid()
        currentSSID = ssid

        guard let previous = lastSeen else {
            // Eerste meting na het opstarten: meteen starten als we al op een bekend net zitten.
            lastSeen = .some(ssid)
            if let ssid { emit(ssid, .start) }
            return
        }
        guard previous != ssid else { return }

        lastSeen = .some(ssid)
        if let previous { emit(previous, .stop) }
        if let ssid { emit(ssid, .start) }
    }

    private func emit(_ ssid: String, _ kind: EventKind) {
        onEvent?(ContextEvent(context: ssid, kind: kind, at: Date(), source: .wifi))
    }
}

extension WifiWatcher: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updateAccess()
            self.poll()
        }
    }
}
