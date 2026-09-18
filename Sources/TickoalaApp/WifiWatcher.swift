import AppKit
import Foundation
import CoreLocation
import CoreWLAN
import SystemConfiguration
import TickoalaCore

/// Watches which network the Mac is on and turns every change into a start or
/// stop signal. This replaces ControlPlane as the source of the events; the
/// tracker receives exactly the same `ContextEvent`s as before.
///
/// The identity is the Wi-Fi SSID when Wi-Fi is associated. When it is not — for
/// example when the Mac shares a wired connection over Wi-Fi (Internet Sharing)
/// — the wired connection is identified by its DHCP domain name, or by the
/// router address when the network has no domain.
///
/// Since Sonoma, macOS only reveals the SSID to programs with Location Services
/// permission. Without that permission Wi-Fi is treated as unavailable; a wired
/// connection is still recognised.
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
                return "Tickoala needs Location Services access to see the network name "
                     + "(and, when detection is set to Location, your position)."
            case .denied:
                return "Without Location Services access, macOS cannot reveal the network name, "
                     + "so tracking will not start and stop automatically."
            case .locationServicesOff:
                return "Location Services is turned off on this Mac; the network name and your "
                     + "position are therefore not visible."
            }
        }
    }

    @Published private(set) var currentSSID: String?
    @Published private(set) var access: Access = .unknown
    /// Last known coordinate, for capturing a client's location from the UI.
    @Published private(set) var latitude: Double?
    @Published private(set) var longitude: Double?

    /// What decides presence: the network name or the Mac's location.
    var source: PresenceSource = .wifi
    /// Turns a coordinate into the context of the client there, if any.
    var resolveLocationContext: ((Double, Double) -> String?)?

    /// Called on every network change.
    var onEvent: ((ContextEvent) -> Void)?

    private let locationManager = CLLocationManager()
    private let wifiClient = CWWiFiClient.shared()
    private var timer: Timer?
    /// `nil` = nothing measured yet; `.some(nil)` = measured and no network.
    private var lastSeen: String??

    /// How often it checks. The system notifications about network changes are not
    /// always reliable, so this deliberately just polls periodically.
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

    /// Opens the permission prompt, or the system settings if it has already been answered.
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

        // On location detection the network is irrelevant: the delegate turns
        // coordinate updates into context changes instead.
        if source == .location {
            // Coarse but battery-friendly: we only need to know the client's
            // radius, and updates only when the Mac has moved a bit.
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 50
            locationManager.startUpdatingLocation()
            return
        }
        locationManager.stopUpdatingLocation()

        // Without permission the SSID is invisible; a wired connection doesn't
        // depend on it, so only treat Wi-Fi as missing when there is nothing else.
        let ssid = access == .granted ? wifiClient.interface()?.ssid() : nil
        let wired = ssid == nil ? wiredNetworkName() : nil

        // Without permission and without a wired signal, `nil` is meaningless: it
        // would give a false stop signal.
        guard access == .granted || wired != nil else {
            currentSSID = nil
            lastSeen = nil
            return
        }

        apply(ssid ?? wired)
    }

    /// Shared transition logic: stop the context left behind and start the new
    /// one. Both Wi-Fi and location changes run through this.
    private func apply(_ context: String?) {
        currentSSID = context

        guard let previous = lastSeen else {
            // First measurement after startup: start right away if we are already
            // on a known network or at a known location.
            lastSeen = .some(context)
            if let context { emit(context, .start) }
            return
        }
        guard previous != context else { return }

        lastSeen = .some(context)
        if let previous { emit(previous, .stop) }
        if let context { emit(context, .start) }
    }

    /// Name of the wired connection the Mac is on, taken from the primary
    /// service's DHCP lease: the domain name if it has one, otherwise the router
    /// address. `nil` when the primary connection still is Wi-Fi or has no lease.
    private func wiredNetworkName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Tickoala" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let service = global["PrimaryService"] as? String,
              let interface = global["PrimaryInterface"] as? String,
              interface != wifiClient.interface()?.interfaceName,
              let dhcp = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/DHCP" as CFString) as? [String: Any]
        else { return nil }

        if let data = dhcp["Option_15"] as? Data,
           let domain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !domain.isEmpty {
            return domain
        }
        if let data = dhcp["Option_3"] as? Data, data.count == 4 {
            return data.map(String.init).joined(separator: ".")
        }
        return nil
    }

    private func emit(_ context: String, _ kind: EventKind) {
        onEvent?(ContextEvent(context: context, kind: kind, at: Date(), source: source == .location ? .location : .wifi))
    }
}

extension WifiWatcher: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updateAccess()
            self.poll()
        }
    }

    /// Every location update is mapped to the client there, if any, and then
    /// treated exactly like a network change.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        Task { @MainActor in
            guard self.source == .location else { return }
            self.latitude = latitude
            self.longitude = longitude
            self.apply(self.resolveLocationContext?(latitude, longitude))
        }
    }
}
