import Foundation
import TickoalaCore

/// Location presence: the distance rule is pure and testable, and a stored
/// location links a hidden context so signals resolve like a network name.
func geoChecks() {
    suite("Location presence") {
        test("the distance between two coordinates is in meters") {
            // 0.001 degrees of latitude is about 111 meters.
            let distance = Geo.distanceMeters(lat1: 52.3700, lon1: 4.8900, lat2: 52.3710, lon2: 4.8900)
            expect(distance > 100 && distance < 120, "about 111 m, got \(distance)")
        }

        test("the closest client within its radius is chosen") {
            let near = Profile(id: 1, name: "Near", contexts: ["geo:1"], latitude: 52.3700, longitude: 4.8900, presenceRadiusMeters: 200)
            let far = Profile(id: 2, name: "Far", contexts: ["geo:2"], latitude: 52.3800, longitude: 4.8900, presenceRadiusMeters: 200)

            let found = Geo.nearestProfile(to: 52.3701, 4.8900, profiles: [near, far])
            expectEqual(found?.id, near.id)
        }

        test("outside every radius there is no client") {
            let near = Profile(id: 1, name: "Near", contexts: ["geo:1"], latitude: 52.3700, longitude: 4.8900, presenceRadiusMeters: 100)
            let found = Geo.nearestProfile(to: 52.4000, 4.8900, profiles: [near])
            expect(found == nil, "far away is nobody")
        }

        test("a client you are at stays selected a bit outside its radius") {
            // Radius 100 m, but the client stays current up to 130 m.
            let client = Profile(id: 1, name: "Near", contexts: ["geo:1"], latitude: 52.3700, longitude: 4.8900, presenceRadiusMeters: 100)
            let justOutside = 52.3700 + 0.00107 // about 119 m north

            let withoutCurrent = Geo.nearestProfile(to: justOutside, 4.8900, profiles: [client])
            expect(withoutCurrent == nil, "alone it is outside the radius")

            let withCurrent = Geo.nearestProfile(to: justOutside, 4.8900, profiles: [client], stayingAt: client)
            expectEqual(withCurrent?.id, client.id, "but current stays until clearly gone")
        }

        test("a stored location links a hidden context and survives a restart") {
            let fixture = try Fixture()
            try fixture.store.updateProfileLocation(
                id: fixture.profileA.id, latitude: 52.37, longitude: 4.89, radiusMeters: 120
            )

            let profile = try expectNotNil(fixture.store.profile(id: fixture.profileA.id))
            expect(profile.contexts.contains(profile.geoContext), "the hidden context is linked")
            expectEqual(profile.presenceRadiusMeters, 120)
            expectEqual(profile.wifiContexts.contains("geo:\(profile.id)"), false, "the marker stays out of the Wi-Fi list")

            let again = try Store(path: fixture.path)
            let stored = try expectNotNil(again.profile(id: fixture.profileA.id))
            expect(stored.hasLocation, "the coordinates survive a restart")

            try fixture.store.updateProfileLocation(
                id: fixture.profileA.id, latitude: nil, longitude: nil, radiusMeters: 120
            )
            let cleared = try expectNotNil(fixture.store.profile(id: fixture.profileA.id))
            expect(!cleared.contexts.contains(cleared.geoContext), "clearing removes the hidden context")
        }
    }
}
