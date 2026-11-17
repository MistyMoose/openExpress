import Foundation
import MapKit

/// The geometry of a route on the map: where the camera looks and whether it is a loop.
public enum RouteGeometry {
    /// Start and finish closer than this (metres): one start/finish marker.
    public static let loopDistance: CLLocationDistance = 50

    /// The points that can be drawn: finite, on Earth, not the (0, 0) of a missing fix.
    public static func drawable(_ points: [ActivityTrack.Point]) -> [ActivityTrack.Point] {
        points.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && abs($0.latitude) <= 90 && abs($0.longitude) <= 180
                && !($0.latitude == 0 && $0.longitude == 0)
        }
    }

    public static func isLoop(_ points: [ActivityTrack.Point]) -> Bool {
        let p = drawable(points)
        guard let a = p.first, let b = p.last, p.count > 1 else { return true }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) < loopDistance
    }

    /// The route with room around it: 15% at the sides and the top, more at the bottom where
    /// the map's attribution is, so markers and route never touch it. At least 200 map points
    /// across, so a single point or a short track still makes a valid region. nil: nothing
    /// to draw.
    public static func cameraRect(_ points: [ActivityTrack.Point]) -> MKMapRect? {
        let mapPoints = drawable(points).map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        guard let first = mapPoints.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in mapPoints.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let w = max(maxX - minX, 200), h = max(maxY - minY, 200)
        let cx = (minX + maxX) / 2
        // Map y grows southwards: the bottom gets the larger margin.
        let rect = MKMapRect(x: cx - w * 0.65, y: minY - h * 0.18, width: w * 1.3, height: (maxY - minY) + h * 0.18 + h * 0.30)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.size.width > 0, rect.size.height > 0 else { return nil }
        return rect
    }
}
