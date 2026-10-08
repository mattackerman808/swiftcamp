import CoreLocation
import Foundation

/// Where this Mac is, once, when asked: the map's locate button.
///
/// One fix and done, not a running watch. A planner on a desk wants the
/// map brought to where it is, not a dot that follows the Wi-Fi's guess
/// around the room, and a watch would keep the location arrow lit in the
/// menu bar for as long as the window is open.
///
/// The hardened runtime refuses Location Services to an app that does not
/// carry `com.apple.security.personal-information.location`, silently: the
/// request never prompts and never answers. The entitlement is in
/// `Swiftcamp/Swiftcamp-macOS.entitlements`, and the release script signs
/// it in.
@MainActor
final class Locator: NSObject, CLLocationManagerDelegate {
    enum Failure: Error, LocalizedError {
        case denied, unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                "Location is off for Swiftcamp. Turn it on in System Settings › Privacy & Security › Location Services."
            case .unavailable(let reason):
                "This Mac's location is not available: \(reason)"
            }
        }
    }

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Coordinate, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        // A town's worth is plenty to centre a map on, and it comes from
        // Wi-Fi in a moment where a finer fix could take much longer.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// The Mac's position, asking permission the first time.
    func locate() async throws -> Coordinate {
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }   // one request answers everyone
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()   // answered in the delegate
            case .denied, .restricted:
                finish(.failure(Failure.denied))
            default:
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<Coordinate, Error>) {
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(with: result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard !waiting.isEmpty else { return }
            switch status {
            case .notDetermined: break   // the prompt is still up
            case .denied, .restricted: finish(.failure(Failure.denied))
            default: manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        let coordinate = Coordinate(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude)
        MainActor.assumeIsolated { finish(.success(coordinate)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated {
            finish(.failure(denied ? Failure.denied : Failure.unavailable(error.localizedDescription)))
        }
    }
}
