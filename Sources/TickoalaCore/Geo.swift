import Foundation

/// Small location helpers. Kept free of CoreLocation so the distance rule stays
/// testable without a location manager, and the core stays a plain library.
public enum Geo {
    /// Distance between two coordinates in meters (haversine).
    public static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let radians = Double.pi / 180
        let deltaLat = (lat2 - lat1) * radians
        let deltaLon = (lon2 - lon1) * radians
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// The client whose stored location is within its radius and closest to the
    /// given coordinate, or `nil` when the coordinate is not near any of them.
    public static func nearestProfile(to latitude: Double, _ longitude: Double, profiles: [Profile]) -> Profile? {
        var best: (profile: Profile, distance: Double)?
        for profile in profiles {
            guard let lat = profile.latitude, let lon = profile.longitude else { continue }
            let distance = distanceMeters(lat1: latitude, lon1: longitude, lat2: lat, lon2: lon)
            guard distance <= Double(profile.presenceRadiusMeters) else { continue }
            if best == nil || distance < best!.distance {
                best = (profile, distance)
            }
        }
        return best?.profile
    }
}
