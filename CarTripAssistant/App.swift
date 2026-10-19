import SwiftUI
import CoreLocation
import CoreMotion
import MapKit
import SQLite3
import UniformTypeIdentifiers

struct Ride: Codable, Identifiable {
    var id = UUID()
    var started: Date
    var ended: Date?
    var kilometers: Double = 0
}
enum RestKind: String, Codable { case meal, charging, other }
struct BreakPeriod: Codable, Identifiable {
    var id = UUID()
    var started: Date
    var ended: Date?
    var kind: RestKind = .other
    init(started: Date, ended: Date? = nil, kind: RestKind = .other) {
        self.started = started
        self.ended = ended
        self.kind = kind
    }
    private enum CodingKeys: String, CodingKey { case id, started, ended, kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        started = try c.decode(Date.self, forKey: .started)
        ended = try c.decodeIfPresent(Date.self, forKey: .ended)
        kind = try c.decodeIfPresent(RestKind.self, forKey: .kind) ?? .other
    }
}
struct Shift: Codable, Identifiable {
    var id = UUID()
    var started: Date
    var ended: Date?
    var kilometers: Double = 0
    var emptyKilometers: Double = 0
    var restKilometers: Double = 0
    var rides: [Ride] = []
    var breaks: [BreakPeriod] = []
    var waitingPeriods: [BreakPeriod] = []
    var lastEmptyMovementAt: Date?
    var revenue: String = ""
    var notes: String = ""
    var points: [TrackPoint] = []
    init(started: Date) { self.started = started }
    private enum CodingKeys: String, CodingKey {
        case id, started, ended, kilometers, emptyKilometers, restKilometers
        case rides, breaks, waitingPeriods, lastEmptyMovementAt, revenue, notes, points
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        started = try c.decode(Date.self, forKey: .started)
        ended = try c.decodeIfPresent(Date.self, forKey: .ended)
        kilometers = try c.decodeIfPresent(Double.self, forKey: .kilometers) ?? 0
        rides = try c.decodeIfPresent([Ride].self, forKey: .rides) ?? []
        breaks = try c.decodeIfPresent([BreakPeriod].self, forKey: .breaks) ?? []
        points = try c.decodeIfPresent([TrackPoint].self, forKey: .points) ?? []
        // Old archives had no separate distance categories; keep the historical total.
        emptyKilometers = try c.decodeIfPresent(Double.self, forKey: .emptyKilometers)
            ?? max(0, kilometers - rides.reduce(0) { $0 + $1.kilometers })
        restKilometers = try c.decodeIfPresent(Double.self, forKey: .restKilometers) ?? 0
        waitingPeriods = try c.decodeIfPresent([BreakPeriod].self, forKey: .waitingPeriods) ?? []
        lastEmptyMovementAt = try c.decodeIfPresent(Date.self, forKey: .lastEmptyMovementAt)
        revenue = try c.decodeIfPresent(String.self, forKey: .revenue) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
    var passengerKM: Double { rides.reduce(0) { $0 + $1.kilometers } }
    var completedOrders: Int { rides.filter { $0.ended != nil }.count }
    func waitingSeconds(at now: Date) -> TimeInterval {
        // Clamp every interval to the shift boundaries, including archived shifts.
        let limit = min(now, ended ?? now)
        return waitingPeriods.reduce(0) { total, period in
            let stop = min(period.ended ?? limit, limit)
            return total + max(0, stop.timeIntervalSince(max(period.started, started)))
        }
    }
    func breakSeconds(kind: RestKind? = nil, at date: Date) -> TimeInterval {
        let limit = min(date, ended ?? date)
        return breaks.filter { kind == nil || $0.kind == kind }.reduce(0) { total, period in
            let stop = min(period.ended ?? limit, limit)
            return total + max(0, stop.timeIntervalSince(max(period.started, started)))
        }
    }
    // Assign each instant to exactly one category. Priority resolves legacy
    // overlapping intervals without double-counting the full shift.
    func timeTotals(at date: Date) -> (passenger: TimeInterval, waiting: TimeInterval, manualRest: TimeInterval, empty: TimeInterval, meal: TimeInterval, charging: TimeInterval, other: TimeInterval) {
        let limit = min(date, ended ?? date)
        guard limit > started else { return (0, 0, 0, 0, 0, 0, 0) }
        struct Event { let time: Date; let kind: Int; let delta: Int }
        var events: [Event] = []
        func append(_ from: Date, _ to: Date?, kind: Int) {
            let a = max(from, started)
            let b = min(to ?? limit, limit)
            guard b > a else { return }
            events.append(Event(time: a, kind: kind, delta: 1))
            events.append(Event(time: b, kind: kind, delta: -1))
        }
        for ride in rides { append(ride.started, ride.ended, kind: 0) }
        for period in breaks {
            let kind = period.kind == .meal ? 1 : (period.kind == .charging ? 2 : 3)
            append(period.started, period.ended, kind: kind)
        }
        for period in waitingPeriods { append(period.started, period.ended, kind: 4) }
        events.sort { $0.time < $1.time }
        var counts = [0, 0, 0, 0, 0]
        var cursor = started
        // Passenger, meal, charging, other, waiting, empty.
        var totals = [Double](repeating: 0, count: 6)
        var index = 0
        func category() -> Int {
            for kind in 0..<5 where counts[kind] > 0 { return kind }
            return 5
        }
        while index < events.count {
            let time = events[index].time
            totals[category()] += max(0, time.timeIntervalSince(cursor))
            while index < events.count && events[index].time == time {
                counts[events[index].kind] += events[index].delta
                index += 1
            }
            cursor = time
        }
        totals[category()] += max(0, limit.timeIntervalSince(cursor))
        return (totals[0], totals[4], totals[1] + totals[2] + totals[3], totals[5], totals[1], totals[2], totals[3])
    }
    var restSeconds: TimeInterval { breakSeconds(at: Date()) }
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
    private var lastSavedLocation: CLLocation?
    private var lastSavedHeading: CLLocationDirection?
    private var lastDiskWrite = Date.distantPast
    private struct Saved: Codable { var active: Shift?; var history: [Shift] }
    private var file: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("trips.json") }
    private var backupFile: URL { file.deletingLastPathComponent().appendingPathComponent("trips-backup.json") }
    private var safeToWrite = true
    override init() {
        super.init()
        let primaryData = try? Data(contentsOf: file)
        let backupData = try? Data(contentsOf: backupFile)
        let saved = primaryData.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
            ?? backupData.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let saved {
            active = saved.active
            history = saved.history
        } else if primaryData != nil || backupData != nil {
            // Never overwrite an unreadable trip archive with an empty one.
            safeToWrite = false
            gpsStatus = "历史记录读取失败，请先备份数据"
        }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 5
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true
        if active != nil {
            if let p = active?.points.last {
                lastSavedLocation = CLLocation(latitude: p.lat, longitude: p.lon)
            }
            resumeTracking()
        }
    }
    func flushToDisk() { save() }
    private func save() {
        guard safeToWrite else { return }
        guard let data = try? JSONEncoder().encode(Saved(active: active, history: history)) else { return }
        // Preserve the previous valid snapshot before replacing the main archive.
        if let old = try? Data(contentsOf: file),
           (try? JSONDecoder().decode(Saved.self, from: old)) != nil {
            try? old.write(to: backupFile, options: .atomic)
        }
        do {
            try data.write(to: file, options: .atomic)
            lastDiskWrite = Date()
        } catch {
            gpsStatus = "保存失败：请检查存储空间"
        }
    }
    private func resumeTracking() {
        location.requestAlwaysAuthorization()
        location.startUpdatingLocation()
        gpsStatus = "等待有效 GPS"
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
        var newShift = Shift(started: Date())
        newShift.waitingPeriods.append(BreakPeriod(started: newShift.started))
        active = newShift
        previous = nil
        lastSavedLocation = nil
        lastSavedHeading = nil
        save()
        resumeTracking()
    }
    func startRide() {
        guard var shift = active, shift.rides.last?.ended != nil || shift.rides.isEmpty, shift.breaks.last?.ended != nil || shift.breaks.isEmpty else { return }
        recordBoundaryPoint(&shift)
        if let i = shift.waitingPeriods.indices.last, shift.waitingPeriods[i].ended == nil { shift.waitingPeriods[i].ended = Date() }
        shift.lastEmptyMovementAt = nil
        shift.rides.append(Ride(started: Date()))
        previous = nil // Do not attribute a GPS segment crossing this state boundary to either category.
        active = shift
        save()
    }
    func endRide() {
        guard var shift = active, let i = shift.rides.indices.last, shift.rides[i].ended == nil else { return }
        recordBoundaryPoint(&shift)
        shift.rides[i].ended = Date()
        let now = Date()
        shift.waitingPeriods.append(BreakPeriod(started: now))
        shift.lastEmptyMovementAt = nil
        previous = nil // Do not attribute a GPS segment crossing this state boundary to either category.
        active = shift
        save()
    }
    func startBreak(kind: RestKind = .other) {
        guard var shift = active, shift.rides.last?.ended != nil || shift.rides.isEmpty, shift.breaks.last?.ended != nil || shift.breaks.isEmpty else { return }
        recordBoundaryPoint(&shift)
        if let i = shift.waitingPeriods.indices.last, shift.waitingPeriods[i].ended == nil { shift.waitingPeriods[i].ended = Date() }
        shift.lastEmptyMovementAt = nil
        shift.breaks.append(BreakPeriod(started: Date(), kind: kind))
        previous = nil // Do not attribute a GPS segment crossing this state boundary to either category.
        active = shift
        save()
    }
    func endBreak() {
        guard var shift = active, let i = shift.breaks.indices.last, shift.breaks[i].ended == nil else { return }
        recordBoundaryPoint(&shift)
        shift.breaks[i].ended = Date()
        shift.waitingPeriods.append(BreakPeriod(started: Date()))
        shift.lastEmptyMovementAt = nil
        previous = nil // Do not attribute a GPS segment crossing this state boundary to either category.
        active = shift
        save()
    }
    func finish(revenue: String, notes: String) {
        guard var shift = active else { return }
        let now = Date()
        if let i = shift.rides.indices.last, shift.rides[i].ended == nil { shift.rides[i].ended = now }
        if let i = shift.breaks.indices.last, shift.breaks[i].ended == nil { shift.breaks[i].ended = now }
        if let i = shift.waitingPeriods.indices.last, shift.waitingPeriods[i].ended == nil { shift.waitingPeriods[i].ended = now }
        recordBoundaryPoint(&shift)
        previous = nil
        shift.ended = now
        shift.revenue = revenue
        shift.notes = notes
        history.insert(shift, at: 0)
        active = nil
        previous = nil
        location.stopUpdatingLocation()
        motion.stopActivityUpdates()
        walking = false
        motionStatus = "未知"
        gpsStatus = "未出车"
        save()
    }
    private func recordBoundaryPoint(_ shift: inout Shift) {
        guard let point = location.location,
              point.horizontalAccuracy > 0, point.horizontalAccuracy <= 35,
              abs(point.timestamp.timeIntervalSinceNow) < 15 else { return }
        if let last = shift.points.last, abs(last.date.timeIntervalSince(point.timestamp)) < 1 { return }
        shift.points.append(TrackPoint(lat: point.coordinate.latitude, lon: point.coordinate.longitude,
                                      date: point.timestamp, accuracy: point.horizontalAccuracy, speed: point.speed))
        lastSavedLocation = point
        // A valid boundary sample is a new segment origin; do not bridge categories.
        previous = point
    }
    private func shouldSaveTrackPoint(_ point: CLLocation) -> Bool {
        guard let last = lastSavedLocation else { return true }
        let meters = point.distance(from: last)
        let elapsed = point.timestamp.timeIntervalSince(last.timestamp)
        if elapsed >= 90 { return true }
        if meters >= 100 { return true }
        // 转弯时增加轨迹密度，避免道路拐角被连成直线。
        if meters >= 20, point.course >= 0, let old = lastSavedHeading {
            let diff = abs(point.course - old)
            if min(diff, 360 - diff) >= 30 { return true }
        }
        return false
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
                // Manual rest can include walking away from the parked car. Never add
                // that movement to vehicle mileage, even if motion detection lags.
                let manualBreakActive = shift.breaks.last.map { $0.ended == nil } ?? false
                // A long GPS outage does not prove the route between samples.
                // Skip the gap instead of inventing straight-line vehicle mileage.
                if seconds <= 120 && meters > 4 && speed < 50 && !walking && !manualBreakActive {
                    let km = meters / 1000
                    shift.kilometers += km
                    if let i = shift.rides.indices.last, shift.rides[i].ended == nil {
                        shift.rides[i].kilometers += km
                    } else {
                        shift.emptyKilometers += km
                        if meters >= 8 && speed >= 1.5 {
                            if let i = shift.waitingPeriods.indices.last, shift.waitingPeriods[i].ended == nil {
                                // The movement happened between two GPS samples. End waiting
                                // at the previous sample rather than counting the driving interval.
                                let boundary = max(shift.waitingPeriods[i].started, last.timestamp)
                                shift.waitingPeriods[i].ended = min(boundary, point.timestamp)
                            }
                            shift.lastEmptyMovementAt = point.timestamp
                        }
                    }
                }
            }
            // Recognize an idle stop only outside a ride and outside a manual break.
            // Require at least 60 seconds of stationary GPS observations; do not classify
            // an isolated slow callback as a stop.
            let rideActive = shift.rides.last.map { $0.ended == nil } ?? false
            let breakActive = shift.breaks.last.map { $0.ended == nil } ?? false
            let waitingActive = shift.waitingPeriods.last.map { $0.ended == nil } ?? false
            if !rideActive && !breakActive && !waitingActive,
               let lastMove = shift.lastEmptyMovementAt,
               point.timestamp.timeIntervalSince(lastMove) >= 60,
               point.speed >= 0 && point.speed < 0.8 {
                shift.waitingPeriods.append(BreakPeriod(started: lastMove.addingTimeInterval(60)))
                shift.lastEmptyMovementAt = nil
            }
            previous = point
            if shouldSaveTrackPoint(point) {
                shift.points.append(TrackPoint(lat: point.coordinate.latitude, lon: point.coordinate.longitude,
                                              date: point.timestamp, accuracy: point.horizontalAccuracy, speed: point.speed))
                lastSavedLocation = point
                if point.course >= 0 { lastSavedHeading = point.course }
            }
        }
        active = shift
        gpsStatus = "GPS 记录中"
        if Date().timeIntervalSince(lastDiskWrite) >= 15 { save() }
    }
    func exportGPX(_ shift: Shift) -> URL? {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
        }
        let stamp = ISO8601DateFormatter()
        let name = "CarTrip-\(shift.started.formatted(.dateTime.year().month().day()))"
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\\n<gpx version=\"1.1\" creator=\"CarTripAssistant\" xmlns=\"http://www.topografix.com/GPX/1/1\">\\n<trk><name>\(escape(name))</name><trkseg>\\n"
        for p in shift.points where (-90...90).contains(p.lat) && (-180...180).contains(p.lon) {
            xml += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><time>\(stamp.string(from: p.date))</time></trkpt>\\n"
        }
        xml += "</trkseg></trk></gpx>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(shift.id.uuidString).gpx")
        do { try xml.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }
    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        save()
    }
    func discardShift() {
        active = nil
        previous = nil
        location.stopUpdatingLocation()
        motion.stopActivityUpdates()
        save()
    }
    func report(_ shift: Shift) -> String {
        let duration = (shift.ended ?? Date()).timeIntervalSince(shift.started)
        return """
        车载行程助手 · 每日总结
        出车时间：\(shift.started.formatted())
        结束时间：\((shift.ended ?? Date()).formatted())
        出车时长：\(Int(duration / 60)) 分钟
        总休息时长（含等客）：\(Int((shift.restSeconds + shift.waitingSeconds(at: shift.ended ?? Date())) / 60)) 分钟
        等客时长：\(Int(shift.waitingSeconds(at: shift.ended ?? Date()) / 60)) 分钟
        工作时长：\(Int(max(0, duration - shift.restSeconds) / 60)) 分钟
        全天总里程：\(String(format: "%.2f", shift.kilometers)) 公里
        载客里程：\(String(format: "%.2f", shift.passengerKM)) 公里
        空驶里程：\(String(format: "%.2f", shift.emptyKilometers)) 公里
        休息期间移动：\(String(format: "%.2f", shift.restKilometers)) 公里
        完成订单：\(shift.completedOrders) 单
        今日流水：\(shift.revenue)
        备注：\(shift.notes)
        """
    }
}
@main struct CarTripAssistantApp: App {
    @StateObject private var store = TripStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Dashboard().environmentObject(store)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .inactive || phase == .background {
                store.flushToDisk()
            }
        }
    }
}

private enum Cockpit {
    static let background = Color(red: 0.045, green: 0.071, blue: 0.12)
    static let panel = Color(red: 0.085, green: 0.13, blue: 0.21)
    static let secondary = Color(red: 0.12, green: 0.18, blue: 0.28)
    static let blue = Color(red: 0.19, green: 0.48, blue: 1)
    static let muted = Color(red: 0.61, green: 0.70, blue: 0.83)
    static let green = Color(red: 0.26, green: 0.88, blue: 0.65)
}
struct Dashboard: View {
    @EnvironmentObject private var store: TripStore
    @State private var revenue = ""
    @State private var notes = ""
    @State private var showFinish = false
    @State private var showDiscard = false
    @State private var deletionTarget: UUID?
    @State private var gpxExport: URL?
    private var riding: Bool { store.active?.rides.last.map { $0.ended == nil } ?? false }
    private var resting: Bool { store.active?.breaks.last.map { $0.ended == nil } ?? false }
    private var activeRideStart: Date? { guard let ride = store.active?.rides.last, ride.ended == nil else { return nil }; return ride.started }
    var body: some View {
        NavigationStack {
        ZStack {
            Cockpit.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .background(Cockpit.background)
                ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let shift = store.active {
                        mileageCard(shift)
                        liveDurationCard(shift)
                        routeEntry(shift)
                        metrics(shift)
                        controls
                    } else {
                        welcome
                    }
                    historySection
                    Text("GPS 里程为估算值，步行、隧道及信号漂移可能影响准确性。")
                        .font(.caption).foregroundStyle(Cockpit.muted)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 48)
                }
            }
        }
        }
        .preferredColorScheme(.dark)
        .sheet(item: Binding(
            get: { gpxExport.map { ExportItem(url: $0) } },
            set: { if $0 == nil { gpxExport = nil } }
        )) { item in
            ShareSheet(items: [item.url])
        }
        .alert("结束今天的出车", isPresented: $showFinish) {
            TextField("今日流水（元）", text: $revenue).keyboardType(.decimalPad)
            TextField("备注（可选）", text: $notes)
            Button("确认结束") {
                store.finish(revenue: revenue, notes: notes)
                revenue = ""; notes = ""
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将保存今天的订单、休息时间和里程。")
        }
        .confirmationDialog("放弃本次出车？", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("放弃本次出车（不可恢复）", role: .destructive) { store.discardShift() }
        } message: {
            Text("仅清除正在记录的本次出车，不影响历史日报。")
        }
        .alert("删除这一天的记录？", isPresented: Binding(
            get: { deletionTarget != nil },
            set: { if !$0 { deletionTarget = nil } }
        )) {
            Button("永久删除", role: .destructive) {
                if let id = deletionTarget { store.deleteHistory(id) }
                deletionTarget = nil
            }
            Button("取消", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("删除后将无法恢复，其他日期的数据不会受影响。")
        }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CAR TRIP  /  WORKSPACE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.1).foregroundStyle(Cockpit.muted)
                Text("车载行程助手")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(store.active == nil ? Cockpit.muted : Cockpit.green)
                    .frame(width: 7, height: 7)
                Text(store.active == nil ? "待出车" : (riding ? "载客中" : (resting ? "休息中" : "运营中")))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(store.active == nil ? Cockpit.muted : Cockpit.green)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Cockpit.panel, in: Capsule())
        }
    }
    private func routeEntry(_ shift: Shift) -> some View {
        NavigationLink {
            RouteDetail(shift: shift)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "map.fill").foregroundStyle(Cockpit.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("今日行驶轨迹").font(.system(size: 15, weight: .semibold))
                    Text("\(shift.points.count) 个 GPS 记录点 · 地图查看").font(.caption).foregroundStyle(Cockpit.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Cockpit.muted)
            }
            .foregroundStyle(.white)
            .padding(17)
            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 17))
        }
    }
    private func mileageCard(_ shift: Shift) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("全天累计里程", systemImage: "car.side.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Cockpit.muted)
                Spacer()
                Image(systemName: "location.north.line.fill")
                    .foregroundStyle(Cockpit.blue)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(String(format: "%.2f", shift.kilometers))
                    .font(.system(size: 55, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("km").font(.system(size: 19, weight: .medium)).foregroundStyle(Cockpit.muted)
            }
            Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Cockpit.green)
                Text(store.gpsStatus).foregroundStyle(.white)
                Spacer()
                Text(store.motionStatus).foregroundStyle(Cockpit.muted)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(22)
        .background(
            LinearGradient(colors: [Cockpit.secondary, Cockpit.panel, Cockpit.background],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 25)
        )
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(Cockpit.blue.opacity(0.3), lineWidth: 1))
    }
    private func liveDurationCard(_ shift: Shift) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let shiftSeconds = max(0, Int(timeline.date.timeIntervalSince(shift.started)))
            let rideSeconds = activeRideStart.map { max(0, Int(timeline.date.timeIntervalSince($0))) }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("本次出车时长", systemImage: "clock")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cockpit.muted)
                    Text(clockString(shiftSeconds))
                        .font(.system(size: 27, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                if let rideSeconds {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("当前载客计时")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Cockpit.green)
                        Text(clockString(rideSeconds))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(Cockpit.green)
                            .monospacedDigit()
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(resting ? "当前休息计时" : "当前等客计时")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Cockpit.green)
                        let start = resting
                            ? shift.breaks.last?.started
                            : (shift.waitingPeriods.last?.ended == nil ? shift.waitingPeriods.last?.started : nil)
                        Text(start.map { clockString(max(0, Int(timeline.date.timeIntervalSince($0)))) } ?? "00:00:00")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(Cockpit.green)
                            .monospacedDigit()
                    }
                }
            }
            .padding(17)
            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 17))
        }
    }
    private func clockString(_ seconds: Int) -> String {
        let hours = seconds / 3600
        return String(format: "%02d:%02d:%02d", hours, (seconds / 60) % 60, seconds % 60)
    }
    private func metrics(_ shift: Shift) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = min(timeline.date, shift.ended ?? timeline.date)
            let totals = shift.timeTotals(at: now)
            let passengerSeconds = totals.passenger
            let waitingSeconds = totals.waiting
            let restSeconds = totals.manualRest + totals.waiting
            let emptySeconds = totals.empty
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                metric("完成订单", "\(shift.completedOrders)", "单", "checkmark.circle.fill", Cockpit.green)
                metric("载客里程", String(format: "%.2f", shift.passengerKM), "km", "person.fill", Cockpit.blue)
                metric("空驶里程", String(format: "%.2f", shift.emptyKilometers), "km", "point.topleft.down.curvedto.point.bottomright.up", .orange)
                metric("总行驶里程", String(format: "%.2f", shift.kilometers), "km", "car.fill", .cyan)
                metric("载客总时长", clockString(Int(passengerSeconds)), "", "person.crop.circle", Cockpit.blue)
                metric("空驶总时长", clockString(Int(emptySeconds)), "", "car.side", .orange)
                metric("等客总时长", clockString(Int(waitingSeconds)), "", "clock.arrow.circlepath", Cockpit.green)
                metric("休息总时长", clockString(Int(restSeconds)), "", "cup.and.saucer.fill", .cyan)
                metric("吃饭休息", clockString(Int(totals.meal)), "", "fork.knife", .orange)
                metric("充电休息", clockString(Int(totals.charging)), "", "bolt.car.fill", Cockpit.green)
                metric("其他休息", clockString(Int(totals.other)), "", "cup.and.saucer", .cyan)
            }
        }
    }
    private func metric(_ label: String, _ value: String, _ unit: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(label).foregroundStyle(Cockpit.muted)
            }
            .font(.system(size: 12, weight: .medium))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                Text(unit).font(.system(size: 12)).foregroundStyle(Cockpit.muted)
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 19))
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("接单工作台").font(.system(size: 17, weight: .bold))
                Spacer()
                Text(riding ? "本单记录中" : (resting ? "休息计时中" : "等待接单"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cockpit.muted)
            }
            if riding {
                action("乘客下车", symbol: "checkmark.flag.fill", color: .orange) { store.endRide() }
            } else if resting {
                action("恢复接单", symbol: "play.fill", color: Cockpit.green) { store.endBreak() }
            } else {
                action("乘客上车", symbol: "person.crop.circle.badge.checkmark", color: Cockpit.blue) { store.startRide() }
                HStack(spacing: 12) {
                    secondaryAction("吃饭休息", symbol: "fork.knife") { store.startBreak(kind: .meal) }
                    secondaryAction("充电等待", symbol: "bolt.car.fill") { store.startBreak(kind: .charging) }
                }
                HStack(spacing: 12) {
                    secondaryAction("其他休息", symbol: "cup.and.saucer.fill") { store.startBreak(kind: .other) }
                    secondaryAction("结束出车", symbol: "flag.checkered") { showFinish = true }
                }
            }
            Button(role: .destructive) { showDiscard = true } label: {
                Label("放弃本次测试记录", systemImage: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Cockpit.muted)
                    .frame(maxWidth: .infinity).padding(.top, 5)
            }
        }
        .padding(17)
        .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 23))
    }
    private func action(_ label: String, symbol: String, color: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(label, systemImage: symbol)
                .font(.system(size: 19, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 58)
        }
        .buttonStyle(.plain)
        .background(color, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
    }
    private func secondaryAction(_ label: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(label, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 48)
        }
        .buttonStyle(.plain)
        .background(Cockpit.secondary, in: RoundedRectangle(cornerRadius: 13))
        .foregroundStyle(.white)
    }
    private var welcome: some View {
        VStack(spacing: 19) {
            ZStack {
                Circle().fill(Cockpit.blue.opacity(0.13)).frame(width: 116, height: 116)
                Image(systemName: "car.side.fill")
                    .font(.system(size: 55))
                    .foregroundStyle(Cockpit.blue)
            }
            Text("准备开始今天的出车")
                .font(.system(size: 22, weight: .bold))
            Text("一键开启全天行程，自动累计里程、订单与休息时间")
                .font(.system(size: 13))
                .foregroundStyle(Cockpit.muted)
                .multilineTextAlignment(.center)
            action("开始出车", symbol: "play.fill", color: Cockpit.blue) { store.startShift() }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 24))
    }
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("历史日报").font(.system(size: 18, weight: .bold))
                Spacer()
                Text("\(store.history.count) 条记录")
                    .font(.caption).foregroundStyle(Cockpit.muted)
            }
            if store.history.isEmpty {
                Text("还没有历史记录，结束出车后会自动保存在这里。")
                    .font(.subheadline).foregroundStyle(Cockpit.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(store.history) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.started.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 16, weight: .bold))
                        Text("\(item.completedOrders) 单  ·  " + String(format: "%.2f km", item.kilometers))
                            .font(.system(size: 13)).foregroundStyle(Cockpit.muted)
                    }
                    Spacer(minLength: 5)
                    NavigationLink {
                        RouteDetail(shift: item)
                    } label: {
                        Image(systemName: "map")
                            .frame(width: 36, height: 42)
                    }
                    Button {
                        gpxExport = store.exportGPX(item)
                    } label: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .frame(width: 32, height: 42)
                    }
                    ShareLink(item: store.report(item)) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 36, height: 42)
                    }
                    Button(role: .destructive) { deletionTarget = item.id } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                            .frame(width: 36, height: 42)
                    }
                }
                .foregroundStyle(.white)
                .padding(15)
                .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}


private struct RouteLine {
    let points: [CLLocationCoordinate2D]
    let passenger: Bool
}
private final class RouteOverlay: MKPolyline {
    var isPassenger = false
}
private struct TripRouteMap: UIViewRepresentable {
    let shift: Shift
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.showsCompass = true
        map.isRotateEnabled = false
        let shenzhen = CLLocationCoordinate2D(latitude: 22.60, longitude: 114.05)
        map.setRegion(MKCoordinateRegion(center: shenzhen, span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.65)), animated: false)
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        // Passenger boundaries can change without a new GPS point; invalidate
        // the rendered route whenever pickup/dropoff timestamps change.
        let rideSignature = shift.rides.map {
            "\($0.id.uuidString):\($0.started.timeIntervalSince1970):\($0.ended?.timeIntervalSince1970 ?? -1)"
        }.joined(separator: "|")
        let latestPointTime = shift.points.last?.date.timeIntervalSince1970 ?? 0
        let coordinator = context.coordinator
        guard coordinator.lastCount != shift.points.count ||
              coordinator.shiftID != shift.id ||
              coordinator.lastRideSignature != rideSignature ||
              coordinator.lastPointTime != latestPointTime else { return }
        coordinator.lastCount = shift.points.count
        coordinator.shiftID = shift.id
        coordinator.lastRideSignature = rideSignature
        coordinator.lastPointTime = latestPointTime
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        let points = shift.points.filter {
            (-90...90).contains($0.lat) && (-180...180).contains($0.lon)
        }
        // An empty track should still display the bundled Shenzhen offline map.
        let entirelyWithinShenzhen = points.allSatisfy {
            (113.70...114.65).contains($0.lon) && (22.35...22.90).contains($0.lat)
        }
        if entirelyWithinShenzhen, let url = OfflineMap.file {
            let tiles = OfflineRasterTiles(url: url)
            tiles.canReplaceMapContent = true
            map.addOverlay(tiles, level: .aboveRoads)
        }
        guard !points.isEmpty else { return }
        // 分段绘制：载客为绿色，其余为蓝色；定位时间间隔过长则断开，不画跨城直线。
        var segment: [CLLocationCoordinate2D] = []
        var segmentPassenger = false
        var previousDate: Date?
        func flush() {
            guard segment.count >= 2 else { segment.removeAll(); return }
            let overlay = RouteOverlay(coordinates: segment, count: segment.count)
            overlay.isPassenger = segmentPassenger
            map.addOverlay(overlay)
            segment.removeAll()
        }
        for p in points {
            let passenger = shift.rides.contains { ride in
                p.date >= ride.started && p.date <= (ride.ended ?? Date())
            }
            if passenger != segmentPassenger || (previousDate.map { p.date.timeIntervalSince($0) > 120 } ?? false) {
                flush()
            }
            segmentPassenger = passenger
            segment.append(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
            previousDate = p.date
        }
        flush()
        let first = MKPointAnnotation()
        first.title = "起点"
        first.coordinate = CLLocationCoordinate2D(latitude: points[0].lat, longitude: points[0].lon)
        let last = MKPointAnnotation()
        last.title = "终点 / 最新位置"
        last.coordinate = CLLocationCoordinate2D(latitude: points[points.count-1].lat, longitude: points[points.count-1].lon)
        map.addAnnotations([first,last])
        map.showAnnotations([first,last], animated: false)
        if points.count > 2 {
            let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let poly = MKPolyline(coordinates: coords, count: coords.count)
            let rect = poly.boundingMapRect
            if !rect.isNull {
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 65, left: 40, bottom: 65, right: 40), animated: false)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastCount = -1
        var shiftID: UUID?
        var lastRideSignature = ""
        var lastPointTime: TimeInterval = -1
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = (overlay as? RouteOverlay)?.isPassenger == true ? .systemGreen : .systemBlue
            renderer.lineWidth = 5
            renderer.alpha = 0.9
            return renderer
        }
    }
}
private struct RouteDetail: View {
    let shift: Shift
    @State private var importMap = false
    @State private var mapRevision = 0
    @State private var mapError: String?
    var body: some View {
        VStack(spacing: 0) {
            TripRouteMap(shift: shift)
                .id(mapRevision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(OfflineMap.file == nil ? "在线地图" : "已内置深圳离线道路图 · © OpenStreetMap")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导入 MBTiles 地图") { importMap = true }
                    .font(.caption.bold())
            }.padding(.horizontal, 15).padding(.top, 10)
            HStack(spacing: 18) {
                Label("全天轨迹", systemImage: "line.diagonal").foregroundStyle(.blue)
                Label("载客区间", systemImage: "line.diagonal").foregroundStyle(.green)
                Spacer()
            }
            .font(.caption.bold())
            .padding(15)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "总里程 %.2f km  ·  载客 %.2f km", shift.kilometers, shift.passengerKM))
                    .font(.headline)
                Text("\(shift.completedOrders) 单 · \(shift.points.count) 个轨迹点")
                    .font(.caption).foregroundStyle(.secondary)
                Text("蓝线是记录的 GPS 轨迹，绿线按乘客上下车时间标记。定位断点、步行点和漂移可能影响地图及里程。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Cockpit.background)
        .fileImporter(isPresented: $importMap, allowedContentTypes: [UTType(filenameExtension: "mbtiles") ?? .data]) { outcome in
            switch outcome {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try OfflineMap.install(url)
                    mapRevision += 1
                } catch { mapError = error.localizedDescription }
            case .failure(let error): mapError = error.localizedDescription
            }
        }
        .alert("离线地图导入失败", isPresented: Binding(
            get: { mapError != nil }, set: { if !$0 { mapError = nil } }
        )) {
            Button("确定") { mapError = nil }
        } message: { Text(mapError ?? "") }
        .navigationTitle("行驶足迹")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}

private struct ExportItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private enum OfflineMap {
    static var file: URL? {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent("offline.mbtiles")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return Bundle.main.url(forResource: "OfflineMap", withExtension: "mbtiles")
    }
    static func install(_ source: URL) throws {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent("incoming.mbtiles")
        if fm.fileExists(atPath: temp.path) { try fm.removeItem(at: temp) }
        try fm.copyItem(at: source, to: temp)
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        var statement: OpaquePointer?
        let valid = opened && sqlite3_prepare_v2(db, "SELECT tile_data FROM tiles LIMIT 1", -1, &statement, nil) == SQLITE_OK
            && sqlite3_step(statement) == SQLITE_ROW
            && sqlite3_column_bytes(statement, 0) > 8
        sqlite3_finalize(statement)
        var raster = false
        var zoomOK = false
        if valid {
            var formatStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE name='format' LIMIT 1", -1, &formatStatement, nil) == SQLITE_OK,
               sqlite3_step(formatStatement) == SQLITE_ROW,
               let raw = sqlite3_column_text(formatStatement, 0) {
                let format = String(cString: raw).lowercased()
                raster = ["png", "jpg", "jpeg", "webp"].contains(format)
            }
            sqlite3_finalize(formatStatement)
            var zoomQuery: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles", -1, &zoomQuery, nil) == SQLITE_OK,
               sqlite3_step(zoomQuery) == SQLITE_ROW {
                let minZoom = sqlite3_column_int(zoomQuery, 0)
                let maxZoom = sqlite3_column_int(zoomQuery, 1)
                zoomOK = minZoom >= 0 && maxZoom <= 22 && minZoom <= maxZoom
            }
            sqlite3_finalize(zoomQuery)
        }
        sqlite3_close(db)
        guard valid && raster && zoomOK else {
            try? fm.removeItem(at: temp)
            throw NSError(domain: "OfflineMap", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要带有 format=png/jpg/jpeg/webp 元数据且包含实际瓦片的栅格 MBTiles；矢量 pbf 不支持"])
        }
        let target = folder.appendingPathComponent("offline.mbtiles")
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: target)
        }
    }
}
private final class OfflineRasterTiles: MKTileOverlay {
    private let fileURL: URL
    private let tileCache = NSCache<NSString, NSData>()
    init(url: URL) {
        fileURL = url
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        // Respect actual MBTiles zoom levels; older bundled maps stop at z15.
        var db: OpaquePointer?
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles", -1, &statement, nil) == SQLITE_OK,
               sqlite3_step(statement) == SQLITE_ROW {
                minimumZ = Int(sqlite3_column_int(statement, 0))
                maximumZ = Int(sqlite3_column_int(statement, 1))
            }
            sqlite3_finalize(statement)
        }
        sqlite3_close(db)
        tileCache.countLimit = 384
        tileCache.totalCostLimit = 24 * 1024 * 1024
    }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = "\(path.z)/\(path.x)/\(path.y)" as NSString
        if let cached = tileCache.object(forKey: key) {
            result(cached as Data, nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.fileURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                result(nil, NSError(domain: "OfflineMap", code: 2))
                return
            }
            defer { sqlite3_close(db) }
            var query: OpaquePointer?
            let sql = "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else {
                sqlite3_finalize(query)
                result(nil, NSError(domain: "OfflineMap", code: 3))
                return
            }
            defer { sqlite3_finalize(query) }
            sqlite3_bind_int(query, 1, Int32(path.z))
            sqlite3_bind_int(query, 2, Int32(path.x))
            sqlite3_bind_int(query, 3, Int32((1 << path.z) - 1 - path.y))
            if sqlite3_step(query) == SQLITE_ROW, let pointer = sqlite3_column_blob(query, 0) {
                let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(query, 0)))
                self.tileCache.setObject(data as NSData, forKey: key, cost: data.count)
                result(data, nil)
            } else {
                result(nil, NSError(domain: "OfflineMap", code: 4))
            }
        }
    }
}
