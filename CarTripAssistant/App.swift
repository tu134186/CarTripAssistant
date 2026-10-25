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
    @Published private(set) var latestGPSLocation: CLLocation?
    @Published var gpsRecoveredFromBackup = false
    @Published var gpsReceivedCount = 0
    @Published var gpsSavedCount = 0
    @Published var gpsNotSavedCount = 0
    @Published var gpsOutOfOrderCount = 0
    @Published var gpsAccuracyRejectedCount = 0
    @Published var gpsTimestampRejectedCount = 0
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
    private var distanceAnchor: CLLocation?
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
        let primarySaved = primaryData.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        let saved = primarySaved ?? backupData.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        gpsRecoveredFromBackup = primarySaved == nil && saved != nil
        if let saved {
            active = saved.active
            history = saved.history
        } else if primaryData != nil || backupData != nil {
            // Never overwrite an unreadable trip archive with an empty one.
            safeToWrite = false
            gpsStatus = "历史记录读取失败，请先备份数据"
        }
        location.delegate = self
        location.activityType = .automotiveNavigation
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true
        if active != nil {
            needsNewTrackSegment = true
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
        distanceAnchor = nil
        lastSavedLocation = nil
        lastSavedHeading = nil
        needsNewTrackSegment = true
        stationarySince = nil
        save()
        resumeTracking()
        // Request an immediate fresh fix instead of waiting for the distance
        // filter to deliver a movement event. Pre-shift fixes are rejected above.
        location.requestLocation()
    }
    func startRide() {
        guard var shift = active, shift.rides.last?.ended != nil || shift.rides.isEmpty else { return }
        recordBoundaryPoint(&shift)
        let now = Date()
        if let i = shift.breaks.indices.last, shift.breaks[i].ended == nil { shift.breaks[i].ended = now }
        if let i = shift.waitingPeriods.indices.last, shift.waitingPeriods[i].ended == nil { shift.waitingPeriods[i].ended = now }
        shift.lastEmptyMovementAt = nil
        stationarySince = nil
        shift.rides.append(Ride(started: now))
        needsNewTrackSegment = true
        previous = nil // Do not attribute a GPS segment crossing this state boundary to either category.
        distanceAnchor = nil
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
        recordBoundaryPoint(&shift)
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
        // Boundary markers must not inject cached fixes from before this shift
        // or rewind an already-recorded track when Core Location updates lag.
        guard let point = latestGPSLocation,
              point.timestamp >= shift.started.addingTimeInterval(-2),
              point.horizontalAccuracy > 0, point.horizontalAccuracy <= 80,
              point.timestamp.timeIntervalSinceNow <= 5,
              point.timestamp.timeIntervalSinceNow >= -15 else { return }
        if let last = shift.points.last, point.timestamp <= last.date { return }
        shift.points.append(TrackPoint(lat: point.coordinate.latitude, lon: point.coordinate.longitude,
                                      date: point.timestamp, accuracy: point.horizontalAccuracy, speed: point.speed))
        lastSavedLocation = point
        // A valid boundary sample is a new segment origin; do not bridge categories.
        previous = point
    }
    private func shouldSaveTrackPoint(_ point: CLLocation) -> Bool {
        // Keep collecting GPS while parked, but reject stationary coordinate jitter.
        guard let last = lastSavedLocation else { return true }
        let elapsed = point.timestamp.timeIntervalSince(last.timestamp)
        guard elapsed >= 0.8 else { return false }
        let meters = point.distance(from: last)
        let accuracy = max(point.horizontalAccuracy, last.horizontalAccuracy)
        let recentSpeed = previous?.speed ?? -1
        let credibleMovement = (point.speed >= 0.6 && point.speed < 50) ||
            (recentSpeed >= 0.6 && recentSpeed < 50)
        if credibleMovement {
            return meters >= max(2.5, min(10.0, accuracy * 0.4))
        }
        if point.speed < 0 && recentSpeed < 0 {
            return meters >= max(12.0, accuracy * 1.5) && meters / elapsed >= 0.8 && meters / elapsed < 50
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
        let countBeforeUpdate = shift.points.count
        // Core Location can deliver a batch in non-chronological order after background wake-up.
        // Sort the batch before applying monotonic timestamp checks to avoid dropping valid fixes.
        for point in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            gpsReceivedCount += 1
            // Core Location may deliver a cached fix from before this shift began.
            // Never allow that older coordinate to become the new trip's start pin.
            guard point.timestamp >= shift.started.addingTimeInterval(-2),
                  point.horizontalAccuracy > 0, point.horizontalAccuracy <= 80,
                  point.timestamp.timeIntervalSinceNow <= 10,
                  point.timestamp.timeIntervalSinceNow >= -21600 else {
                rejectedGPSCount += 1
                if point.horizontalAccuracy <= 0 || point.horizontalAccuracy > 80 { gpsAccuracyRejectedCount += 1 }
                else { gpsTimestampRejectedCount += 1 }
                continue
            }
            gpsAccuracy = point.horizontalAccuracy
            gpsSpeed = point.speed >= 0 ? point.speed * 3.6 : nil
            // Never publish a stale/out-of-order fix as the latest recorder
            // location: otherwise the diagnostic endpoint can move backwards.
            if let last = previous, point.timestamp <= last.timestamp {
                gpsOutOfOrderCount += 1
                rejectedGPSCount += 1
                continue
            }
            gpsLastUpdate = point.timestamp
            latestGPSLocation = point
            if let last = previous {
                let seconds = point.timestamp.timeIntervalSince(last.timestamp)
                // Delayed batches must still be chronological; reject duplicates
                // or out-of-order samples rather than rewinding the route.
                guard seconds > 0 else { rejectedGPSCount += 1; continue }
                let meters = point.distance(from: last)
                let speed = meters / seconds
                // All valid movement counts throughout the shift, including walking and legacy rest.
                // Preserve sub-threshold motion: compare with the last credited
                // fix rather than discarding each 5 m Core Location callback.
                // Reset on breaks, GPS gaps and impossible jumps.
                if seconds > 120 || speed >= 50 {
                    distanceAnchor = point
                }
                if let anchor = distanceAnchor,
                   point.timestamp.timeIntervalSince(anchor.timestamp) > 120 {
                    distanceAnchor = last
                }
                if distanceAnchor == nil { distanceAnchor = last }
                let anchor = distanceAnchor ?? last
                let anchorSeconds = point.timestamp.timeIntervalSince(anchor.timestamp)
                let anchorMeters = point.distance(from: anchor)
                let anchorSpeed = anchorSeconds > 0 ? anchorMeters / anchorSeconds : 0
                let threshold = max(8, min(18, (anchor.horizontalAccuracy + point.horizontalAccuracy) * 0.5))
                if seconds <= 120 && anchorSeconds > 0 &&
                   anchorSeconds <= 120 && anchorMeters >= threshold &&
                   anchorSpeed >= 0.6 && anchorSpeed < 50 && speed < 50 {
                    distanceAnchor = point
                    let km = anchorMeters / 1000
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
            if gpsGap { needsNewTrackSegment = true }
            // Capture all credible movement independent of passenger/rest state.
            // This is a recorded GPS fix, not an interpolated playback position.
            if shift.points.isEmpty || shouldSaveTrackPoint(point) {
                shift.points.append(TrackPoint(lat: point.coordinate.latitude, lon: point.coordinate.longitude,
                                              date: point.timestamp, accuracy: point.horizontalAccuracy, speed: point.speed,
                                              segmentStart: needsNewTrackSegment))
                gpsSavedCount += 1
                needsNewTrackSegment = false
                lastSavedLocation = point
                if point.course >= 0 { lastSavedHeading = point.course }
            } else {
                gpsNotSavedCount += 1
            }
            previous = point
        }
        active = shift
        gpsStatus = shift.points.isEmpty ? "等待有效轨迹点（精度需≤80米）" : "GPS 记录中 · \(shift.points.count)点"
        // Persist the first accepted fix immediately. Otherwise terminating
        // the app before the 15-second flush can lose the new shift's start.
        if shift.points.count > countBeforeUpdate || Date().timeIntervalSince(lastDiskWrite) >= 15 { save() }
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
            "recoveredFromBackup": gpsRecoveredFromBackup,
            "motionStatus": motionStatus,
            "accuracyMeters": gpsAccuracy as Any,
            "speedKmh": gpsSpeed as Any,
            "lastGPSUpdate": gpsLastUpdate.map { ISO8601DateFormatter().string(from: $0) } ?? "none",
            "activeShift": active != nil,
            "activePoints": active?.points.count ?? 0,
            "historyCount": history.count,
            "gpsGapCount": gpsGapCount,
            "gpsReceivedCount": gpsReceivedCount,
            "gpsSavedCount": gpsSavedCount,
            "gpsNotSavedCount": gpsNotSavedCount,
            "gpsOutOfOrderCount": gpsOutOfOrderCount,
            "gpsAccuracyRejectedCount": gpsAccuracyRejectedCount,
            "gpsTimestampRejectedCount": gpsTimestampRejectedCount,
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
    func exportHistoryCSV(_ selected: [Shift]? = nil) -> URL? {
        func cell(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        var lines = ["开始时间,结束时间,总里程km,载客里程km,空驶里程km,休息里程km,完成订单,流水元,备注"]
        for shift in (selected ?? history).sorted(by: { $0.started < $1.started }) {
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
        guard let data = ("\u{FEFF}" + lines.joined(separator: "\r\n")).data(using: .utf8),
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
        let stamp = ISO8601DateFormatter()
        let name = "CarTrip-\(shift.started.formatted(.dateTime.year().month().day()))"
        let escapedName = name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\\n<gpx version=\"1.1\" creator=\"CarTripAssistant\" xmlns=\"http://www.topografix.com/GPX/1/1\">\\n<trk><name>\(escapedName)</name>\\n"
        var priorDate: Date?
        var segmentOpen = false
        for p in shift.points where (-90...90).contains(p.lat) && (-180...180).contains(p.lon) {
            let newSegment = p.segmentStart || (priorDate.map { p.date.timeIntervalSince($0) > 120 } ?? false)
            if !segmentOpen || newSegment {
                if segmentOpen { xml += "</trkseg>\\n" }
                xml += "<trkseg>\\n"
                segmentOpen = true
            }
            priorDate = p.date
            xml += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><time>\(stamp.string(from: p.date))</time></trkpt>\\n"
        }
        if segmentOpen { xml += "</trkseg>\\n" }
        xml += "</trk></gpx>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(shift.id.uuidString).gpx")
        do { try xml.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }
    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        save()
    }
    func deleteHistoryBatch(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        history.removeAll { ids.contains($0.id) }
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
        let rest = max(0, duration - totals.passenger)
        let work = totals.passenger + totals.empty
        return """
        行程助手 · 每日总结
        出车时间：\(shift.started.formatted())
        结束时间：\(end.formatted())
        出车时长：\(Int(duration / 60)) 分钟
        总休息时长（所有非载客时间）：\(Int(rest / 60)) 分钟
        等客时长：\(Int(totals.waiting / 60)) 分钟
        吃饭休息：\(Int(totals.meal / 60)) 分钟
        充电休息：\(Int(totals.charging / 60)) 分钟
        其他休息：\(Int(totals.other / 60)) 分钟
        载客时长：\(Int(totals.passenger / 60)) 分钟
        空驶时长：\(Int(totals.empty / 60)) 分钟
        非休息时长（载客+空驶）：\(Int(work / 60)) 分钟
        全天总里程：\(String(format: "%.2f", shift.kilometers)) 公里
        载客里程：\(String(format: "%.2f", shift.passengerKM)) 公里
        空驶里程：\(String(format: "%.2f", max(0, shift.kilometers - shift.passengerKM))) 公里
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
                .preferredColorScheme(ThemePreference.scheme(UserDefaults.standard.string(forKey: "cartrip.appearance") ?? "auto"))
        }
        .onChange(of: scenePhase) { phase in
            if phase == .inactive || phase == .background {
                store.flushToDisk()
            }
        }
    }
}

private enum ThemePreference {
    static func scheme(_ value: String) -> ColorScheme? {
        switch value { case "day": return .light; case "night": return .dark; default: return nil }
    }
}
private enum Cockpit {
    private static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static let background = adaptive(UIColor(red: 0.88, green: 0.93, blue: 0.98, alpha: 1), UIColor(red: 0.035, green: 0.055, blue: 0.105, alpha: 1))
    static let panel = adaptive(UIColor(red: 0.975, green: 0.99, blue: 1, alpha: 1), UIColor(red: 0.085, green: 0.14, blue: 0.235, alpha: 1))
    static let secondary = adaptive(UIColor(red: 0.78, green: 0.87, blue: 0.98, alpha: 1), UIColor(red: 0.13, green: 0.21, blue: 0.34, alpha: 1))
    static let blue = adaptive(UIColor(red: 0.06, green: 0.35, blue: 0.84, alpha: 1), UIColor(red: 0.19, green: 0.48, blue: 1, alpha: 1))
    static let muted = adaptive(UIColor(red: 0.19, green: 0.29, blue: 0.43, alpha: 1), UIColor(red: 0.70, green: 0.79, blue: 0.92, alpha: 1))
    static let green = adaptive(UIColor(red: 0.04, green: 0.52, blue: 0.33, alpha: 1), UIColor(red: 0.26, green: 0.88, blue: 0.65, alpha: 1))
}
struct Dashboard: View {
    @EnvironmentObject private var store: TripStore
    @AppStorage("cartrip.appearance") private var appearance = "auto"
    @State private var revenue = ""
    @State private var notes = ""
    @State private var showFinish = false
    @State private var historySearch = ""
    @State private var historyPeriod = 0
    @State private var expandedHistoryDays: Set<String> = []
    @AppStorage("cartrip.tools.statsExpanded") private var statsExpanded = false
    @AppStorage("cartrip.tools.parkingExpanded") private var parkingExpanded = false
    @AppStorage("cartrip.tools.backupExpanded") private var backupExpanded = false
    @AppStorage("cartrip.tools.diagnosticsExpanded") private var diagnosticsExpanded = false
    @State private var detailShift: Shift?
    @State private var showDiscard = false
    @State private var deletionTarget: UUID?
    @State private var historyRoute: Shift?
    @State private var selectingHistory = false
    @State private var selectedHistoryIDs: Set<UUID> = []
    @State private var confirmBatchDelete = false
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
                    .frame(height: 78)
                    .frame(maxWidth: .infinity)
                    .background(Cockpit.background)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Cockpit.blue.opacity(0.10)).frame(height: 1)
                    }
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
                            }
                        } else if selectedTab == 1 {
                            if let shift = store.active {
                                RouteDetail(shift: shift, embedded: true)
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "map").font(.system(size: 36)).foregroundStyle(Cockpit.blue)
                                    Text("暂无行驶轨迹").font(.headline)
                                    Text("开始出车后可查看实时轨迹").font(.subheadline).foregroundStyle(Cockpit.muted)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 65)
                            }
                        } else if selectedTab == 2 {
                            toolsPage
                        } else {
                            historySection
                        }
                        if selectedTab == 0 {
                            Text("本工具不接入网约车平台，订单趟数由乘客上下车按钮记录；GPS 里程为估算值。")
                                .font(.caption).foregroundStyle(Cockpit.muted)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 26)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
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
        .preferredColorScheme(ThemePreference.scheme(appearance))
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
                                    .foregroundStyle(.primary)
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
                                .foregroundStyle(.primary)
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
            .preferredColorScheme(ThemePreference.scheme(UserDefaults.standard.string(forKey: "cartrip.appearance") ?? "auto"))
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $historyRoute) { item in
            historyRouteFullScreen(item)
        }
        .fullScreenCover(item: $detailShift) { item in
            NavigationStack {
                HistoryReportDetail(shift: item)
                    .navigationTitle("历史日报详情")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { detailShift = nil }
                        }
                    }
            }
            .preferredColorScheme(ThemePreference.scheme(UserDefaults.standard.string(forKey: "cartrip.appearance") ?? "auto"))
        }
        .confirmationDialog("删除选中的历史记录？", isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("永久删除 \(selectedHistoryIDs.count) 条", role: .destructive) {
                store.deleteHistoryBatch(selectedHistoryIDs)
                selectedHistoryIDs.removeAll()
                selectingHistory = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，未勾选的记录不受影响。")
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
    // Keep the large history route view outside Dashboard.body to avoid SwiftUI type-check timeout.
    private func historyRouteFullScreen(_ item: Shift) -> some View {
            NavigationStack {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("行驶足迹")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundStyle(Color.primary)
                            Text("查看轨迹 · 分段回放")
                                .font(.system(size: 11))
                                .foregroundStyle(Cockpit.muted)
                        }
                        Spacer()
                        Button("完成") { historyRoute = nil }
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 78)
                    .frame(maxWidth: .infinity)
                    .background(Cockpit.background)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Cockpit.blue.opacity(0.10)).frame(height: 1)
                    }
                    ScrollView {
                        RouteDetail(shift: item, embedded: true)
                            .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .background(Cockpit.background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
            }
            .preferredColorScheme(ThemePreference.scheme(UserDefaults.standard.string(forKey: "cartrip.appearance") ?? "auto"))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(["行程助手", "行驶足迹", "驾驶工具", "行程记录"][selectedTab]).font(.system(size: 25, weight: .bold))
                Text(["记录每一趟行程 · 让工作更清晰", "查看轨迹 · 分段回放", "统计 · 定位 · 备份 · 诊断", "查询历史行程"][selectedTab])
                    .font(.system(size: 11)).foregroundStyle(Cockpit.muted)
            }
            Spacer()
            if selectedTab == 0 {
            VStack(alignment: .trailing, spacing: 5) {
                Text(Date().formatted(.dateTime.month().day()))
                    .font(.system(size: 12, weight: .semibold))
                Button {
                    if store.active == nil { store.startShift() }
                    else { showFinish = true }
                } label: {
                    Label(store.active == nil ? "出车" : "收车", systemImage: store.active == nil ? "play.fill" : "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(store.active == nil ? Cockpit.green : Color.red, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            }
        }
        .foregroundStyle(.primary)
    }
    private var toolsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("外观设置", systemImage: "sun.max.fill").font(.headline).foregroundStyle(Cockpit.blue)
                Picker("显示模式", selection: $appearance) {
                    Text("自动").tag("auto")
                    Text("白天").tag("day")
                    Text("夜间").tag("night")
                }.pickerStyle(.segmented)
                Text("自动模式跟随 iPhone 系统外观").font(.caption).foregroundStyle(Cockpit.muted)
            }
            .padding(14)
            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 14))
            DisclosureGroup(isExpanded: $statsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
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
                let monthKM = month.reduce(0.0) { $0 + $1.kilometers }
                let monthOrders = month.reduce(0) { $0 + $1.completedOrders }
                let monthPassengerKM = month.reduce(0.0) { $0 + $1.passengerKM }
                toolRow("本月每公里流水", monthKM > 0 ? String(format: "¥%.2f/km", monthRevenue / monthKM) : "暂无")
                toolRow("本月每单平均流水", monthOrders > 0 ? String(format: "¥%.2f", monthRevenue / Double(monthOrders)) : "暂无")
                toolRow("本月载客里程占比", monthKM > 0 ? String(format: "%.1f%%", monthPassengerKM / monthKM * 100) : "暂无")
                let weekRevenue = week.compactMap { Double($0.revenue.trimmingCharacters(in: .whitespacesAndNewlines)) }.reduce(0, +)
                let yearRevenue = year.compactMap { Double($0.revenue.trimmingCharacters(in: .whitespacesAndNewlines)) }.reduce(0, +)
                toolRow("本周已录入流水", String(format: "¥%.2f", weekRevenue))
                toolRow("今年已录入流水", String(format: "¥%.2f", yearRevenue))
            
                }
                .padding(.top, 8)
            } label: {
                Label("行程统计", systemImage: "chart.bar.fill")
            }
            .padding(16)
            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
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
            DisclosureGroup(isExpanded: $parkingExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                Picker("停车确认时间", selection: $store.parkingThresholdSeconds) {
                    Text("30 秒").tag(30.0)
                    Text("60 秒").tag(60.0)
                    Text("120 秒").tag(120.0)
                    Text("180 秒").tag(180.0)
                }.pickerStyle(.menu)
                Text("连续低速且不处于载客、休息状态时，达到设定时间后开始计算等客时间。")
                    .font(.caption).foregroundStyle(Cockpit.muted)
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
                .padding(.top, 8)
            } label: {
                Label("停车与等客识别", systemImage: "car.side.fill")
            }
            .padding(16)
            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            .padding(16).background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            DisclosureGroup(isExpanded: $backupExpanded) {
                VStack(alignment: .leading, spacing: 12) {
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
                .padding(.top, 8)
            } label: {
                Label("数据备份", systemImage: "externaldrive.fill")
            }
            .padding(16)
            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            .padding(16).background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                toolRow("历史记录", "\(store.history.count) 条")
                toolRow("最近定位距今", store.gpsLastUpdate.map { "\(Int(max(0, Date().timeIntervalSince($0)))) 秒" } ?? "暂无")
                toolRow("本次启动收到定位", "\(store.gpsReceivedCount) 个")
                toolRow("本次启动保存轨迹", "\(store.gpsSavedCount) 个")
                toolRow("有效但未存轨迹", "\(store.gpsNotSavedCount) 个")
                toolRow("重复或乱序定位", "\(store.gpsOutOfOrderCount) 个")
                toolRow("精度不达标", "\(store.gpsAccuracyRejectedCount) 个")
                toolRow("时间异常", "\(store.gpsTimestampRejectedCount) 个")
                toolRow("当前 GPS 精度", store.gpsAccuracy.map { String(format: "%.1f 米", $0) } ?? "暂无")
                toolRow("GPS 超时断点", "\(store.gpsGapCount) 次")
                toolRow("GPS 无效点", "\(store.rejectedGPSCount) 个")
                toolRow("定位错误", "\(store.gpsErrorCount) 次")
                toolRow("数据恢复来源", store.gpsRecoveredFromBackup ? "备用快照" : "主数据或新建")
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
                .padding(.top, 8)
            } label: {
                Label("行程诊断", systemImage: "waveform.path.ecg")
            }
            .padding(16)
            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 18))
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
            Button { selectedTab = 1 } label: {
                VStack(spacing: 5) {
                    Image(systemName: "map.fill").font(.system(size: 20))
                    Text("轨迹").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(selectedTab == 1 ? Color.white : Cockpit.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selectedTab == 1 ? Cockpit.blue : Color.clear, in: RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain)
            tab("工具", "wrench.and.screwdriver.fill", index: 2)
            tab("记录", "doc.text.fill", index: 3)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10).padding(.bottom, 7)
        .background(Cockpit.panel)
        .overlay(alignment: .top) { Rectangle().fill(Cockpit.blue.opacity(0.16)).frame(height: 1) }
    }
    private func tab(_ label: String, _ icon: String, index: Int) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selectedTab == index ? Color.white : Cockpit.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selectedTab == index ? Cockpit.blue : Color.clear, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
    private func liveMap(_ shift: Shift) -> some View {
        NavigationLink {
            RouteDetail(shift: shift)
        } label: {
            ZStack(alignment: .bottomLeading) {
                TripRouteMap(shift: shift)
                    .frame(height: max(460, UIScreen.main.bounds.height * 0.68))
                    .allowsHitTesting(false)
                Label("今日行驶轨迹 · 点击查看", systemImage: "location.fill")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .foregroundStyle(Cockpit.blue)
                    .background(Cockpit.panel.opacity(0.94), in: Capsule())
                    .overlay(Capsule().stroke(Cockpit.blue.opacity(0.28), lineWidth: 1))
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Cockpit.blue.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
    private func mileageCard(_ shift: Shift) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("全天累计里程", systemImage: "car.side.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Image(systemName: "location.north.line.fill")
                    .foregroundStyle(.white.opacity(0.9))
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(String(format: "%.2f", shift.kilometers))
                    .font(.system(size: 55, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("km").font(.system(size: 19, weight: .medium)).foregroundStyle(.white.opacity(0.82))
            }
            Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color(red: 0.53, green: 1, blue: 0.78))
                Text(store.gpsStatus).foregroundStyle(.white)
                Spacer()
                Text(store.motionStatus).foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(22)
        .background(
            LinearGradient(colors: [Color(red: 0.07, green: 0.43, blue: 0.92), Color(red: 0.04, green: 0.26, blue: 0.63), Color(red: 0.02, green: 0.15, blue: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 25)
        )
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(.white.opacity(0.24), lineWidth: 1))
        .shadow(color: Cockpit.blue.opacity(0.22), radius: 14, y: 7)
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
            let restSeconds = max(0, now.timeIntervalSince(shift.started) - totals.passenger)
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
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                Text(label)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                Text(unit).font(.system(size: 12, weight: .semibold)).opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(15)
        .background(
            LinearGradient(colors: [tint, tint.opacity(0.88), tint.opacity(0.70)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.28), lineWidth: 1))
        .shadow(color: tint.opacity(0.25), radius: 10, y: 5)
    }
    private var controls: some View {
        VStack(spacing: 10) {
            if riding {
                action("乘客下车", symbol: "checkmark.flag.fill", color: .orange) { store.endRide() }
            } else {
                action("乘客上车", symbol: "person.fill", color: Cockpit.blue) { store.startRide() }
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
        .foregroundStyle(.primary)
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
            HStack(alignment: .center, spacing: 10) {
                Label("历史日报", systemImage: "calendar.badge.clock")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Cockpit.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text("\(store.history.count) 条")
                    .font(.caption).foregroundStyle(Cockpit.muted)
                    .fixedSize()
                Button(selectingHistory ? "取消" : "批量删除") {
                    selectingHistory.toggle()
                    selectedHistoryIDs.removeAll()
                }
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
            }
            HStack(spacing: 10) {
                TextField("搜索日期、备注、流水", text: $historySearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 0)
                    .autocorrectionDisabled()
                Picker("时间", selection: $historyPeriod) {
                    Text("全部").tag(0)
                    Text("本周").tag(1)
                    Text("本月").tag(2)
                    Text("今年").tag(3)
                }.pickerStyle(.menu)
            }
            let filteredHistory = store.history.filter { item in
                let calendar = Calendar.current
                let periodMatches: Bool
                switch historyPeriod {
                case 1: periodMatches = calendar.isDate(item.started, equalTo: Date(), toGranularity: .weekOfYear)
                case 2: periodMatches = calendar.isDate(item.started, equalTo: Date(), toGranularity: .month)
                case 3: periodMatches = calendar.isDate(item.started, equalTo: Date(), toGranularity: .year)
                default: periodMatches = true
                }
                let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
                let searchMatches = query.isEmpty ||
                    item.started.formatted(date: .numeric, time: .omitted).localizedCaseInsensitiveContains(query) ||
                    item.notes.localizedCaseInsensitiveContains(query) ||
                    item.revenue.localizedCaseInsensitiveContains(query)
                return periodMatches && searchMatches
            }
            if !store.history.isEmpty {
                HStack {
                    Text("筛选结果：\(filteredHistory.count) 条")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(format: "合计 %.1f km", filteredHistory.reduce(0) { $0 + $1.kilometers }))
                        Text(String(format: "流水 ¥%.2f · %d 单",
                                    filteredHistory.compactMap { Double($0.revenue.trimmingCharacters(in: .whitespacesAndNewlines)) }.reduce(0, +),
                                    filteredHistory.reduce(0) { $0 + $1.completedOrders }))
                    }
                }.font(.caption).foregroundStyle(Cockpit.muted)
            }
            if !store.history.isEmpty && filteredHistory.isEmpty {
                Text("没有符合条件的历史行程").font(.caption).foregroundStyle(Cockpit.muted)
            }
            if store.history.isEmpty {
                Text("还没有历史记录，结束出车后会自动保存在这里。")
                    .font(.subheadline).foregroundStyle(Cockpit.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 16))
            }
            if !filteredHistory.isEmpty {
                Button {
                    gpxExport = store.exportHistoryCSV(filteredHistory)
                } label: {
                    Label("导出当前筛选结果 CSV", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if selectingHistory && !filteredHistory.isEmpty {
                HStack {
                    Button("全选筛选结果") {
                        selectedHistoryIDs.formUnion(filteredHistory.map { $0.id })
                    }
                    Spacer()
                    Text("已选 \(selectedHistoryIDs.count) 条")
                    Button("删除") { confirmBatchDelete = true }
                        .foregroundStyle(.red)
                        .disabled(selectedHistoryIDs.isEmpty)
                }
                .font(.subheadline)
                .padding(12)
                .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            let historyDays = Dictionary(grouping: filteredHistory) { Calendar.current.startOfDay(for: $0.started) }
            ForEach(historyDays.keys.sorted(by: >), id: \.self) { day in
                let dayKey = String(Int(day.timeIntervalSince1970))
                let entries = historyDays[day] ?? []
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedHistoryDays.contains(dayKey) },
                    set: { if $0 { expandedHistoryDays.insert(dayKey) } else { expandedHistoryDays.remove(dayKey) } }
                )) {
                    LazyVStack(spacing: 10) {
            ForEach(entries) { item in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        if selectingHistory {
                            Button {
                                if selectedHistoryIDs.contains(item.id) { selectedHistoryIDs.remove(item.id) }
                                else { selectedHistoryIDs.insert(item.id) }
                            } label: {
                                Image(systemName: selectedHistoryIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(Cockpit.blue)
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            if selectingHistory {
                                if selectedHistoryIDs.contains(item.id) { selectedHistoryIDs.remove(item.id) }
                                else { selectedHistoryIDs.insert(item.id) }
                            } else { detailShift = item }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.started.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.headline).foregroundStyle(.primary)
                                Text("\(item.completedOrders) 单 · " + String(format: "%.2f km", item.kilometers))
                                    .font(.subheadline).foregroundStyle(Cockpit.muted)
                                Text(item.revenue.isEmpty ? "流水未填写" : "流水 ¥" + item.revenue)
                                    .font(.subheadline.bold()).foregroundStyle(Cockpit.green)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        if !selectingHistory {
                            Button(role: .destructive) { deletionTarget = item.id } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                                    .frame(width: 38, height: 38)
                            }
                        }
                    }
                    if !selectingHistory {
                        HStack(spacing: 8) {
                            Button { detailShift = item } label: {
                                Label("日报", systemImage: "doc.text")
                                    .frame(maxWidth: .infinity)
                            }
                            NavigationLink { ShareJourneyCard(shift: item) } label: {
                                Label("分享卡", systemImage: "rectangle.portrait.on.rectangle.portrait")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { historyRoute = item } label: {
                                Label("轨迹", systemImage: "map")
                                    .frame(maxWidth: .infinity)
                            }
                            ShareLink(item: store.report(item)) {
                                Label("分享", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(Cockpit.blue)
                        .buttonStyle(.plain)
                        .padding(.vertical, 9)
                        .background(Cockpit.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(14)
                .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 16))
            }
                    }
                } label: {
                    HStack {
                        Text(day.formatted(.dateTime.year().month().day())).font(.headline)
                        Spacer()
                        Text("\(entries.count) 条 · " + String(format: "%.2f km", entries.reduce(0) { $0 + $1.kilometers }))
                            .font(.caption).foregroundStyle(Cockpit.muted)
                    }
                }
                .padding(14)
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
    var playbackCoordinate: CLLocationCoordinate2D? = nil
    var satelliteMode: Bool = false
    var interactive3D: Bool = false
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .unspecified
        map.showsCompass = true
        map.mapType = satelliteMode ? .hybrid : .standard
        map.showsUserLocation = true // Blue dot: live Core Location, distinct from stored trip start/end pins.
        map.isRotateEnabled = interactive3D
        map.isPitchEnabled = interactive3D
        let shenzhen = CLLocationCoordinate2D(latitude: 22.60, longitude: 114.05)
        map.setRegion(MKCoordinateRegion(center: shenzhen, span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.65)), animated: false)
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let desiredMapType: MKMapType = satelliteMode ? .hybrid : .standard
        if map.mapType != desiredMapType { map.mapType = desiredMapType }
        map.isRotateEnabled = interactive3D
        map.isPitchEnabled = interactive3D
        // Passenger boundaries can change without a new GPS point; invalidate
        // the rendered route whenever pickup/dropoff timestamps change.
        let rideSignature = shift.rides.map {
            "\($0.id.uuidString):\($0.started.timeIntervalSince1970):\($0.ended?.timeIntervalSince1970 ?? -1)"
        }.joined(separator: "|")
        let latestPointTime = shift.points.last?.date.timeIntervalSince1970 ?? 0
        let coordinator = context.coordinator
        if let playbackCoordinate {
            if coordinator.playbackPin == nil {
                let pin = MKPointAnnotation()
                pin.title = "回放车辆"
                coordinator.playbackPin = pin
                map.addAnnotation(pin)
            }
            coordinator.playbackPin?.coordinate = playbackCoordinate
            // Overview playback: the vehicle moves while the map stays fixed.
            // The full recorded route remains visible at the original framing.
        } else if let pin = coordinator.playbackPin {
            map.removeAnnotation(pin)
            coordinator.playbackPin = nil
        }
        guard coordinator.lastCount != shift.points.count ||
              coordinator.shiftID != shift.id ||
              coordinator.lastRideSignature != rideSignature ||
              coordinator.lastPointTime != latestPointTime else { return }
        coordinator.lastCount = shift.points.count
        coordinator.shiftID = shift.id
        coordinator.lastRideSignature = rideSignature
        coordinator.lastPointTime = latestPointTime
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { $0 !== coordinator.playbackPin })
        let points = shift.points.filter {
            (-90...90).contains($0.lat) && (-180...180).contains($0.lon)
        }
        // Use Apple's native map as the reference coordinate layer for GPS routes.
        // Third-party MBTiles can use a different coordinate datum (e.g. GCJ-02)
        // and visually shift roads away from WGS-84 Core Location points.
        // Keep the installed offline database untouched; do not overlay it here
        // until its coordinate system has been independently verified.
        guard !points.isEmpty else { return }
        // 分段绘制：载客为绿色，其余为蓝色；定位时间间隔过长则断开，不画跨城直线。
        var segment: [CLLocationCoordinate2D] = []
        var segmentPassenger = false
        var previousDate: Date?
        var previousCoordinate: CLLocationCoordinate2D?
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
            let coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
            let elapsed = previousDate.map { p.date.timeIntervalSince($0) } ?? 0
            let jumped = previousCoordinate.map { previous in
                elapsed > 0 && CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: p.lat, longitude: p.lon)) / elapsed >= 50
            } ?? false
            // A discontinuity is not a driven road. Never draw a straight
            // connector across a GPS gap, reversed timestamp or impossible jump.
            if p.segmentStart || elapsed > 8 || (previousDate != nil && elapsed <= 0) || jumped {
                flush()
                segmentPassenger = passenger
            } else if passenger != segmentPassenger {
                // Keep the boundary coordinate so the color changes without
                // leaving a visual gap between empty and passenger mileage.
                let boundary = segment.last
                flush()
                segmentPassenger = passenger
                if let boundary { segment.append(boundary) }
            }
            segment.append(coordinate)
            previousCoordinate = coordinate
            previousDate = p.date
        }
        flush()
        let first = MKPointAnnotation()
        first.title = "起点"
        first.coordinate = CLLocationCoordinate2D(latitude: points[0].lat, longitude: points[0].lon)
        if points.count == 1 {
            // One GPS sample cannot describe a route or a current position.
            // Avoid overlapping "start" and "latest" pins that mislead the driver.
            map.addAnnotation(first)
            let region = MKCoordinateRegion(center: first.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012))
            if !coordinator.hasFramedRoute { map.setRegion(region, animated: false); coordinator.hasFramedRoute = true }
        } else {
            map.addAnnotation(first)
            // Do not mark framing complete here: two endpoints alone can hide
            // the bends of a multi-point trip. Fit the full track below.
            if points.count == 2 && !coordinator.hasFramedRoute {
                map.showAnnotations([first], animated: false)
                coordinator.hasFramedRoute = true
            }
        }
        if points.count > 2 {
            let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let poly = MKPolyline(coordinates: coords, count: coords.count)
            let rect = poly.boundingMapRect
            if !rect.isNull && !coordinator.hasFramedRoute {
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 65, left: 40, bottom: 65, right: 40), animated: false)
                coordinator.hasFramedRoute = true
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastCount = -1
        var playbackPin: MKPointAnnotation?
        var hasFramedRoute = false
        var shiftID: UUID?
        var lastRideSignature = ""
        var lastPointTime: TimeInterval = -1
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation === playbackPin else { return nil }
            let reuseID = "CarTripReplayVehicle"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation = annotation
            view.markerTintColor = .systemOrange
            view.glyphImage = UIImage(systemName: "car.fill")
            view.displayPriority = .required
            view.canShowCallout = true
            return view
        }
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
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .padding(11)
        .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(color.opacity(0.23), lineWidth: 1))
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
                TripRouteMap(shift: shift, interactive3D: true)
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                Text("直接在地图上双指缩放、旋转、倾斜；单指拖动")
                    .font(.system(size: 11))
                    .foregroundStyle(Cockpit.muted)
                HStack(spacing: 12) {
                    Label("全天轨迹", systemImage: "line.diagonal").foregroundStyle(Cockpit.blue)
                    Label("载客路段", systemImage: "line.diagonal").foregroundStyle(Cockpit.green)
                    Spacer()
                    Text("\(shift.points.count) 点").foregroundStyle(Cockpit.muted)
                }.font(.system(size: 11))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    tile("全天总里程", String(format: "%.2f km", shift.kilometers), Cockpit.blue)
                    tile("完成订单", "\(shift.completedOrders) 单", Cockpit.green)
                    tile("载客里程", String(format: "%.2f km", shift.passengerKM), Cockpit.blue)
                    tile("空驶里程", String(format: "%.2f km", max(0, shift.kilometers - shift.passengerKM)), .orange)
                    tile("总休息时间", clock(max(0, end.timeIntervalSince(shift.started) - totals.passenger)), .purple)
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
        .preferredColorScheme(ThemePreference.scheme(UserDefaults.standard.string(forKey: "cartrip.appearance") ?? "auto"))
    }
}
private struct HistoryReportDetail: View {
    let shift: Shift
    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 3600, (total / 60) % 60)
    }
    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(Cockpit.muted)
            Spacer(minLength: 12)
            Text(value).fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
    private func panel<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline).foregroundStyle(Cockpit.blue)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 16))
    }
    var body: some View {
        let end = shift.ended ?? Date()
        let totals = shift.timeTotals(at: end)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(shift.started.formatted(date: .complete, time: .omitted))
                    .font(.title2.bold())
                panel("今日流水") {
                    Text(shift.revenue.isEmpty ? "未填写" : "¥" + shift.revenue)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Cockpit.green)
                }
                panel("行程概览") {
                    row("出车时间", shift.started.formatted(date: .omitted, time: .shortened))
                    row("收车时间", end.formatted(date: .omitted, time: .shortened))
                    row("出车总时长", clock(end.timeIntervalSince(shift.started)))
                    row("完成订单", "\(shift.completedOrders) 单")
                    row("全天总里程", String(format: "%.2f km", shift.kilometers))
                    row("载客里程", String(format: "%.2f km", shift.passengerKM))
                    row("空驶里程", String(format: "%.2f km", max(0, shift.kilometers - shift.passengerKM)))
                }
                panel("时间分布") {
                    row("载客时间", clock(totals.passenger))
                    row("空驶时间", clock(totals.empty))
                    row("等待时间", clock(totals.waiting))
                    row("吃饭休息", clock(totals.meal))
                    row("充电休息", clock(totals.charging))
                    row("其他休息", clock(totals.other))
                    row("总休息时间", clock(max(0, end.timeIntervalSince(shift.started) - totals.passenger - totals.empty)))
                }
                if !shift.notes.isEmpty {
                    panel("备注") { Text(shift.notes).font(.subheadline) }
                }
            }
            .padding(16)
        }
        .background(Cockpit.background)
    }
}
private struct FullscreenJourneyMap: View {
    let shift: Shift
    @State private var satellite = false
    @State private var revision = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("双指缩放、旋转、倾斜")
                    .font(.caption).foregroundStyle(Cockpit.muted)
                Spacer()
                Button(satellite ? "标准" : "卫星") { satellite.toggle() }
                Button("全程") { revision = UUID() }
            }
            .padding(12)
            TripRouteMap(shift: shift, satelliteMode: satellite, interactive3D: true)
                .id(revision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Label("空驶", systemImage: "line.diagonal").foregroundStyle(.blue)
                Label("载客", systemImage: "line.diagonal").foregroundStyle(.green)
                Spacer()
                Text("\(shift.points.count) GPS点").foregroundStyle(Cockpit.muted)
            }
            .font(.caption).padding(12)
        }
        .background(Cockpit.background)
        .navigationTitle("完整轨迹地图")
        .navigationBarTitleDisplayMode(.inline)
    }
}
private struct RouteDetail: View {
    var embedded = false
    @EnvironmentObject private var store: TripStore
    private let initialShift: Shift
    init(shift: Shift, embedded: Bool = false) {
        self.initialShift = shift
        self.embedded = embedded
    }
    // NavigationLink captures a value snapshot. Read the current published
    // shift on every render so GPS points keep updating while this page stays open.
    private var shift: Shift {
        if let live = store.active, live.id == initialShift.id { return live }
        return store.history.first(where: { $0.id == initialShift.id }) ?? initialShift
    }
    // Compare Apple's live location with the latest stored route fix.
    // This makes stale background GPS and coordinate drift distinguishable.
    private var routeGPSCheck: String {
        guard let saved = shift.points.last else { return "轨迹诊断：尚无保存的 GPS 点" }
        let age = max(0, Int(Date().timeIntervalSince(saved.date)))
        // Compare the same Core Location feed used by TripStore with the
        // stored endpoint. MKMapView's blue dot has its own location pipeline.
        guard let live = store.latestGPSLocation,
              live.horizontalAccuracy > 0,
              abs(live.timestamp.timeIntervalSinceNow) <= 30 else {
            return "轨迹诊断：终点距今\(age)秒 · 暂无新鲜的记录器 GPS"
        }
        let savedLocation = CLLocation(latitude: saved.lat, longitude: saved.lon)
        let separation = Int(live.distance(from: savedLocation).rounded())
        return "轨迹诊断：记录器定位与轨迹终点相差\(separation)米 · 终点距今\(age)秒 · 精度±\(Int(live.horizontalAccuracy))米"
    }
    private var routeLengthCheck: String {
        let points = shift.points
        guard points.count > 1 else { return "轨迹路径：有效点不足，无法估算" }
        var meters = 0.0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let seconds = b.date.timeIntervalSince(a.date)
            if b.segmentStart || seconds <= 0 || seconds > 8 { continue }
            let start = CLLocation(latitude: a.lat, longitude: a.lon)
            let end = CLLocation(latitude: b.lat, longitude: b.lon)
            let distance = end.distance(from: start)
            if distance / seconds >= 50 { continue }
            meters += distance
        }
        let gaps = (1..<points.count).filter {
            points[$0].date.timeIntervalSince(points[$0 - 1].date) > 8
        }.count
        return String(format: "连续GPS折线约%.2f公里 · 已计入%.2f公里 · %d点 · 定位间隔>8秒共%d次（折线含漂移，不是实际里程）", meters / 1000, shift.kilometers, points.count, gaps)
    }
    private var routeQualityCheck: String {
        let points = shift.points
        guard !points.isEmpty else { return "轨迹质量：尚无定位点" }
        let accurate = points.filter { $0.accuracy > 0 && $0.accuracy <= 20 }.count
        let weak = points.filter { $0.accuracy > 35 }.count
        let segments = points.filter { $0.segmentStart }.count
        let gaps = zip(points, points.dropFirst()).filter {
            $1.date.timeIntervalSince($0.date) > 8
        }.count
        return String(format: "轨迹质量：精度≤20米 %d/%d点 · 精度>35米 %d点 · 分段 %d次 · 间隔>8秒 %d次", accurate, points.count, weak, segments, gaps)
    }
    @State private var importMap = false
    @State private var mapRevision = 0
    @StateObject private var mapDownload = ShenzhenMapDownload()
    @State private var mapError: String?
    @State private var showDiagnostics = false
    @State private var replayRunning = false
    @State private var replayMode = false
    @State private var replaySpeed = -30
    // Positive values are real-time multipliers; negative values are target
    // completion seconds, independent of the recorded trip duration.
    private var effectiveReplaySpeed: Double {
        replaySpeed > 0 ? Double(replaySpeed) : max(1, replayDuration / Double(-replaySpeed))
    }
    @AppStorage("cartrip.routeMapProvider") private var routeMapProvider = "baidu"
    @AppStorage("cartrip.baiduPrivacyConsent") private var baiduPrivacyConsent = false
    @State private var satelliteMode = false
    @AppStorage("cartrip.followVehicle") private var followVehicle = false
    // Replay uses recorded timestamps, not the number of GPS points.
    // A missing GPS second is never presented as a genuine recorded fix.
    @State private var replayElapsed: TimeInterval = 0
    private let replayTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    @State private var replayLastTick: Date? = nil
    private var replayCount: Int { shift.points.count }
    private var replayDuration: TimeInterval {
        guard let first = shift.points.first, let last = shift.points.last else { return 0 }
        return max(0, last.date.timeIntervalSince(first.date))
    }
    private var replayIndex: Int {
        guard let first = shift.points.first else { return 0 }
        let target = first.date.addingTimeInterval(replayElapsed)
        // Binary search: replay remains responsive for long 1 Hz trips.
        var low = 0
        var high = shift.points.count
        while low < high {
            let mid = low + (high - low) / 2
            if shift.points[mid].date <= target { low = mid + 1 }
            else { high = mid }
        }
        return max(0, low - 1)
    }
    private var playbackCoordinate: CLLocationCoordinate2D? {
        guard replayMode, !shift.points.isEmpty else { return nil }
        let index = replayIndex
        let a = shift.points[index]
        let from = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
        guard index + 1 < shift.points.count else { return from }
        let b = shift.points[index + 1]
        let interval = b.date.timeIntervalSince(a.date)
        // Interpolation is display-only. Never invent or persist GPS fixes.
        guard !b.segmentStart, interval > 0, interval <= 8 else { return from }
        let start = CLLocation(latitude: a.lat, longitude: a.lon)
        let end = CLLocation(latitude: b.lat, longitude: b.lon)
        guard end.distance(from: start) / interval < 50 else { return from }
        let target = shift.points[0].date.addingTimeInterval(replayElapsed)
        let fraction = max(0, min(1, target.timeIntervalSince(a.date) / interval))
        return CLLocationCoordinate2D(latitude: a.lat + (b.lat - a.lat) * fraction,
                                      longitude: a.lon + (b.lon - a.lon) * fraction)
    }
    private var replayShift: Shift {
        var partial = shift
        partial.points = Array(shift.points.prefix(min(replayCount, max(1, replayIndex + 1))))
        return partial
    }
    @ViewBuilder private var replayControls: some View {
        if replayCount > 1 {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button(replayRunning ? "暂停" : "播放") {
                        if replayElapsed >= replayDuration { replayElapsed = 0 }
                        replayMode = true
                        replayLastTick = nil
                        replayRunning.toggle()
                    }
                    .buttonStyle(.borderedProminent)

                    Picker("回放时长", selection: $replaySpeed) {
                        Text("60秒看完").tag(-60)
                        Text("30秒看完").tag(-30)
                        Text("20秒看完").tag(-20)
                    }
                    .pickerStyle(.menu)
                    .tint(Cockpit.blue)

                    Spacer(minLength: 0)
                    Button("重置") {
                        replayRunning = false
                        replayElapsed = 0
                        replayMode = false
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.regular)

                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { replayElapsed },
                        set: { replayMode = true; replayElapsed = $0; replayRunning = false }
                    ), in: 0...max(1, replayDuration))
                    Text(!replayMode ? "完整路线" :
                        shift.points[min(replayIndex, replayCount - 1)].date.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 6)
        }
    }
    var body: some View {
        VStack(spacing: 0) {

            Picker("地图来源", selection: $routeMapProvider) {
                Text("苹果地图").tag("apple")
                Text("百度地图").tag("baidu")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, embedded ? 10 : 12)
            .padding(.bottom, 12)
            .background(Cockpit.background)
            if routeMapProvider == "baidu" && baiduPrivacyConsent && BaiduRouteMap.isConfigured {
                Toggle("跟随车辆", isOn: $followVehicle)
                    .font(.caption).padding(.horizontal, 14)
            }
            if routeMapProvider == "baidu" && !baiduPrivacyConsent {
                Button("同意百度地图SDK隐私政策并启用百度地图") {
                    baiduPrivacyConsent = true
                }
                .font(.caption).padding(10)
            }
            if routeMapProvider == "baidu" && !BaiduRouteMap.isConfigured {
                Text("百度地图AK未配置，自动使用苹果地图").font(.caption).foregroundStyle(Cockpit.muted)
            }
            Group {
                if routeMapProvider == "baidu" && baiduPrivacyConsent && BaiduRouteMap.isConfigured {
                    BaiduRouteMap(shift: replayMode ? replayShift : shift,
                                  playbackCoordinate: playbackCoordinate,
                                  followVehicle: followVehicle,
                                  replayActive: replayMode,
                                  liveCoordinate: store.latestGPSLocation?.coordinate)
                } else {
                    TripRouteMap(shift: replayMode ? replayShift : shift,
                                 playbackCoordinate: playbackCoordinate,
                                 satelliteMode: satelliteMode)
                }
            }
                .id(mapRevision)
                .frame(maxWidth: .infinity)
                .frame(height: embedded ? 240 : 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Cockpit.blue.opacity(0.12), lineWidth: 1)
                }
                .padding(.horizontal, 14)
                .overlay(alignment: .topTrailing) {
                    if !replayMode {
                        Text(store.gpsSpeed.map { String(format: "%.0f km/h", $0) } ?? "-- km/h")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .padding(22)
                    }
                }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button(satelliteMode ? "标准地图" : "卫星地图") { satelliteMode.toggle() }
                        .font(.caption.bold())
                    Spacer(minLength: 8)
                    Text(OfflineMap.file == nil ? "在线地图 · 离线包未下载" : "深圳离线道路图已安装")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                HStack(spacing: 14) {
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
                    if OfflineMap.file == nil {
                        Link(destination: URL(string: "https://github.com/tu134186/CarTripAssistant/releases/tag/shenzhen-map-v1")!) {
                            Label("浏览器下载", systemImage: "safari")
                        }.font(.caption.bold())
                    }
                    Spacer(minLength: 0)
                }
            }.padding(.horizontal, 15).padding(.top, 10)
            if mapDownload.downloading {
                ProgressView(value: mapDownload.progress).padding(.horizontal, 15)
                Text("下载深圳地图：\(Int(mapDownload.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = mapDownload.errorMessage {
                VStack(alignment: .leading, spacing: 7) {
                    Text(message).font(.caption).foregroundStyle(.red)
                    Text("若 APP 内下载失败，可点「浏览器下载」，在 GitHub 下载 .mbtiles 文件，再返回本页点「导入」。不要导入 ZIP。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("重试下载") { mapDownload.start { mapRevision += 1 } }
                        .font(.caption.bold())
                }.padding(.horizontal, 15)
            }
            DisclosureGroup(isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(routeQualityCheck)
                    Text(routeLengthCheck)
                    Text(routeGPSCheck)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                Label("GPS 轨迹诊断", systemImage: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Cockpit.blue)
            }
            .padding(13)
            .background(Cockpit.panel, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            replayControls
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
                if shift.points.count < 2 {
                    Text("当前仅记录到 \(shift.points.count) 个 GPS 点：红色图钉是行程起点，不代表实时位置；地图蓝点才是手机当前定位。请等待 GPS 更新。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("蓝线是记录的 GPS 轨迹，绿线按乘客上下车时间标记。定位断点、步行点和漂移可能影响地图及里程。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Cockpit.background)
        .fileImporter(isPresented: $importMap, allowedContentTypes: [.data, .item]) { outcome in
            switch outcome {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard url.pathExtension.lowercased() == "mbtiles" else {
                        throw NSError(domain: "OfflineMap", code: 3, userInfo: [NSLocalizedDescriptionKey: "请选择解压后的 .mbtiles 地图文件，不要选择 ZIP 压缩包"])
                    }
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
        .navigationTitle(embedded ? "" : "行驶足迹")
        .toolbar(embedded ? .hidden : .visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(ThemePreference.scheme(UserDefaults.standard.string(forKey: "cartrip.appearance") ?? "auto"))
        .onReceive(replayTimer) { now in
            guard replayRunning else {
                replayLastTick = nil
                return
            }
            let delta = replayLastTick.map { max(0, min(2, now.timeIntervalSince($0))) } ?? 0.1
            replayLastTick = now
            replayElapsed = min(replayDuration, replayElapsed + delta * effectiveReplaySpeed)
            if replayElapsed >= replayDuration {
                replayRunning = false
                replayLastTick = nil
            }
        }
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
        let bytes = (try? fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes >= 4096 else {
            try? fm.removeItem(at: temp)
            throw NSError(domain: "OfflineMap", code: 5, userInfo: [NSLocalizedDescriptionKey: "文件过小（\(bytes) 字节），可能是下载失败保存的网页，不是地图数据库"])
        }
        // SQLite files must start with this exact 16-byte header.
        let header = try FileHandle(forReadingFrom: temp)
        let prefix = header.readData(ofLength: 16)
        try header.close()
        guard prefix == Data("SQLite format 3\0".utf8) else {
            try? fm.removeItem(at: temp)
            throw NSError(domain: "OfflineMap", code: 6, userInfo: [NSLocalizedDescriptionKey: "不是 SQLite MBTiles 数据库。请确认下载的是 .mbtiles 文件，而不是 ZIP 或网页"])
        }
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
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 1800
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
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
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw NSError(domain: "ShenzhenMap", code: status, userInfo: [NSLocalizedDescriptionKey: "下载服务器返回 HTTP \(status)。可尝试在 GitHub Release 页面下载后手动导入。"])
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 1024 * 1024 else {
                throw NSError(domain: "ShenzhenMap", code: 4, userInfo: [NSLocalizedDescriptionKey: "下载文件只有 \(size) 字节，可能是网页或下载未完成，并非完整地图。"])
            }
            try OfflineMap.install(location)
            DispatchQueue.main.async {
                self.downloading = false
                self.progress = 1
                self.completion?()
                self.completion = nil
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "地图安装失败：" + error.localizedDescription
                self.downloading = false
                self.completion = nil
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let error = error, (error as NSError).code != NSURLErrorCancelled {
                self.errorMessage = "地图下载失败：" + error.localizedDescription
                self.downloading = false
                self.completion = nil
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
