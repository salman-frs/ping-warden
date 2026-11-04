import Foundation
import XCTest
@testable import PingWardenCore

final class GeForceNOWStreamLogTests: XCTestCase {
    private static let session = "11111111-2222-3333-4444-555555555555"

    private static func event(_ name: String, _ parameters: String, ts: String, session: String = session) -> String {
        "[\(ts)]=00:00:00=    INFO [GridApp] {1} - GsTelemetry::EventDump={\"name\": \"\(name)\", \"parameters\" : "
            + "{\(parameters),\"sessionId\":\"\(session)\"}, \"ts\" : \"\(ts)\"} "
    }

    private static let completeStream = [
        "Starting logging",
        "[2026-11-02 20:37:14,065]=03:37:14=    INFO [NVST:NvscClientConfigDefaults] {1} -  Mode: 2560x1600@60, recommended max bitrate: 42913, client provided max bitrate: 0",
        event("Streamer_Start", #""zoneAddress":"NP-TYO-01","codec":"HEVC","networkType":"WIFI_5_0""#, ts: "2026-11-02T20:37:17.000Z"),
        event("System_WifiInterfaceInfo", #""band":"BAND_5_0_GHz","activeChannel":161,"maxTxRateMbps":43"#, ts: "2026-11-02T20:37:17.000Z"),
        event("Nvst_RealTimeMetrics", #""avgRoundTripDelayMs":87.0,"maxRoundTripDelayMs":100.0,"packetLossPercent":0.5,"frameDropPercent":0.0"#, ts: "2026-11-02T20:42:17.000Z"),
        event("Nvst_RealTimeMetrics", #""avgRoundTripDelayMs":89.0,"maxRoundTripDelayMs":610.0,"packetLossPercent":1.5,"frameDropPercent":2.0"#, ts: "2026-11-02T20:47:17.000Z"),
        event("Nvst_RealTimeMetrics", #""avgRoundTripDelayMs":10.0,"maxRoundTripDelayMs":900.0"#, ts: "2026-11-02T20:48:17.000Z", session: "other"),
        "[2026-11-02 21:27:01,274]=04:27:01=    INFO [SessionSpikeDetector] {1} - Router ping stats: session spikes=2003 totalRtt=29533 spikePercent=7 threshold=9.29 intervalMs=100",
        event("Streamer_Exit", #""zoneAddress":"NP-TYO-01","streamDuration":2986169,"codec":"HEVC""#, ts: "2026-11-02T21:27:01.000Z"),
    ].joined(separator: "\n")

    func testCompleteStreamCollectsEverythingTheClientMeasured() throws {
        let report = try XCTUnwrap(GeForceNOWStreamLog.reports(in: Self.completeStream).first)

        XCTAssertEqual(report.zoneCode, "NP-TYO-01")
        XCTAssertEqual(report.startedAt, ISO8601DateFormatter().date(from: "2026-11-02T20:37:17Z"))
        XCTAssertEqual(report.duration, 49 * 60 + 44, accuracy: 0.001)
        XCTAssertEqual(report.codec, "HEVC")
        XCTAssertEqual(report.usesWiFi, true)
        XCTAssertEqual(report.videoMode, .init(width: 2560, height: 1600, framesPerSecond: 60))
        XCTAssertEqual(try XCTUnwrap(report.maximumBitrateMbps), 42.913, accuracy: 0.0001)
        XCTAssertEqual(report.averageRoundTripMs, 88)
        XCTAssertEqual(report.worstRoundTripMs, 610)
        XCTAssertEqual(report.packetLossPercent, 1)
        XCTAssertEqual(report.frameDropPercent, 1)
        XCTAssertEqual(report.routerSpikePercent, 7)
        XCTAssertEqual(report.routerSpikeThresholdMs, 9.29)
        XCTAssertEqual(report.wifi, .init(band: .band5GHz, channel: 161, linkRateMbps: 43))
    }

    func testStreamWhoseStartWasRotatedAwayIsRebuiltFromItsExit() throws {
        let log = Self.event(
            "Streamer_Exit",
            #""zoneAddress":"NP-AMS-05","streamDuration":600000,"codec":"H264","networkType":"ETHERNET""#,
            ts: "2026-11-02T21:00:00.000Z"
        )

        let report = try XCTUnwrap(GeForceNOWStreamLog.reports(in: log).first)

        XCTAssertEqual(report.zoneCode, "NP-AMS-05")
        XCTAssertEqual(report.duration, 600, accuracy: 0.001)
        XCTAssertEqual(report.usesWiFi, false)
        XCTAssertNil(report.averageRoundTripMs)
        XCTAssertFalse(report.hasMeasurements)
    }

    func testUnfinishedStreamAndUnrecognisedLinesProduceNoReport() {
        let log = [
            "garbage",
            "[2026] GsTelemetry::EventDump={not json",
            Self.event("Streamer_Start", #""zoneAddress":"NP-TYO-01""#, ts: "2026-11-02T20:37:17.000Z"),
        ].joined(separator: "\n")

        XCTAssertTrue(GeForceNOWStreamLog.reports(in: log).isEmpty)
    }

    func testLatestReportReadsBothLogsAndPicksTheNewestStream() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = Self.event("Streamer_Exit", #""zoneAddress":"NP-FRK-06","streamDuration":1000"#, ts: "2026-11-01T10:00:00.000Z")
        try older.write(to: directory.appendingPathComponent("geronimo.log.bak"), atomically: true, encoding: .utf8)
        try Self.completeStream.write(to: directory.appendingPathComponent("geronimo.log"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GeForceNOWStreamLog.latestReport(in: directory)?.zoneCode, "NP-TYO-01")
    }

    func testMissingLogDirectoryHasNoReport() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(GeForceNOWStreamLog.latestReport(in: directory))
    }
}

final class GeForceNOWStreamDiagnosisTests: XCTestCase {
    private func report(
        averageRoundTripMs: Double? = 20,
        worstRoundTripMs: Double? = 40,
        routerSpikePercent: Double? = 0,
        routerSpikeThresholdMs: Double = 9.29,
        linkRateMbps: Double? = 600,
        band: WiFiBand? = .band5GHz,
        usesWiFi: Bool? = true
    ) -> GeForceNOWStreamReport {
        let start = Date(timeIntervalSince1970: 1_000)
        var report = GeForceNOWStreamReport(zoneCode: "NP-TYO-01", startedAt: start, endedAt: start.addingTimeInterval(600))
        report.usesWiFi = usesWiFi
        report.maximumBitrateMbps = 42.9
        report.averageRoundTripMs = averageRoundTripMs
        report.worstRoundTripMs = worstRoundTripMs
        report.packetLossPercent = 0
        report.frameDropPercent = 0
        report.routerSpikePercent = routerSpikePercent
        report.routerSpikeThresholdMs = routerSpikeThresholdMs
        report.wifi = .init(band: band, channel: 161, linkRateMbps: linkRateMbps)
        return report
    }

    func testHealthyStreamHasNoFindings() {
        XCTAssertTrue(GeForceNOWStreamDiagnosis.findings(for: report()).isEmpty)
    }

    func testDistantServerSlowLinkAndWiFiDelaysAreProblemsAheadOfSpikes() throws {
        let findings = GeForceNOWStreamDiagnosis.findings(for: report(
            averageRoundTripMs: 88,
            worstRoundTripMs: 610,
            routerSpikePercent: 7,
            linkRateMbps: 43
        ))

        XCTAssertEqual(findings.map(\.kind), [.serverTooFar, .wifiTooSlowForStream, .routerDelays, .roundTripSpikes])
        XCTAssertEqual(findings.map(\.severity), [.problem, .problem, .warning, .warning])
        XCTAssertTrue(findings[1].detail.contains("about 21 Mbps"))
        XCTAssertTrue(try XCTUnwrap(findings.last).detail.contains("may have started on your Wi-Fi"))
    }

    func testSpikesWithASteadyRouterArePlacedPastTheRouter() throws {
        let findings = GeForceNOWStreamDiagnosis.findings(for: report(worstRoundTripMs: 300, routerSpikePercent: 1))

        XCTAssertEqual(findings.map(\.kind), [.roundTripSpikes])
        XCTAssertTrue(try XCTUnwrap(findings.first).detail.contains("past your router"))
    }

    func testRouterSpikesAreAProblemOnlyWhenFrequentAndLong() {
        let severity = { (percent: Double, threshold: Double) in
            GeForceNOWStreamDiagnosis.findings(for: self.report(routerSpikePercent: percent, routerSpikeThresholdMs: threshold))
                .map(\.severity)
        }
        XCTAssertEqual(severity(3, 60), [.warning])
        XCTAssertEqual(severity(7, 9.29), [.warning])
        XCTAssertEqual(severity(7, 60), [.problem])
    }

    func testWiredStreamSkipsWiFiFindings() {
        let findings = GeForceNOWStreamDiagnosis.findings(for: report(linkRateMbps: 10, band: .band2_4GHz, usesWiFi: false))
        XCTAssertTrue(findings.isEmpty)
    }

    func testTwoPointFourGigahertzIsFlagged() {
        XCTAssertEqual(GeForceNOWStreamDiagnosis.findings(for: report(band: .band2_4GHz)).map(\.kind), [.slowWiFiBand])
    }
}
