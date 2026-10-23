import SwiftUI
import CoreLocation

// Optional display-only map. All mileage, GPS capture and saved track
// coordinates continue to use the original Core Location data.
struct BaiduRouteMap: UIViewRepresentable {
    let shift: Shift
    let playbackCoordinate: CLLocationCoordinate2D?
    let followVehicle: Bool
    let liveCoordinate: CLLocationCoordinate2D?
    static var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "BaiduMapAK") as? String else { return false }
        return !key.isEmpty
    }
    func makeUIView(context: Context) -> BaiduMapHostView {
        BaiduMapHostView(frame: .zero)
    }
    func updateUIView(_ view: BaiduMapHostView, context: Context) {
        // Match Apple MapKit: passenger periods are green, empty driving blue.
        // Never bridge gaps >8s, reversed timestamps or implausible GPS jumps.
        var segments: [[String: Any]] = []
        var current: [[NSNumber]] = []
        var currentPassenger = false
        var previous: TrackPoint?
        func flush() {
            if current.count >= 2 {
                segments.append(["points": current, "passenger": currentPassenger])
            }
            current.removeAll()
        }
        for point in shift.points {
            guard (-90...90).contains(point.lat), (-180...180).contains(point.lon) else { continue }
            let passenger = shift.rides.contains {
                point.date >= $0.started && point.date <= ($0.ended ?? Date())
            }
            var discontinuity = point.segmentStart
            if let old = previous {
                let seconds = point.date.timeIntervalSince(old.date)
                let meters = CLLocation(latitude: old.lat, longitude: old.lon)
                    .distance(from: CLLocation(latitude: point.lat, longitude: point.lon))
                discontinuity = discontinuity || seconds <= 0 || seconds > 8 || meters / seconds >= 50
            }
            if discontinuity {
                flush()
                currentPassenger = passenger
            } else if passenger != currentPassenger {
                let boundary = current.last
                flush()
                currentPassenger = passenger
                if let boundary = boundary { current.append(boundary) }
            }
            current.append([NSNumber(value: point.lat), NSNumber(value: point.lon)])
            previous = point
        }
        flush()
        let playback: [NSNumber]? = playbackCoordinate.map {
            [NSNumber(value: $0.latitude), NSNumber(value: $0.longitude)]
        }
        view.renderSegments(segments, playback: playback)
        let live: [NSNumber]? = liveCoordinate.map { [NSNumber(value: $0.latitude), NSNumber(value: $0.longitude)] }
        view.setLivePosition(live, follow: followVehicle)
    }
}
