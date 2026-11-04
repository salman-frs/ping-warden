//
//  GeForceNOWStreamLog.swift
//  PingWarden
//
//  Reads finished streams out of the GeForce NOW client's own log. During a
//  stream the client measures its round trip to the server, reports packet
//  loss and dropped frames, and pings the local router every 100 ms, so its
//  log already holds what a stream recap needs. The format is NVIDIA's and
//  undocumented: anything missing or unrecognised is left out of the report
//  rather than guessed.
//

import Foundation

struct GeForceNOWStreamReport: Equatable, Sendable {
    struct VideoMode: Equatable, Sendable {
        let width: Int
        let height: Int
        let framesPerSecond: Int
    }

    /// The Wi-Fi link as the client saw it when the stream started.
    struct WiFiLink: Equatable, Sendable {
        let band: WiFiBand?
        let channel: Int?
        let linkRateMbps: Double?
    }

    let zoneCode: String
    let startedAt: Date
    var endedAt: Date
    var codec: String?
    var usesWiFi: Bool?
    var videoMode: VideoMode?
    var maximumBitrateMbps: Double?
    var averageRoundTripMs: Double?
    var worstRoundTripMs: Double?
    var packetLossPercent: Double?
    var frameDropPercent: Double?
    /// Share of the client's router pings that took longer than
    /// `routerSpikeThresholdMs`, which the client sets from its own baseline.
    var routerSpikePercent: Double?
    var routerSpikeThresholdMs: Double?
    var wifi: WiFiLink?

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    /// False when only the stream's start and end made it into the log.
    var hasMeasurements: Bool {
        averageRoundTripMs != nil || routerSpikePercent != nil || wifi != nil
    }
}

enum GeForceNOWStreamLog {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NVIDIA/GeForceNOW", isDirectory: true)

    /// The client starts a new log each time it launches and keeps the
    /// previous one as the backup.
    private static let logFileNames = ["geronimo.log.bak", "geronimo.log"]
    private static let readLimitBytes: UInt64 = 16 * 1024 * 1024

    static func latestReport(in directory: URL = defaultDirectory) -> GeForceNOWStreamReport? {
        logFileNames
            .compactMap { readTail(of: directory.appendingPathComponent($0)) }
            .flatMap(reports(in:))
            .max { $0.endedAt < $1.endedAt }
    }

    /// Every stream that both started and ended in `log`, plus any whose
    /// start fell before the log began but whose end is in it.
    static func reports(in log: String) -> [GeForceNOWStreamReport] {
        var parser = StreamLogParser()
        for line in log.split(separator: "\n") {
            parser.consume(line)
        }
        return parser.reports
    }

    private static func readTail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size > readLimitBytes ? size - readLimitBytes : 0)) != nil,
              let data = try? handle.readToEnd() else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct StreamLogParser {
    private struct OpenStream {
        let sessionID: String?
        var report: GeForceNOWStreamReport
        var averageRoundTrips: [Double] = []
        var worstRoundTrips: [Double] = []
        var packetLossPercents: [Double] = []
        var frameDropPercents: [Double] = []
    }

    private(set) var reports: [GeForceNOWStreamReport] = []
    private var openStream: OpenStream?
    /// The client announces the video mode and its bitrate ceiling just
    /// before the stream's start event.
    private var announcedMode: (mode: GeForceNOWStreamReport.VideoMode, bitrateMbps: Double)?

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    mutating func consume(_ line: Substring) {
        if let eventStart = line.range(of: "GsTelemetry::EventDump=") {
            consumeEvent(line[eventStart.upperBound...])
        } else if line.contains("recommended max bitrate: ") {
            consumeModeAnnouncement(line)
        } else if line.contains("Router ping stats: session spikes=") {
            openStream?.report.routerSpikePercent = Self.number(after: "spikePercent=", in: line)
            openStream?.report.routerSpikeThresholdMs = Self.number(after: "threshold=", in: line)
        }
    }

    private mutating func consumeEvent(_ json: Substring) {
        guard let event = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let name = event["name"] as? String,
              let parameters = event["parameters"] as? [String: Any],
              let timestamp = (event["ts"] as? String).flatMap(dateFormatter.date(from:)) else {
            return
        }
        let sessionID = parameters["sessionId"] as? String
        switch name {
        case "Streamer_Start":
            startStream(parameters, sessionID: sessionID, at: timestamp)
        case "Streamer_Exit":
            finishStream(parameters, sessionID: sessionID, at: timestamp)
        case "Nvst_RealTimeMetrics" where isOpenStream(sessionID):
            recordMetrics(parameters)
        case "System_WifiInterfaceInfo" where isOpenStream(sessionID) && openStream?.report.wifi == nil:
            openStream?.report.wifi = GeForceNOWStreamReport.WiFiLink(
                band: (parameters["band"] as? String).flatMap(WiFiBand.init(clientBandName:)),
                channel: Self.double(parameters["activeChannel"]).map { Int($0) },
                linkRateMbps: Self.double(parameters["maxTxRateMbps"])
            )
        default:
            break
        }
    }

    private func isOpenStream(_ sessionID: String?) -> Bool {
        openStream.map { $0.sessionID == sessionID } ?? false
    }

    private mutating func startStream(_ parameters: [String: Any], sessionID: String?, at timestamp: Date) {
        guard let zone = parameters["zoneAddress"] as? String, !zone.isEmpty else { return }
        var report = GeForceNOWStreamReport(zoneCode: zone, startedAt: timestamp, endedAt: timestamp)
        report.codec = parameters["codec"] as? String
        report.usesWiFi = (parameters["networkType"] as? String).map { $0.hasPrefix("WIFI") }
        report.videoMode = announcedMode?.mode
        report.maximumBitrateMbps = announcedMode?.bitrateMbps
        announcedMode = nil
        openStream = OpenStream(sessionID: sessionID, report: report)
    }

    private mutating func recordMetrics(_ parameters: [String: Any]) {
        if let value = Self.double(parameters["avgRoundTripDelayMs"]) { openStream?.averageRoundTrips.append(value) }
        if let value = Self.double(parameters["maxRoundTripDelayMs"]) { openStream?.worstRoundTrips.append(value) }
        if let value = Self.double(parameters["packetLossPercent"]) { openStream?.packetLossPercents.append(value) }
        if let value = Self.double(parameters["frameDropPercent"]) { openStream?.frameDropPercents.append(value) }
    }

    private mutating func finishStream(_ parameters: [String: Any], sessionID: String?, at timestamp: Date) {
        let streamDuration = Self.double(parameters["streamDuration"]).map { $0 / 1000 }
        let stream: OpenStream
        if let openStream, openStream.sessionID == sessionID {
            stream = openStream
        } else {
            guard let zone = parameters["zoneAddress"] as? String, !zone.isEmpty else { return }
            let startedAt = timestamp.addingTimeInterval(-(streamDuration ?? 0))
            stream = OpenStream(
                sessionID: sessionID,
                report: GeForceNOWStreamReport(zoneCode: zone, startedAt: startedAt, endedAt: timestamp)
            )
        }
        openStream = nil
        announcedMode = nil

        var report = stream.report
        report.endedAt = timestamp
        report.codec = report.codec ?? parameters["codec"] as? String
        report.usesWiFi = report.usesWiFi ?? (parameters["networkType"] as? String).map { $0.hasPrefix("WIFI") }
        report.averageRoundTripMs = Self.mean(stream.averageRoundTrips)
        report.worstRoundTripMs = stream.worstRoundTrips.max()
        report.packetLossPercent = Self.mean(stream.packetLossPercents)
        report.frameDropPercent = Self.mean(stream.frameDropPercents)
        reports.append(report)
    }

    /// "Mode: 2560x1600@60, recommended max bitrate: 42913" (kbps).
    private mutating func consumeModeAnnouncement(_ line: Substring) {
        guard let modeStart = line.range(of: "Mode: "),
              let kbps = Self.number(after: "recommended max bitrate: ", in: line) else {
            return
        }
        let modeText = line[modeStart.upperBound...].prefix { $0 != "," }
        let parts = modeText.split(whereSeparator: { $0 == "x" || $0 == "@" }).compactMap { Int($0) }
        guard parts.count == 3 else { return }
        announcedMode = (
            GeForceNOWStreamReport.VideoMode(width: parts[0], height: parts[1], framesPerSecond: parts[2]),
            kbps / 1000
        )
    }

    /// The number written right after `marker`, as in "spikePercent=7".
    private static func number(after marker: String, in line: Substring) -> Double? {
        guard let range = line.range(of: marker) else { return nil }
        return Double(line[range.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
