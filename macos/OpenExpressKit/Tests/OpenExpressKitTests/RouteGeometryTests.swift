import Foundation
import MapKit
import Testing
@testable import OpenExpressKit

@Suite("Route geometry")
struct RouteGeometryTests {
    /// A synthetic coastal loop of 1345 points, about 5 × 3.5 km (the size of a real one).
    static let loop: [ActivityTrack.Point] = (0..<1345).map { i in
        let t = Double(i) / 1344 * 2 * .pi
        return .init(latitude: 46.20 + 0.0155 * sin(t) + 0.002 * sin(9 * t),
                     longitude: 7.10 + 0.036 * cos(t) + 0.003 * cos(7 * t), time: Double(i))
    }

    static func check(_ points: [ActivityTrack.Point]) throws {
        let rect = try #require(RouteGeometry.cameraRect(points))
        #expect(rect.origin.x.isFinite && rect.origin.y.isFinite)
        #expect(rect.size.width > 0 && rect.size.height > 0)
        for p in RouteGeometry.drawable(points) {
            #expect(rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))))
        }
        // Room below the route for the attribution: the bottom margin is the larger one.
        let ys = RouteGeometry.drawable(points).map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)).y }
        #expect(rect.maxY - ys.max()! > ys.min()! - rect.minY)
    }

    @Test func syntheticLoop() throws {
        try Self.check(Self.loop)
        #expect(RouteGeometry.isLoop(Self.loop))
        #expect(RouteGeometry.isLoop(MockEngine.sampleTrack(loop: true).points))
        #expect(!RouteGeometry.isLoop(MockEngine.sampleTrack(loop: false).points))
    }

    @Test func degenerateTracks() throws {
        #expect(RouteGeometry.cameraRect([]) == nil)
        try Self.check([.init(latitude: 52, longitude: 5)])                 // one point
        try Self.check(Array(repeating: .init(latitude: 52, longitude: 5), count: 10))
        // A missing fix (0, 0) and garbage are left out, not stretched over half the Earth.
        let withGaps = Self.loop + [.init(latitude: 0, longitude: 0), .init(latitude: .nan, longitude: 5)]
        let rect = try #require(RouteGeometry.cameraRect(withGaps))
        #expect(rect.size.width < 10_000_000)
    }

    /// The user's own track, never in the repository: `OE_REAL_TRACK=<engine response .json>`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OE_REAL_TRACK"] != nil))
    func realTrack() throws {
        let path = try #require(ProcessInfo.processInfo.environment["OE_REAL_TRACK"])
        let value = try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: URL(fileURLWithPath: path)))
        let track = try (value["result"] ?? value).decode(ActivityTrack.self)
        #expect(track.points.count > 100)
        try Self.check(track.points)
        #expect(RouteGeometry.isLoop(track.points))
    }
}
