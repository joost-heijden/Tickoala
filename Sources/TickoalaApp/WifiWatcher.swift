import AppKit
import Foundation
import CoreLocation
import CoreWLAN
import TickoalaCore

/// Watches which Wi-Fi network the Mac is on and turns every change into a start
/// or stop signal. This replaces ControlPlane as the source of the events; the
/// tracker receives exactly the same `ContextEvent`s as before.
///
/// Since Sonoma, macOS only reveals the network name to programs with Location
/// Services permission. Without that permission the system returns `nil`, which
/// cannot be distinguished from "no Wi-Fi". That is why events are only sent as
/// long as the permission is there.
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
                return "Tickoala needs Location Services access to be able to see the network name."
            case .denied:
                return "Without Location Services access, macOS cannot reveal the network name, "
                     + "so tracking will not start and stop automatically."
            case .locationServicesOff:
                return "Location Services is turned off on this Mac; the network name is therefore not visible."
            }
        }
    }

    @Published private(set) var currentSSID: String?
    @Published private(set) var access: Access = .unknown

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

        // Without permission, `nil` is meaningless: it would give a false stop signal.
        guard access == .granted else {
            currentSSID = nil
            lastSeen = nil
            return
        }

        let ssid = wifiClient.interface()?.ssid()
        currentSSID = ssid

        guard let previous = lastSeen else {
            // First measurement after startup: start right away if we are already on a known network.
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
