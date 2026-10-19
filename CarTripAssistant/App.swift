import SwiftUI
import CoreLocation
import CoreMotion

struct Ride: Codable, Identifiable {
    var id = UUID()
    var started: Date
    var ended: Date?
    var kilometers: Double = 0
}
struct BreakPeriod: Codable, Identifiable {
    var id = UUID()
    var started: Date
    var ended: Date?
}
struct Shift: Codable, Identifiable {
    var id = UUID()
    var started: Date
    var ended: Date?
    var kilometers: Double = 0
    var rides: [Ride] = []
    var breaks: [BreakPeriod] = []
    var revenue: String = ""
    var notes: String = ""
    var points: [TrackPoint] = []
    var passengerKM: Double { rides.reduce(0) { $0 + $1.kilometers } }
    var completedOrders: Int { rides.filter { $0.ended != nil }.count }
    var restSeconds: TimeInterval { breaks.reduce(0) { $0 + ($1.ended ?? Date()).timeIntervalSince($1.started) } }
}
struct TrackPoint: Codable {
    var lat: Double
    var lon: Double
    var date: Date
    var accuracy: Double
    var speed: Double
}
@MainActor final class TripStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var active: Shift?
    @Published var history: [Shift] = []
    @Published var gpsStatus = "等待定位"
    @Published var motionStatus = "未知"
    private let location = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private var previous: CLLocation?
    private var walking = false
    private struct Saved: Codable { var active: Shift?; var history: [Shift] }
    private var file: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("trips.json") }
    override init() {
        super.init()
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            active = saved.active
            history = saved.history
        }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = 5
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true
        if active != nil { resumeTracking() }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(Saved(active: active, history: history)) {
            try? data.write(to: file, options: .atomic)
        }
    }
    private func resumeTracking() {
        location.requestAlwaysAuthorization()
        location.startUpdatingLocation()
        if CMMotionActivityManager.isActivityAvailable() {
            motion.startActivityUpdates(to: .main) { [weak self] activity in
                Task { @MainActor in
                    guard let self, let activity else { return }
                    self.walking = activity.walking || activity.running
                    self.motionStatus = activity.automotive ? "驾车" : (self.walking ? "步行" : "未确认")
                }
            }
        }
    }
    func startShift() {
        guard active == nil else { return }
        active = Shift(started: Date())
        previous = nil
        save()
        resumeTracking()
    }
    func startRide() {
        guard var shift = active, shift.rides.last?.ended != nil || shift.rides.isEmpty, shift.breaks.last?.ended != nil || shift.breaks.isEmpty else { return }
        shift.rides.append(Ride(started: Date()))
        active = shift
        save()
    }
    func endRide() {
        guard var shift = active, let i = shift.rides.indices.last, shift.rides[i].ended == nil else { return }
        shift.rides[i].ended = Date()
        active = shift
        save()
    }
    func startBreak() {
        guard var shift = active, shift.rides.last?.ended != nil || shift.rides.isEmpty, shift.breaks.last?.ended != nil || shift.breaks.isEmpty else { return }
        shift.breaks.append(BreakPeriod(started: Date()))
        active = shift
        save()
    }
    func endBreak() {
        guard var shift = active, let i = shift.breaks.indices.last, shift.breaks[i].ended == nil else { return }
        shift.breaks[i].ended = Date()
        active = shift
        save()
    }
    func finish(revenue: String, notes: String) {
        guard var shift = active else { return }
        let now = Date()
        if let i = shift.rides.indices.last, shift.rides[i].ended == nil { shift.rides[i].ended = now }
        if let i = shift.breaks.indices.last, shift.breaks[i].ended == nil { shift.breaks[i].ended = now }
        shift.ended = now
        shift.revenue = revenue
        shift.notes = notes
        history.insert(shift, at: 0)
        active = nil
        previous = nil
        location.stopUpdatingLocation()
        motion.stopActivityUpdates()
        save()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            if active != nil { manager.startUpdatingLocation() }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { gpsStatus = "定位异常：" + error.localizedDescription }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard var shift = active else { return }
        for point in locations {
            guard point.horizontalAccuracy > 0, point.horizontalAccuracy <= 35, abs(point.timestamp.timeIntervalSinceNow) < 30 else { continue }
            if let last = previous {
                let seconds = point.timestamp.timeIntervalSince(last.timestamp)
                guard seconds > 0 else { continue }
                let meters = point.distance(from: last)
                let speed = meters / seconds
                if meters > 4 && speed < 50 && !walking {
                    shift.kilometers += meters / 1000
                    if let i = shift.rides.indices.last, shift.rides[i].ended == nil { shift.rides[i].kilometers += meters / 1000 }
                }
            }
            previous = point
            shift.points.append(TrackPoint(lat: point.coordinate.latitude, lon: point.coordinate.longitude, date: point.timestamp, accuracy: point.horizontalAccuracy, speed: point.speed))
            if shift.points.count > 20000 { shift.points.removeFirst(1000) }
        }
        active = shift
        gpsStatus = "GPS 记录中"
        save()
    }
    func report(_ shift: Shift) -> String {
        let duration = (shift.ended ?? Date()).timeIntervalSince(shift.started)
        return """
        车载行程助手 · 每日总结
        出车时间：\(shift.started.formatted())
        结束时间：\((shift.ended ?? Date()).formatted())
        出车时长：\(Int(duration / 60)) 分钟
        休息时长：\(Int(shift.restSeconds / 60)) 分钟
        工作时长：\(Int(max(0, duration - shift.restSeconds) / 60)) 分钟
        全天总里程：\(String(format: "%.2f", shift.kilometers)) 公里
        载客里程：\(String(format: "%.2f", shift.passengerKM)) 公里
        非载客里程：\(String(format: "%.2f", max(0, shift.kilometers - shift.passengerKM))) 公里
        完成订单：\(shift.completedOrders) 单
        今日流水：\(shift.revenue)
        备注：\(shift.notes)
        """
    }
}
@main struct CarTripAssistantApp: App {
    @StateObject private var store = TripStore()
    var body: some Scene { WindowGroup { Dashboard().environmentObject(store) } }
}
struct Dashboard: View {
    @EnvironmentObject private var store: TripStore
    @State private var revenue = ""
    @State private var notes = ""
    @State private var showFinish = false
    private var riding: Bool { store.active?.rides.last.map { $0.ended == nil } ?? false }
    private var resting: Bool { store.active?.breaks.last.map { $0.ended == nil } ?? false }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let shift = store.active {
                        VStack(spacing: 8) {
                            Text("全天行驶里程").font(.subheadline).foregroundStyle(.secondary)
                            Text(String(format: "%.2f km", shift.kilometers)).font(.system(size: 42, weight: .bold, design: .rounded))
                            Text(store.gpsStatus + " · " + store.motionStatus).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding().background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                        HStack {
                            stat("完成订单", "\(shift.completedOrders) 单")
                            stat("载客里程", String(format: "%.2f km", shift.passengerKM))
                        }
                        HStack {
                            stat("非载客里程", String(format: "%.2f km", max(0, shift.kilometers - shift.passengerKM)))
                            stat("休息时长", "\(Int(shift.restSeconds / 60)) 分钟")
                        }
                        if riding {
                            Button("乘客下车") { store.endRide() }.buttonStyle(.borderedProminent).tint(.orange)
                        } else if resting {
                            Button("继续接单") { store.endBreak() }.buttonStyle(.borderedProminent)
                        } else {
                            Button("接到订单") { store.startRide() }.buttonStyle(.borderedProminent)
                            Button("暂停休息") { store.startBreak() }.buttonStyle(.bordered)
                            Button("结束出车") { showFinish = true }.buttonStyle(.bordered).tint(.red)
                        }
                    } else {
                        Image(systemName: "car.fill").font(.system(size: 56)).foregroundStyle(.blue)
                        Text("准备开始今天的出车").font(.title3.bold())
                        Button("开始出车") { store.startShift() }.buttonStyle(.borderedProminent)
                    }
                    Text("定位统计仅供参考。停车或步行时可能存在误差，请以车辆仪表为准。").font(.caption).foregroundStyle(.secondary)
                    if !store.history.isEmpty {
                        Text("历史日报").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(store.history) { item in
                            ShareLink(item: store.report(item)) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.started.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                                        Text("\(item.completedOrders) 单 · " + String(format: "%.2f km", item.kilometers)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up")
                                }.padding().background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }.padding()
            }
            .navigationTitle("车载行程助手")
            .alert("结束出车", isPresented: $showFinish) {
                TextField("今日流水", text: $revenue).keyboardType(.decimalPad)
                TextField("备注", text: $notes)
                Button("确认结束") { store.finish(revenue: revenue, notes: notes); revenue = ""; notes = "" }
                Button("取消", role: .cancel) {}
            } message: { Text("确认结束全天记录，并保存今日流水。") }
        }
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
