import SwiftUI
import CoreLocation

// Optional display-only map. All mileage, GPS capture and saved track
// coordinates continue to use the original Core Location data.
struct BaiduRouteMap: UIViewRepresentable {
    let shift: Shift
    let playbackCoordinate: CLLocationCoordinate2D?
    let followVehicle: Bool
    let replayActive: Bool
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
        // A full-day route may have 10,000+ fixes. Avoid scanning every ride
        // for every GPS point during SwiftUI redraw and replay.
        let rides = shift.rides.sorted { $0.started < $1.started }
        var rideCursor = 0
        var lastPointDate: Date?
        func flush() {
            if current.count >= 2 {
                segments.append(["points": current, "passenger": currentPassenger])
            }
            current.removeAll()
        }
        for point in shift.points {
            guard (-90...90).contains(point.lat), (-180...180).contains(point.lon) else { continue }
            // Imported/merged tracks can contain out-of-order timestamps.
            // Reset the cursor rather than silently misclassifying those points.
            if let last = lastPointDate, point.date < last { rideCursor = 0 }
            lastPointDate = point.date
            while rideCursor < rides.count,
                  let ended = rides[rideCursor].ended,
                  ended < point.date {
                rideCursor += 1
            }
            let passenger = rideCursor < rides.count &&
                point.date >= rides[rideCursor].started &&
                point.date <= (rides[rideCursor].ended ?? Date())
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
        // Extend the visible stroke to the interpolated playback position.
        // Do not draw across a GPS recording gap or a segment boundary.
        if replayActive, let cursor = playbackCoordinate,
           let last = shift.points.last,
           current.count > 0 {
            let lastLocation = CLLocation(latitude: last.lat, longitude: last.lon)
            let cursorLocation = CLLocation(latitude: cursor.latitude, longitude: cursor.longitude)
            let meters = lastLocation.distance(from: cursorLocation)
            // Playback interpolation is display-only. Never bridge a GPS gap,
            // and never connect a cursor to an unrelated prior segment.
            if meters > 0.3 && meters < 100,
               let lastPair = current.last,
               abs(lastPair[0].doubleValue - last.lat) < 0.000001,
               abs(lastPair[1].doubleValue - last.lon) < 0.000001 {
                current.append([NSNumber(value: cursor.latitude), NSNumber(value: cursor.longitude)])
            }
        }
        flush()
        let playback: [NSNumber]? = playbackCoordinate.map {
            [NSNumber(value: $0.latitude), NSNumber(value: $0.longitude)]
        }
        view.renderSegments(segments, playback: playback)
        let live: [NSNumber]? = liveCoordinate.map { [NSNumber(value: $0.latitude), NSNumber(value: $0.longitude)] }
        view.setLivePosition(replayActive ? nil : live, follow: followVehicle && !replayActive)
        if replayActive { view.followPlaybackPosition(playback) }
    }
}
