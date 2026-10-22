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
    var segmentStart: Bool = false
    private enum CodingKeys: String, CodingKey { case lat, lon, date, accuracy, speed, segmentStart }
    init(lat: Double, lon: Double, date: Date, accuracy: Double, speed: Double, segmentStart: Bool = false) {
        self.lat = lat
        self.lon = lon
        self.date = date
        self.accuracy = accuracy
        self.speed = speed
        self.segmentStart = segmentStart
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        date = try c.decode(Date.self, forKey: .date)
        accuracy = try c.decode(Double.self, forKey: .accuracy)
        speed = try c.decode(Double.self, forKey: .speed)
        segmentStart = try c.decodeIfPresent(Bool.self, forKey: .segmentStart) ?? false
    }
}
@MainActor final class TripStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var active: Shift?
    @Published var history: [Shift] = []
    @Published var gpsStatus = "等待定位"
    @Published var motionStatus = "未知"
    @Published var gpsAccuracy: Double?
    @Published var gpsSpeed: Double?
    @Published var gpsLastUpdate: Date?
    @Published var gpsGapCount = 0
    @Published var rejectedGPSCount = 0
    @Published var gpsErrorCount = 0
    @Published var gpsPauseCount = 0
    @Published var gpsResumeCount = 0
    @Published var gpsAuthorization = "未知"
    @Published var parkingThresholdSeconds: Double = max(30, UserDefaults.standard.double(forKey: "parkingThresholdSeconds") == 0 ? 60 : UserDefaults.standard.double(forKey: "parkingThresholdSeconds")) {
        didSet { UserDefaults.standard.set(parkingThresholdSeconds, forKey: "parkingThresholdSeconds") }
    }
    private let location = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private var previous: CLLocation?
    private var walking = false
    private var lastSavedLocation: CLLocation?
    private var lastSavedHeading: CLLocationDirection?
    private var needsNewTrackSegment = true
    private var stationarySince: Date?
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
        needsNewTrackSegment = true
        stationarySince = nil
        save()
        resumeTracking()
    }
    func startRide() {
        guard var shift = active, shift.rides.last?.ended != nil || shift.rides.isEmpty, shift.breaks.last?.ended != nil || shift.breaks.isEmpty else { return }
        recordBoundaryPoint(&shift)
        let now = Date()
        if let i = shift.waitingPeriods.indices.last, shift.waitingPeriods[i].ended == nil { shift.waitingPeriods[i].ended = now }
        shift.lastEmptyMovementAt = nil
        stationarySince = nil
        shift.rides.append(Ride(started: now))
        needsNewTrackSegment = true
        previous = nil // Do not attribute a GPS segment crossing this state boundary to either category.
        active = shift
        save()
    }
    func endRide() {
        guard var shift = active, let i = shift.rides.indices.last, shift.rides[i].ended == nil else { return }
        recordBoundaryPoint(&shift)
        let now = Date()
        shift.rides[i].ended = now
        shift.waitingPeriods.append(BreakPeriod(started: now))
        shift.lastEmptyMovementAt = nil
        stationarySince = nil
        needsNewTrackSegment = true
        previous = nil // Do not attribute a GPS segment crossing this state boundary to either category.
        active = shift
        save()
    }
    func startBreak(kind: RestKind = .other) {
        guard var shift = active, shift.rides.last?.ended != nil || shift.rides.isEmpty, shift.breaks.last?.ended != nil || shift.breaks.isEmpty else { return }
        recordBoundaryPoint(&shift)
        let now = Date()
        if let i = shift.waitingPeriods.indices.last, shift.waitingPeriods[i].ended == nil { shift.waitingPeriods[i].ended = now }
        shift.lastEmptyMovementAt = nil
        stationarySince = nil
        shift.breaks.append(BreakPeriod(started: now, kind: kind))
        needsNewTrackSegment = true
        previous = nil // Do not attribute a GPS segment crossing this state boundary to either category.
        active = shift
        save()
    }
    func endBreak() {
        guard var shift = active, let i = shift.breaks.indices.last, shift.breaks[i].ended == nil else { return }
        // Do not add the phone\u0027s walking position as a vehicle route endpoint.
        let now = Date()
        shift.breaks[i].ended = now
        shift.waitingPeriods.append(BreakPeriod(started: now))
        shift.lastEmptyMovementAt = nil
        stationarySince = nil
        needsNewTrackSegment = true
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
        if shift.breaks.last?.ended != now && !walking {
            recordBoundaryPoint(&shift)
        }
        stationarySince = nil
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
        // Record road bends and empty-driving routes without waiting 100 m.
        // GPS jitter alone must not generate dense stationary points.
        if elapsed >= 30 { return true }
        if meters >= max(25, min(45, point.horizontalAccuracy * 2)) { return true }
        // 转弯时增加轨迹密度，避免道路拐角被连成直线。
        if meters >= 20, point.course >= 0, let old = lastSavedHeading {
            let diff = abs(point.course - old)
            if min(diff, 360 - diff) >= 30 { return true }
        }
        return false
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways: gpsAuthorization = "始终允许"
        case .authorizedWhenInUse: gpsAuthorization = "使用期间（后台可能中断）"
        case .denied: gpsAuthorization = "已拒绝"
        case .restricted: gpsAuthorization = "受系统限制"
        case .notDetermined: gpsAuthorization = "尚未授权"
        @unknown default: gpsAuthorization = "未知"
        }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            if active != nil { manager.startUpdatingLocation() }
        } else if active != nil {
            gpsStatus = "定位权限不足，请检查系统设置"
        }
    }
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        gpsPauseCount += 1
        needsNewTrackSegment = true
        gpsStatus = "系统暂停定位"
    }
    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        gpsResumeCount += 1
        needsNewTrackSegment = true
        gpsStatus = "系统恢复定位"
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        gpsErrorCount += 1
        gpsStatus = "定位异常：" + error.localizedDescription
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard var shift = active else { return }
        for point in locations {
            guard point.horizontalAccuracy > 0, point.horizontalAccuracy <= 35, abs(point.timestamp.timeIntervalSinceNow) < 30 else {
                rejectedGPSCount += 1
                continue
            }
            gpsAccuracy = point.horizontalAccuracy
            gpsSpeed = point.speed >= 0 ? point.speed * 3.6 : nil
            gpsLastUpdate = point.timestamp
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
                if seconds <= 120 && meters > max(8, min(18, (last.horizontalAccuracy + point.horizontalAccuracy) * 0.5)) && speed >= 1.5 && speed < 50 && !walking && !manualBreakActive {
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
            // Confirm a stop from continuous low-speed GPS samples. Once confirmed,
            // credit the whole observed stationary interval, not only time after 60s.
            let rideActive = shift.rides.last.map { $0.ended == nil } ?? false
            let breakActive = shift.breaks.last.map { $0.ended == nil } ?? false
            let waitingActive = shift.waitingPeriods.last.map { $0.ended == nil } ?? false
            let validStationary = point.speed >= 0 && point.speed < 0.8 && !walking
            let sampleGap = previous.map { point.timestamp.timeIntervalSince($0.timestamp) } ?? 0
            if rideActive || breakActive || waitingActive || !validStationary || sampleGap > 120 {
                stationarySince = nil
            } else {
                if stationarySince == nil { stationarySince = point.timestamp }
                if let since = stationarySince, point.timestamp.timeIntervalSince(since) >= parkingThresholdSeconds {
                    shift.waitingPeriods.append(BreakPeriod(started: since))
                    shift.lastEmptyMovementAt = nil
                    stationarySince = nil
                }
            }
            // Keep the previous sample until AFTER segment-gap detection.
            // This applies equally to passenger trips and empty driving.
            let gpsGap = previous.map { point.timestamp.timeIntervalSince($0.timestamp) > 120 } ?? false
            if gpsGap { gpsGapCount += 1 }
            if (breakActive || walking || gpsGap) { needsNewTrackSegment = true }
            if !breakActive && !walking && (needsNewTrackSegment || shouldSaveTrackPoint(point)) {
                shift.points.append(TrackPoint(lat: point.coordinate.latitude, lon: point.coordinate.longitude,
                                              date: point.timestamp, accuracy: point.horizontalAccuracy, speed: point.speed,
                                              segmentStart: needsNewTrackSegment))
                needsNewTrackSegment = false
                lastSavedLocation = point
                if point.course >= 0 { lastSavedHeading = point.course }
            }
            previous = point
        }
        active = shift
        gpsStatus = "GPS 记录中"
        if Date().timeIntervalSince(lastDiskWrite) >= 15 { save() }
    }
    func restoreArchive(_ url: URL) throws {
        guard active == nil else {
            throw NSError(domain: "CarTripAssistant", code: 409, userInfo: [NSLocalizedDescriptionKey: "正在出车，必须先收车才能恢复备份"])
        }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Saved.self, from: data)
        // Never silently overwrite existing data: keep an independent timestamped snapshot.
        if let current = try? Data(contentsOf: file) {
            let stamp = Int(Date().timeIntervalSince1970)
            let archive = file.deletingLastPathComponent().appendingPathComponent("trips-before-restore-\(stamp).json")
            try current.write(to: archive, options: .atomic)
        }
        try data.write(to: file, options: .atomic)
        active = decoded.active
        history = decoded.history
        safeToWrite = true
        previous = nil
        lastSavedLocation = nil
        needsNewTrackSegment = true
        if active != nil { resumeTracking() }
    }
    func exportDiagnostics() -> URL? {
        let payload: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "gpsStatus": gpsStatus,
            "motionStatus": motionStatus,
            "accuracyMeters": gpsAccuracy as Any,
            "speedKmh": gpsSpeed as Any,
            "lastGPSUpdate": gpsLastUpdate.map { ISO8601DateFormatter().string(from: $0) } ?? "none",
            "activeShift": active != nil,
            "activePoints": active?.points.count ?? 0,
            "historyCount": history.count,
            "gpsGapCount": gpsGapCount,
            "rejectedGPSCount": rejectedGPSCount,
            "gpsErrorCount": gpsErrorCount,
            "gpsPauseCount": gpsPauseCount,
            "gpsResumeCount": gpsResumeCount,
            "gpsAuthorization": gpsAuthorization,
            "locationAuthorization": location.authorizationStatus.rawValue,
            "backgroundLocationEnabled": location.allowsBackgroundLocationUpdates
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarTripAssistant-Diagnostics.json")
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
    func exportHistoryCSV() -> URL? {
        func cell(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        var lines = ["开始时间,结束时间,总里程km,载客里程km,空驶里程km,休息里程km,完成订单,流水元,备注"]
        for shift in history.sorted(by: { $0.started < $1.started }) {
            let columns = [
                formatter.string(from: shift.started),
                shift.ended.map { formatter.string(from: $0) } ?? "",
                String(format: "%.3f", shift.kilometers),
                String(format: "%.3f", shift.passengerKM),
                String(format: "%.3f", shift.emptyKilometers),
                String(format: "%.3f", shift.restKilometers),
                String(shift.completedOrders),
                shift.revenue,
                shift.notes
            ]
            lines.append(columns.map(cell).joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarTripAssistant-History.csv")
        guard let data = ("\\u{FEFF}" + lines.joined(separator: "\\r\\n")).data(using: .utf8),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
    func exportArchive() -> URL? {
        guard let data = try? JSONEncoder().encode(Saved(active: active, history: history)) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarTripAssistant-Backup.json")
        do { try data.write(to: url, options: .atomic); return url }
        catch { return nil }
    }
    func exportGPX(_ shift: Shift) -> URL? {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
        }
        let stamp = ISO8601DateFormatter()
        let name = "CarTrip-\(shift.started.formatted(.dateTime.year().month().day()))"
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\\n<gpx version=\"1.1\" creator=\"CarTripAssistant\" xmlns=\"http://www.topografix.com/GPX/1/1\">\\n<trk><name>\(escape(name))</name><trkseg>\\n"
        var priorDate: Date?
        for p in shift.points where (-90...90).contains(p.lat) && (-180...180).contains(p.lon) {
            if p.segmentStart || (priorDate.map { p.date.timeIntervalSince($0) > 120 } ?? false) {
                xml += "</trkseg><trkseg>\\n"
            }
            priorDate = p.date
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
        let end = shift.ended ?? Date()
        let duration = max(0, end.timeIntervalSince(shift.started))
        let totals = shift.timeTotals(at: end)
        let rest = totals.waiting + totals.manualRest
        let work = totals.passenger + totals.empty
        return """
        行程助手 · 每日总结
        出车时间：\(shift.started.formatted())
        结束时间：\(end.formatted())
        出车时长：\(Int(duration / 60)) 分钟
        总休息时长（含等客）：\(Int(rest / 60)) 分钟
        等客时长：\(Int(totals.waiting / 60)) 分钟
        吃饭休息：\(Int(totals.meal / 60)) 分钟
        充电休息：\(Int(totals.charging / 60)) 分钟
        其他休息：\(Int(totals.other / 60)) 分钟
        载客时长：\(Int(totals.passenger / 60)) 分钟
        空驶时长：\(Int(totals.empty / 60)) 分钟
        非休息时长（载客+空驶）：\(Int(work / 60)) 分钟
        全天总里程：\(String(format: "%.2f", shift.kilometers)) 公里
        载客里程：\(String(format: "%.2f", shift.passengerKM)) 公里
        空驶里程：\(String(format: "%.2f", shift.emptyKilometers)) 公里
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
    @State private var detailShift: Shift?
    @State private var showDiscard = false
    @State private var deletionTarget: UUID?
    @State private var gpxExport: URL?
    @State private var selectedTab = 0
    @State private var showRestorePicker = false
    @State private var restoreNotice: String?
    @State private var confirmRestore = false
    @State private var pendingRestore: URL?
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
                    VStack(alignment: .leading, spacing: 12) {
                        if selectedTab == 0 {
                            if let shift = store.active {
                                mileageCard(shift)
                                metrics(shift)
                                controls
                            } else {
                                let idleShift = Shift(started: Date())
                                mileageCard(idleShift)
                                idleMetrics
                                welcome
                            }
                        } else if selectedTab == 1 {
                            if let shift = store.active {
                                Text("今日行驶轨迹").font(.title2.bold())
                                liveMap(shift)
                                routeEntry(shift)
                            } else {
                                Text("开始出车后显示实时轨迹").foregroundStyle(Cockpit.muted)
                            }
                        } else if selectedTab == 2 {
                            toolsPage
                        } else {
                            historySection
                        }
                        Text("本工具不接入网约车平台，订单趟数由乘客上下车按钮记录；GPS 里程为估算值。")
                            .font(.caption).foregroundStyle(Cockpit.muted)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 26)
                }
                bottomTabs
            }
        }
        }
        .fileImporter(isPresented: $showRestorePicker, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-trip-restore.json")
                    if FileManager.default.fileExists(atPath: temp.path) { try FileManager.default.removeItem(at: temp) }
                    try FileManager.default.copyItem(at: url, to: temp)
                    pendingRestore = temp
                    confirmRestore = true
                } catch { restoreNotice = "读取备份失败：\(error.localizedDescription)" }
            case .failure(let error): restoreNotice = error.localizedDescription
            }
        }
        .confirmationDialog("恢复备份将替换当前行程与历史记录。原数据会自动另存备份。是否继续？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("确认恢复", role: .destructive) {
                guard let url = pendingRestore else { return }
                do { try store.restoreArchive(url); restoreNotice = "恢复成功，原有数据已另存备份" }
                catch { restoreNotice = "恢复失败：\(error.localizedDescription)" }
                pendingRestore = nil
            }
        }
        .alert("数据恢复", isPresented: Binding(get: { restoreNotice != nil }, set: { if !$0 { restoreNotice = nil } })) {
            Button("确定", role: .cancel) { restoreNotice = nil }
        } message: { Text(restoreNotice ?? "") }
        .preferredColorScheme(.dark)
        .sheet(item: Binding(
            get: { gpxExport.map { ExportItem(url: $0) } },
            set: { if $0 == nil { gpxExport = nil } }
        )) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showFinish) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("填写今天的流水，收车后会与当天的里程、时间和订单一起保存。")
                            .font(.subheadline).foregroundStyle(Cockpit.muted)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("今日流水（元）").font(.headline)
                            HStack(spacing: 8) {
                                Text("¥").font(.title2.bold()).foregroundStyle(Cockpit.green)
                                TextField("例如 200", text: $revenue)
                                    .keyboardType(.decimalPad)
                                    .foregroundStyle(.white)
                                    .tint(Cockpit.blue)
                                    .font(.system(size: 25, weight: .bold, design: .rounded))
                                    .accessibilityLabel("今日流水金额")
                            }
                            .padding(15)
                            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 14))
                            Text(revenue.isEmpty ? "可留空，历史日报会标记为未填写" : "当前输入：¥" + revenue)
                                .font(.caption).foregroundStyle(Cockpit.muted)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("备注（可选）").font(.headline)
                            TextField("例如：今日运营情况", text: $notes, axis: .vertical)
                                .lineLimit(2...4)
                                .foregroundStyle(.white)
                                .tint(Cockpit.blue)
                                .padding(14)
                                .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 14))
                        }
                        Button {
                            let clean = revenue.trimmingCharacters(in: .whitespacesAndNewlines)
                            store.finish(revenue: clean, notes: notes)
                            revenue = ""; notes = ""
                            showFinish = false
                            selectedTab = 3
                        } label: {
                            Text("确认收车并保存")
                                .font(.headline)
                                .frame(maxWidth: .infinity).padding(.vertical, 17)
                                .foregroundStyle(.white)
                                .background(Cockpit.blue, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                }
                .background(Cockpit.background)
                .navigationTitle("收车结算")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showFinish = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $detailShift) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(item.started.formatted(date: .complete, time: .omitted))
                            .font(.title2.bold())
                        Text("今日流水").foregroundStyle(Cockpit.muted)
                        Text(item.revenue.isEmpty ? "未填写" : "¥" + item.revenue)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Cockpit.green)
                        Text(store.report(item))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !item.notes.isEmpty { Text("备注：" + item.notes).foregroundStyle(Cockpit.muted) }
                    }
                    .padding(20)
                }
                .background(Cockpit.background)
                .navigationTitle("历史日报详情")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { detailShift = nil } } }
            }
            .preferredColorScheme(.dark)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("行程助手").font(.system(size: 25, weight: .bold))
                Text("记录每一趟行程 · 让工作更清晰")
                    .font(.system(size: 11)).foregroundStyle(Cockpit.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(Date().formatted(.dateTime.month().day()))
                    .font(.system(size: 12, weight: .semibold))
                Text(store.active == nil ? "未出车" : (riding ? "载客中" : (resting ? "休息中" : "已出车")))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(store.active == nil ? Cockpit.muted : Cockpit.green)
            }
        }
        .foregroundStyle(.white)
    }
    private var toolsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("驾驶工具箱").font(.system(size: 23, weight: .bold))
            Text("定位诊断 · 停车识别 · 行程备份与恢复 · 里程统计")
                .font(.caption).foregroundStyle(Cockpit.muted)
            VStack(alignment: .leading, spacing: 12) {
                Label("行程统计", systemImage: "chart.bar.fill")
                    .font(.headline).foregroundStyle(Cockpit.green)
                let shifts = store.history + (store.active.map { [$0] } ?? [])
                let calendar = Calendar.current
                let today = shifts.filter { calendar.isDateInToday($0.started) }
                let week = shifts.filter { calendar.isDate($0.started, equalTo: Date(), toGranularity: .weekOfYear) }
                let month = shifts.filter { calendar.isDate($0.started, equalTo: Date(), toGranularity: .month) }
                let year = shifts.filter { calendar.isDate($0.started, equalTo: Date(), toGranularity: .year) }
                toolRow("今日里程", String(format: "%.1f km", today.reduce(0) { $0 + $1.kilometers }))
                toolRow("本周里程", String(format: "%.1f km", week.reduce(0) { $0 + $1.kilometers }))
                toolRow("本月里程", String(format: "%.1f km", month.reduce(0) { $0 + $1.kilometers }))
                toolRow("今年里程", String(format: "%.1f km", year.reduce(0) { $0 + $1.kilometers }))
                toolRow("累计订单", "\(shifts.reduce(0) { $0 + $1.rides.count }) 单")
                let totalSeconds = shifts.reduce(0.0) { $0 + max(0, ($1.ended ?? Date()).timeIntervalSince($1.started)) }
                let totalHours = Int(totalSeconds / 3600)
                let totalMinutes = Int(totalSeconds.truncatingRemainder(dividingBy: 3600) / 60)
                toolRow("累计出车时长", "\(totalHours) 小时 \(totalMinutes) 分钟")
                let monthSeconds = month.reduce(0.0) { $0 + max(0, ($1.ended ?? Date()).timeIntervalSince($1.started)) }
                toolRow("本月出车时长", String(format: "%.1f 小时", monthSeconds / 3600))
                let monthRevenue = month.compactMap { Double($0.revenue.trimmingCharacters(in: .whitespacesAndNewlines)) }.reduce(0, +)
                toolRow("本月已录入流水", String(format: "¥%.2f", monthRevenue))
                toolRow("本月平均每小时流水", monthSeconds > 0 ? String(format: "¥%.1f", monthRevenue * 3600 / monthSeconds) : "暂无")
            }
            .padding(16).background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 12) {
                Label("GPS 定位状态", systemImage: "location.circle.fill")
                    .font(.headline).foregroundStyle(Cockpit.blue)
                toolRow("定位", store.gpsStatus)
                toolRow("定位精度", store.gpsAccuracy.map { String(format: "±%.0f 米", $0) } ?? "暂无有效数据")
                toolRow("GPS 速度", store.gpsSpeed.map { String(format: "%.1f km/h", $0) } ?? "暂无有效数据")
                toolRow("最近定位", store.gpsLastUpdate.map { $0.formatted(date: .omitted, time: .standard) } ?? "尚未收到")
                Text("GPS 速度和位置可能漂移；显示 0 km/h 不等于已确认停车。")
                    .font(.caption).foregroundStyle(Cockpit.muted)
            }
            .padding(16).background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 12) {
                Label("停车与等客识别", systemImage: "car.side.fill")
                Picker("停车确认时间", selection: $store.parkingThresholdSeconds) {
                    Text("30 秒").tag(30.0)
                    Text("60 秒").tag(60.0)
                    Text("120 秒").tag(120.0)
                    Text("180 秒").tag(180.0)
                }.pickerStyle(.menu)
                Text("连续低速且不处于载客、休息状态时，达到设定时间后开始计算等客时间。")
                    .font(.caption).foregroundStyle(Cockpit.muted)
                    .font(.headline).foregroundStyle(Cockpit.green)
                toolRow("运营状态", store.active == nil ? "未出车" : (riding ? "载客中" : (resting ? "手动休息中" : "出车中")))
                toolRow("运动识别", store.motionStatus)
                if let shift = store.active {
                    let waiting = shift.waitingPeriods.last
                    toolRow("等客计时", waiting?.ended == nil && waiting != nil ? "正在累计" : "未在累计")
                    toolRow("轨迹点数", "\(shift.points.count) 个")
                } else {
                    Text("点击出车后，才能记录停车和等客状态。")
                        .font(.caption).foregroundStyle(Cockpit.muted)
                }
                Text("仅显示当前识别结果；GPS 中断时不能保证自动识别停车。")
                    .font(.caption).foregroundStyle(Cockpit.muted)
            }
            .padding(16).background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 12) {
                Label("数据备份", systemImage: "externaldrive.fill")
                    .font(.headline).foregroundStyle(.purple)
                Text("导出包含历史日报、流水、轨迹及当前出车状态的 JSON 备份文件。")
                    .font(.subheadline).foregroundStyle(Cockpit.muted)
                Button {
                    store.flushToDisk()
                    gpxExport = store.exportArchive()
                } label: {
                    Label("导出完整行程备份", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Cockpit.blue, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                Button {
                    gpxExport = store.exportHistoryCSV()
                } label: {
                    Label("导出历史统计 CSV", systemImage: "tablecells")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Cockpit.secondary, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                Button {
                showRestorePicker = true
            } label: {
                Label("从 JSON 备份恢复", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Cockpit.secondary, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
            Text("恢复前会自动保存旧数据快照；请先结束正在进行的行程。")
                    .font(.caption).foregroundStyle(Cockpit.muted)
            }
            .padding(16).background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 8) {
                Label("行程诊断", systemImage: "waveform.path.ecg")
                    .font(.headline).foregroundStyle(.orange)
                toolRow("历史记录", "\(store.history.count) 条")
                toolRow("最近定位距今", store.gpsLastUpdate.map { "\(Int(max(0, Date().timeIntervalSince($0)))) 秒" } ?? "暂无")
                toolRow("GPS 超时断点", "\(store.gpsGapCount) 次")
                toolRow("GPS 无效点", "\(store.rejectedGPSCount) 个")
                toolRow("定位错误", "\(store.gpsErrorCount) 次")
                toolRow("定位权限", store.gpsAuthorization)
                toolRow("系统暂停 / 恢复", "\(store.gpsPauseCount) / \(store.gpsResumeCount) 次")
                Button {
                    gpxExport = store.exportDiagnostics()
                } label: {
                    Label("导出 GPS 诊断报告", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Cockpit.secondary, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                toolRow("当前行程", store.active == nil ? "无" : "记录中")
                Text("原地停车出现里程增加时，可查看 GPS 精度、速度和运动识别数据。")
                    .font(.caption).foregroundStyle(Cockpit.muted)
            }
            .padding(16).background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
        }
    }
    private func toolRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Cockpit.muted)
            Spacer(minLength: 12)
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 14))
    }
    private var bottomTabs: some View {
        HStack(spacing: 0) {
            tab("首页", "house.fill", index: 0)
            tab("轨迹", "map.fill", index: 1)
            tab("工具", "wrench.and.screwdriver.fill", index: 2)
            tab("记录", "doc.text.fill", index: 3)
        }
        .padding(.top, 10).padding(.bottom, 5)
        .background(Cockpit.background)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.10)).frame(height: 1) }
    }
    private func tab(_ label: String, _ icon: String, index: Int) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selectedTab == index ? Color.cyan : Cockpit.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
    private func liveMap(_ shift: Shift) -> some View {
        NavigationLink {
            RouteDetail(shift: shift)
        } label: {
            ZStack(alignment: .bottomLeading) {
                TripRouteMap(shift: shift)
                    .frame(height: 205)
                    .allowsHitTesting(false)
                Label("今日行驶轨迹 · 点击查看", systemImage: "location.fill")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Cockpit.blue.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
    private func routeEntry(_ shift: Shift) -> some View {
        NavigationLink {
            RouteDetail(shift: shift)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Label("今日行驶轨迹", systemImage: "map.fill")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    Text("\(shift.points.count) 个记录点")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(14)
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
            LinearGradient(colors: [Color(red: 0.02, green: 0.37, blue: 0.83), Color(red: 0.03, green: 0.20, blue: 0.48), Cockpit.background],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 25)
        )
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(Cockpit.blue.opacity(0.3), lineWidth: 1))
    }
    private func clockString(_ seconds: Int) -> String {
        let hours = seconds / 3600
        return String(format: "%02d:%02d:%02d", hours, (seconds / 60) % 60, seconds % 60)
    }
    private var idleMetrics: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            metric("完成订单", "0", "单", "checkmark.circle.fill", Cockpit.green)
            metric("载客里程", "0.00", "km", "person.fill", Cockpit.blue)
            metric("空驶里程", "0.00", "km", "car.side", .orange)
            metric("总休息时间", "00:00:00", "", "cup.and.saucer.fill", .purple)
            metric("载客时长", "00:00:00", "", "clock.fill", .pink)
            metric("本次出车时长", "00:00:00", "", "clock", .cyan)
        }
    }
    private func metrics(_ shift: Shift) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = min(timeline.date, shift.ended ?? timeline.date)
            let totals = shift.timeTotals(at: now)
            let restSeconds = totals.manualRest + totals.waiting
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                metric("完成订单", "\(shift.completedOrders)", "单", "checkmark.circle.fill", Cockpit.green)
                metric("载客里程", String(format: "%.2f", shift.passengerKM), "km", "person.fill", Cockpit.blue)
                metric("空驶里程", String(format: "%.2f", shift.emptyKilometers), "km", "car.side", .orange)
                metric("总休息时间", clockString(Int(restSeconds)), "", "cup.and.saucer.fill", .purple)
                metric("载客时长", clockString(Int(totals.passenger)), "", "clock.fill", .pink)
                metric("本次出车时长", clockString(max(0, Int(now.timeIntervalSince(shift.started)))), "", "clock", .cyan)
            }
        }
    }
    private func metric(_ label: String, _ value: String, _ unit: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 29, height: 29)
                    .background(tint.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                Text(unit).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(12)
        .background(LinearGradient(colors: [tint.opacity(0.26), Cockpit.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(tint.opacity(0.55), lineWidth: 1))
    }
    private var controls: some View {
        VStack(spacing: 10) {
            if riding {
                action("乘客下车", symbol: "checkmark.flag.fill", color: .orange) { store.endRide() }
            } else if resting {
                action("结束休息", symbol: "play.fill", color: Cockpit.green) { store.endBreak() }
            } else {
                HStack(spacing: 8) {
                    compactRest("乘客上车", "person.fill", Cockpit.blue) { store.startRide() }
                    compactRest("吃饭休息", "cup.and.saucer.fill", .orange) { store.startBreak(kind: .meal) }
                    compactRest("充电等待", "bolt.fill", .purple) { store.startBreak(kind: .charging) }
                    compactRest("其他休息", "sofa.fill", Cockpit.green) { store.startBreak(kind: .other) }
                }
            }
            Button { showFinish = true } label: {
                Label("收车", systemImage: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 13))
            }
            Button(role: .destructive) { showDiscard = true } label: {
                Text("放弃本次测试记录").font(.caption2).foregroundStyle(Cockpit.muted)
            }
        }
    }
    private func compactRest(_ label: String, _ symbol: String, _ tint: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 19))
                Text(label).font(.system(size: 10, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity).frame(height: 58)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.45)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
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
        Button { store.startShift() } label: {
            Label("出车", systemImage: "play.fill")
                .font(.system(size: 19, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 60)
                .foregroundStyle(.white)
                .background(Cockpit.blue, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
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
                    Button { detailShift = item } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.started.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 16, weight: .bold))
                        Text("\(item.completedOrders) 单  ·  " + String(format: "%.2f km", item.kilometers))
                            .font(.system(size: 13)).foregroundStyle(Cockpit.muted)
                        Text(item.revenue.isEmpty ? "今日流水：未填写" : "今日流水：¥" + item.revenue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Cockpit.green)
                        Label("查看完整日报", systemImage: "chevron.right")
                            .font(.caption.bold()).foregroundStyle(Cockpit.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 5)
                    NavigationLink {
                        ShareJourneyCard(shift: item)
                    } label: {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                            .frame(width: 30, height: 42)
                    }
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
            tiles.canReplaceMapContent = false
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
            if p.segmentStart || passenger != segmentPassenger || (previousDate.map { p.date.timeIntervalSince($0) > 120 } ?? false) {
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
private struct ShareJourneyCard: View {
    let shift: Shift
    private func clock(_ t: TimeInterval) -> String {
        let n = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", n / 3600, (n / 60) % 60, n % 60)
    }
    private func tile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(Cockpit.muted)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(11)
        .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    var body: some View {
        let end = shift.ended ?? Date()
        let totals = shift.timeTotals(at: end)
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("今日行程报告").font(.system(size: 23, weight: .bold))
                        Text(shift.started.formatted(date: .complete, time: .omitted))
                            .font(.caption).foregroundStyle(Cockpit.muted)
                    }
                    Spacer()
                    Image(systemName: "car.side.fill").font(.title2).foregroundStyle(Cockpit.blue)
                }
                TripRouteMap(shift: shift)
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .allowsHitTesting(false)
                HStack(spacing: 12) {
                    Label("全天轨迹", systemImage: "line.diagonal").foregroundStyle(Cockpit.blue)
                    Label("载客路段", systemImage: "line.diagonal").foregroundStyle(Cockpit.green)
                    Spacer()
                    Text("\(shift.points.count) 点").foregroundStyle(Cockpit.muted)
                }.font(.system(size: 11))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    tile("全天总里程", String(format: "%.2f km", shift.kilometers), .white)
                    tile("完成订单", "\(shift.completedOrders) 单", Cockpit.green)
                    tile("载客里程", String(format: "%.2f km", shift.passengerKM), Cockpit.blue)
                    tile("空驶里程", String(format: "%.2f km", shift.emptyKilometers), .orange)
                    tile("总休息时间", clock(totals.waiting + totals.manualRest), .purple)
                    tile("本次出车时长", clock(end.timeIntervalSince(shift.started)), .cyan)
                }
                HStack {
                    Text("今日流水").foregroundStyle(Cockpit.muted)
                    Spacer()
                    Text(shift.revenue.isEmpty ? "未填写" : "¥" + shift.revenue)
                        .foregroundStyle(Cockpit.green).fontWeight(.bold)
                }
                .font(.system(size: 14))
                .padding(11)
                .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 12))
                Text("行程助手 · GPS 轨迹与里程为估算值")
                    .font(.system(size: 10)).foregroundStyle(Cockpit.muted)
                    .frame(maxWidth: .infinity)
            }.padding(12)
        }
        .background(Cockpit.background)
        .navigationTitle("行程分享卡")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}
private struct RouteDetail: View {
    let shift: Shift
    @State private var importMap = false
    @State private var mapRevision = 0
    @StateObject private var mapDownload = ShenzhenMapDownload()
    @State private var mapError: String?
    @State private var replayIndex = 0
    @State private var replayRunning = false
    @State private var replaySpeed = 1
    private let replayTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private var replayCount: Int { shift.points.count }
    private var replayShift: Shift {
        var partial = shift
        partial.points = Array(shift.points.prefix(min(replayCount, max(1, replayIndex + 1))))
        return partial
    }
    var body: some View {
        VStack(spacing: 0) {
            TripRouteMap(shift: replayIndex == 0 && !replayRunning ? shift : replayShift)
                .id(mapRevision)
                .onReceive(replayTimer) { _ in
                    guard replayRunning else { return }
                    replayIndex = min(max(0, replayCount - 1), replayIndex + replaySpeed * 4)
                    if replayIndex >= replayCount - 1 { replayRunning = false }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(OfflineMap.file == nil ? "在线地图 · 深圳离线包未下载" : "深圳离线道路图已安装 · © OpenStreetMap")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if OfflineMap.file == nil {
                    Button(mapDownload.downloading ? "取消下载" : "下载深圳地图") {
                        if mapDownload.downloading { mapDownload.cancel() }
                        else { mapDownload.start { mapRevision += 1 } }
                    }.font(.caption.bold())
                } else {
                    Button("删除地图") {
                        try? OfflineMap.remove()
                        mapRevision += 1
                    }.font(.caption.bold()).foregroundStyle(.red)
                }
                Button("导入") { importMap = true }
                    .font(.caption.bold())
            }.padding(.horizontal, 15).padding(.top, 10)
            if mapDownload.downloading {
                ProgressView(value: mapDownload.progress).padding(.horizontal, 15)
                Text("下载深圳地图：\(Int(mapDownload.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = mapDownload.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 15)
            }
            if replayCount > 1 {
                VStack(spacing: 7) {
                    HStack {
                        Button(replayRunning ? "暂停回放" : "播放轨迹") {
                            if replayIndex >= replayCount - 1 { replayIndex = 0 }
                            replayRunning.toggle()
                        }.buttonStyle(.borderedProminent)
                        Button("重置") { replayRunning = false; replayIndex = 0 }
                            .buttonStyle(.bordered)
                        Spacer()
                        Picker("速度", selection: $replaySpeed) {
                            Text("1×").tag(1)
                            Text("2×").tag(2)
                            Text("5×").tag(5)
                        }.pickerStyle(.menu)
                    }
                    Slider(value: Binding(get: { Double(replayIndex) }, set: { replayIndex = Int($0); replayRunning = false }),
                           in: 0...Double(replayCount - 1), step: 1)
                    Text(replayIndex == 0 && !replayRunning ? "完整路线" : "回放：\(shift.points[min(replayIndex, replayCount - 1)].date.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 15).padding(.vertical, 8)
            }
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
        return nil
    }
    static func remove() throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let target = folder.appendingPathComponent("offline.mbtiles")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
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
private final class ShenzhenMapDownload: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: Double = 0
    @Published var downloading = false
    @Published var errorMessage: String?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var completion: (() -> Void)?
    private let mapURL = URL(string: "https://github.com/tu134186/CarTripAssistant/releases/download/shenzhen-map-v1/Shenzhen-Roads.mbtiles")!
    func start(completion: @escaping () -> Void) {
        guard !downloading else { return }
        self.completion = completion
        errorMessage = nil
        progress = 0
        downloading = true
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.downloadTask(with: mapURL)
        task?.resume()
    }
    func cancel() {
        task?.cancel()
        task = nil
        downloading = false
        session?.invalidateAndCancel()
        session = nil
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        DispatchQueue.main.async { self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "ShenzhenMap", code: 2, userInfo: [NSLocalizedDescriptionKey: "地图下载地址不可用，请稍后重试或手动导入 MBTiles"])
            }
            try OfflineMap.install(location)
            DispatchQueue.main.async {
                self.downloading = false
                self.progress = 1
                self.completion?()
                self.completion = nil
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription; self.downloading = false }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let error = error, (error as NSError).code != NSURLErrorCancelled {
                self.errorMessage = error.localizedDescription
                self.downloading = false
            }
            self.session?.finishTasksAndInvalidate()
            self.session = nil
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
