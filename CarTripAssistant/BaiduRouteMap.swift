import SwiftUI
import CoreLocation

// Optional display-only map. All mileage, GPS capture and saved track
// coordinates continue to use the original Core Location data.
struct BaiduRouteMap: UIViewRepresentable {
    let shift: Shift
    let playbackCoordinate: CLLocationCoordinate2D?
    static var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "BaiduMapAK") as? String else { return false }
        return !key.isEmpty
    }
    func makeUIView(context: Context) -> BaiduMapHostView {
        BaiduMapHostView(frame: .zero)
    }
    func updateUIView(_ view: BaiduMapHostView, context: Context) {
        let coordinates: [[NSNumber]] = shift.points.map {
            [NSNumber(value: $0.lat), NSNumber(value: $0.lon)]
        }
        let playback: [NSNumber]? = playbackCoordinate.map {
            [NSNumber(value: $0.latitude), NSNumber(value: $0.longitude)]
        }
        view.renderCoordinates(coordinates, playback: playback)
    }
}
