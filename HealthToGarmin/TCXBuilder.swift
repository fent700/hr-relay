import Foundation
import HealthKit
import CoreLocation

/// Builds a Garmin Training Center (.tcx) file, which Garmin Connect accepts for upload.
enum TCXBuilder {
    private struct Point {
        var time: Date
        var lat: Double? = nil
        var lon: Double? = nil
        var alt: Double? = nil
        var dist: Double? = nil
        var hr: Int? = nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func build(for w: HKWorkout) async -> Data {
        let hk = HealthKitManager.shared
        let hr = (try? await hk.heartRates(for: w)) ?? []
        let locs = ((try? await hk.locations(for: w)) ?? [])
            .filter { $0.timestamp >= w.startDate && $0.timestamp <= w.endDate && $0.horizontalAccuracy >= 0 }
        let totalDistance = hk.totalDistanceMeters(w)
        let kcal = hk.activeKilocalories(w)

        var points: [Point] = []
        if !locs.isEmpty {
            var cumulative = 0.0
            var prev: CLLocation?
            for l in locs {
                if let p = prev { cumulative += l.distance(from: p) }
                prev = l
                points.append(Point(time: l.timestamp,
                                    lat: l.coordinate.latitude,
                                    lon: l.coordinate.longitude,
                                    alt: l.verticalAccuracy >= 0 ? l.altitude : nil,
                                    dist: cumulative))
            }
            // Attach the most recent heart-rate reading (within 60 s) to each GPS point.
            var i = 0
            for k in points.indices {
                while i + 1 < hr.count && hr[i + 1].date <= points[k].time { i += 1 }
                if i < hr.count, hr[i].date <= points[k].time,
                   points[k].time.timeIntervalSince(hr[i].date) <= 60 {
                    points[k].hr = Int(hr[i].bpm.rounded())
                }
            }
        } else {
            points = hr.map { Point(time: $0.date, hr: Int($0.bpm.rounded())) }
            // No GPS (treadmill, indoor ride…): spread distance across the workout so totals match.
            if totalDistance > 0 {
                let span = max(w.endDate.timeIntervalSince(w.startDate), 1)
                for k in points.indices {
                    let frac = min(max(points[k].time.timeIntervalSince(w.startDate) / span, 0), 1)
                    points[k].dist = totalDistance * frac
                }
            }
        }

        // Garmin rejects files without trackpoints; make sure start and end exist.
        let noGPSDist: Double? = totalDistance > 0 ? 0 : nil
        if points.first.map({ $0.time > w.startDate }) ?? true {
            points.insert(Point(time: w.startDate, dist: locs.isEmpty ? noGPSDist : 0), at: 0)
        }
        if points.last.map({ $0.time < w.endDate }) ?? true {
            let endDist = locs.isEmpty ? (totalDistance > 0 ? totalDistance : nil) : points.last?.dist
            points.append(Point(time: w.endDate, dist: endDist))
        }

        let lapDistance = totalDistance > 0 ? totalDistance : (points.compactMap(\.dist).last ?? 0)
        let hrValues = points.compactMap(\.hr)
        let source = w.sourceRevision.source.name

        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <Activities>
            <Activity Sport="\(w.workoutActivityType.tcxSport)">
              <Id>\(iso.string(from: w.startDate))</Id>
              <Lap StartTime="\(iso.string(from: w.startDate))">
                <TotalTimeSeconds>\(fmt(w.duration, 1))</TotalTimeSeconds>
                <DistanceMeters>\(fmt(lapDistance, 1))</DistanceMeters>
                <Calories>\(Int(kcal.rounded()))</Calories>

        """
        if !hrValues.isEmpty {
            let avg = Double(hrValues.reduce(0, +)) / Double(hrValues.count)
            x += "          <AverageHeartRateBpm><Value>\(Int(avg.rounded()))</Value></AverageHeartRateBpm>\n"
            x += "          <MaximumHeartRateBpm><Value>\(hrValues.max()!)</Value></MaximumHeartRateBpm>\n"
        }
        x += """
                  <Intensity>Active</Intensity>
                  <TriggerMethod>Manual</TriggerMethod>
                  <Track>

        """
        for p in points {
            x += "            <Trackpoint><Time>\(iso.string(from: p.time))</Time>"
            if let lat = p.lat, let lon = p.lon {
                x += "<Position><LatitudeDegrees>\(fmt(lat, 7))</LatitudeDegrees><LongitudeDegrees>\(fmt(lon, 7))</LongitudeDegrees></Position>"
            }
            if let alt = p.alt { x += "<AltitudeMeters>\(fmt(alt, 1))</AltitudeMeters>" }
            if let d = p.dist { x += "<DistanceMeters>\(fmt(d, 1))</DistanceMeters>" }
            if let hr = p.hr { x += "<HeartRateBpm><Value>\(hr)</Value></HeartRateBpm>" }
            x += "</Trackpoint>\n"
        }
        x += """
                  </Track>
                </Lap>
                <Notes>\(escape("\(w.workoutActivityType.displayName) – exported from Apple Health (\(source))"))</Notes>
              </Activity>
            </Activities>
          </TrainingCenterDatabase>

          """
        return Data(x.utf8)
    }

    private static func fmt(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
