import Foundation
import XCTest
@testable import PingWardenCore

final class RouterLatencySummaryTests: XCTestCase {
    private func pings(_ roundTrips: [Double?]) -> [RouterPingSample] {
        roundTrips.enumerated().map { index, roundTrip in
            RouterPingSample(roundTripMs: roundTrip, sentAt: Date(timeIntervalSince1970: Double(index) / 10))
        }
    }

    func testNoRepliesHaveNoSummary() {
        XCTAssertNil(RouterLatencySummary(samples: []))
        XCTAssertNil(RouterLatencySummary(samples: pings([nil, nil, nil])))
    }

    func testLostAndLatePingsCountAsDelayedButOnlyRepliesSetPercentiles() throws {
        let summary = try XCTUnwrap(RouterLatencySummary(samples: pings([4, 5, 6, 50, nil])))

        XCTAssertEqual(summary.sampleCount, 5)
        XCTAssertEqual(summary.medianMs, 5.5)
        XCTAssertEqual(summary.p95Ms, 50)
        XCTAssertEqual(summary.delayedPercent, 40)
        XCTAssertEqual(summary.health, .delaying)
    }

    func testHealthBands() throws {
        let healthy = try XCTUnwrap(RouterLatencySummary(samples: pings(Array(repeating: 4, count: 200) + [80])))
        let occasional = try XCTUnwrap(RouterLatencySummary(samples: pings(Array(repeating: 4, count: 97) + [80, 80, 80])))

        XCTAssertEqual(healthy.health, .healthy)
        XCTAssertEqual(occasional.health, .occasionalDelays)
    }
}

final class LocalLinkAssessmentTests: XCTestCase {
    private let delayingRouter = RouterLatencySummary(sampleCount: 100, medianMs: 5, p95Ms: 200, delayedPercent: 12)
    private let healthyRouter = RouterLatencySummary(sampleCount: 100, medianMs: 3, p95Ms: 6, delayedPercent: 0)

    private func wifi(signal: Int, band: WiFiBand = .band5GHz) -> WiFiLinkSample {
        WiFiLinkSample(signalDBm: signal, noiseDBm: -90, transmitRateMbps: 144, channel: 153, band: band)
    }

    func testDelayingRouterOnAFairSignalSuggestsMovingCloserAndProtection() {
        let advice = LocalLinkAssessment.advice(router: delayingRouter, wifi: wifi(signal: -73), protectionActive: false)
        XCTAssertEqual(advice, [.moveCloserOrUseEthernet, .turnOnPingProtection])
    }

    func testHealthyStrongFiveGigahertzLinkNeedsNothing() {
        let advice = LocalLinkAssessment.advice(router: healthyRouter, wifi: wifi(signal: -55), protectionActive: false)
        XCTAssertTrue(advice.isEmpty)
    }

    func testWeakSignalAndSlowBandAreFlaggedEvenWhenTheRouterIsFine() {
        let advice = LocalLinkAssessment.advice(
            router: healthyRouter,
            wifi: wifi(signal: -80, band: .band2_4GHz),
            protectionActive: true
        )
        XCTAssertEqual(advice, [.moveCloserOrUseEthernet, .useFasterBand])
    }

    func testWiredMacGetsNoWiFiAdvice() {
        XCTAssertTrue(LocalLinkAssessment.advice(router: delayingRouter, wifi: nil, protectionActive: false).isEmpty)
    }

    func testDelayOriginSeparatesLocalNetworkFromThePathBeyondIt() {
        XCTAssertEqual(
            LocalLinkAssessment.delayOrigin(router: delayingRouter, targetMedianMs: 90, targetP95Ms: 200),
            .localNetwork
        )
        XCTAssertEqual(
            LocalLinkAssessment.delayOrigin(router: delayingRouter, targetMedianMs: 90, targetP95Ms: 95),
            .none
        )
        XCTAssertEqual(
            LocalLinkAssessment.delayOrigin(router: healthyRouter, targetMedianMs: 90, targetP95Ms: 200),
            .beyondRouter
        )
        XCTAssertEqual(
            LocalLinkAssessment.delayOrigin(router: healthyRouter, targetMedianMs: 90, targetP95Ms: 100),
            .none
        )
    }

    func testSignalBandsAndClientBandNames() {
        XCTAssertEqual(WiFiSignalQuality.forSignal(dBm: -67), .strong)
        XCTAssertEqual(WiFiSignalQuality.forSignal(dBm: -75), .fair)
        XCTAssertEqual(WiFiSignalQuality.forSignal(dBm: -76), .weak)
        XCTAssertEqual(WiFiBand(clientBandName: "BAND_2_4_GHz"), .band2_4GHz)
        XCTAssertEqual(WiFiBand(clientBandName: "BAND_6_0_GHz"), .band6GHz)
        XCTAssertNil(WiFiBand(clientBandName: "UNKNOWN"))
    }
}

final class ICMPEchoTests: XCTestCase {
    func testRequestCarriesAValidChecksum() {
        let request = ICMPEcho.request(identifier: 0xBEEF, sequence: 7)

        XCTAssertEqual(request.count, 24)
        XCTAssertEqual(Array(request[0...1]), [8, 0])
        XCTAssertEqual(ICMPEcho.checksum(request), 0)
    }

    func testReplyIsReadWithOrWithoutAnIPv4Header() {
        var reply = ICMPEcho.request(identifier: 0xBEEF, sequence: 300)
        reply[0] = 0
        let ipv4Header: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)

        XCTAssertEqual(ICMPEcho.reply(in: ipv4Header + reply), .init(identifier: 0xBEEF, sequence: 300))
        XCTAssertEqual(ICMPEcho.reply(in: reply), .init(identifier: 0xBEEF, sequence: 300))
    }

    func testRequestsAndTruncatedDatagramsAreNotReplies() {
        let request = ICMPEcho.request(identifier: 1, sequence: 1)
        XCTAssertNil(ICMPEcho.reply(in: request))
        XCTAssertNil(ICMPEcho.reply(in: [0x45, 0, 0]))
    }
}

final class ProtectedSessionLocalLinkTests: XCTestCase {
    func testSessionRecapsRouterPingsAndWeakestSignal() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var accumulator = ProtectedSessionAccumulator(startedAt: start, trigger: .gameMode, startingInterventionCount: 0)
        accumulator.recordRouterPing(RouterPingSample(roundTripMs: 4, sentAt: start))
        accumulator.recordRouterPing(RouterPingSample(roundTripMs: nil, sentAt: start))
        accumulator.recordWiFi(WiFiLinkSample(signalDBm: -60, noiseDBm: -90, transmitRateMbps: 300, channel: 36, band: .band5GHz))
        accumulator.recordWiFi(WiFiLinkSample(signalDBm: -74, noiseDBm: -90, transmitRateMbps: 100, channel: 36, band: .band5GHz))

        let summary = accumulator.finish(endedAt: start.addingTimeInterval(60), endingInterventionCount: 0)

        XCTAssertEqual(summary.router?.sampleCount, 2)
        XCTAssertEqual(summary.router?.delayedPercent, 50)
        XCTAssertEqual(summary.weakestSignalDBm, -74)
        XCTAssertTrue(summary.privacySafeShareText.contains("Router pings delayed: 50.0%"))
        XCTAssertTrue(summary.privacySafeShareText.contains("Weakest Wi-Fi signal: -74 dBm"))
    }

    func testRecapsSavedBeforeRouterPingsStillDecode() throws {
        let json = """
        [{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","startedAt":"2026-01-01T00:00:00Z",
          "endedAt":"2026-01-01T00:10:00Z","trigger":"manual","sampleCount":3,"successfulSampleCount":3,
          "medianLatencyMs":20,"p95LatencyMs":30,"jitterMs":2,"packetLossPercent":0,"interventionCount":1}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let summary = try XCTUnwrap(try decoder.decode([ProtectedSessionSummary].self, from: Data(json.utf8)).first)

        XCTAssertNil(summary.router)
        XCTAssertNil(summary.weakestSignalDBm)
        XCTAssertFalse(summary.privacySafeShareText.contains("Router"))
    }

    func testRouterSummaryRoundTripsThroughTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProtectedSessionStore(directoryURL: directory)
        let router = RouterLatencySummary(sampleCount: 600, medianMs: 4.5, p95Ms: 30, delayedPercent: 2.5)
        let summary = ProtectedSessionSummary(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            trigger: .manual,
            sampleCount: 300,
            successfulSampleCount: 300,
            medianLatencyMs: 88,
            p95LatencyMs: 120,
            jitterMs: 4,
            packetLossPercent: 0,
            interventionCount: 2,
            router: router,
            weakestSignalDBm: -73
        )

        try store.save(summary)

        XCTAssertEqual(try store.load(), [summary])
    }
}
