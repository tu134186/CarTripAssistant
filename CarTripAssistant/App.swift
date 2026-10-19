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
    private var riding: Bool { store.active?.rides.last.map { $0.ended == nil } ?? false }
    private var resting: Bool { store.active?.breaks.last.map { $0.ended == nil } ?? false }
    var body: some View {
        ZStack {
            Cockpit.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let shift = store.active {
                        mileageCard(shift)
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
                .padding(.top, 14)
                .padding(.bottom, 34)
            }
        }
        .preferredColorScheme(.dark)
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
        .confirmationDialog("放弃本次测试记录？", isPresented: $showDiscard, titleVisibility: .visible) {
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
    private func metrics(_ shift: Shift) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            metric("完成订单", "\(shift.completedOrders)", "单", "checkmark.circle.fill", Cockpit.green)
            metric("载客里程", String(format: "%.2f", shift.passengerKM), "km", "person.fill", Cockpit.blue)
            metric("非载客里程", String(format: "%.2f", max(0, shift.kilometers - shift.passengerKM)), "km", "point.topleft.down.curvedto.point.bottomright.up", .orange)
            metric("累计休息", "\(Int(shift.restSeconds / 60))", "分钟", "cup.and.saucer.fill", .cyan)
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
                action("继续接单", symbol: "play.fill", color: Cockpit.green) { store.endBreak() }
            } else {
                action("接到订单", symbol: "person.crop.circle.badge.checkmark", color: Cockpit.blue) { store.startRide() }
                HStack(spacing: 12) {
                    secondaryAction("暂停休息", symbol: "cup.and.saucer.fill") { store.startBreak() }
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
