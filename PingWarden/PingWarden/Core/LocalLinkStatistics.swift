//
//  LocalLinkStatistics.swift
//  PingWarden
//
//  Judges the hop between this Mac and its router: how often router pings
//  come back late, and how strong the Wi-Fi link is. A delay that already
//  shows at the router started on the local network, not past it.
//

import Foundation

enum WiFiBand: String, Codable, Sendable {
    case band2_4GHz
    case band5GHz
    case band6GHz

    /// GeForce NOW writes "BAND_2_4_GHz", "BAND_5_0_GHz", and "BAND_6_0_GHz".
    init?(clientBandName: String) {
        switch clientBandName.uppercased() {
        case let name where name.contains("2_4"): self = .band2_4GHz
        case let name where name.contains("5_0"): self = .band5GHz
        case let name where name.contains("6_0"): self = .band6GHz
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .band2_4GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        }
    }
}

enum WiFiSignalQuality: Equatable, Sendable {
    case strong
    case fair
    case weak

    /// -67 dBm is the common floor for real-time traffic such as calls.
    static func forSignal(dBm: Int) -> WiFiSignalQuality {
        if dBm >= -67 { return .strong }
        if dBm >= -75 { return .fair }
        return .weak
    }
}

struct WiFiLinkSample: Equatable, Sendable {
    let signalDBm: Int
    let noiseDBm: Int
    let transmitRateMbps: Double
    let channel: Int?
    let band: WiFiBand?

    var signalToNoiseDB: Int { signalDBm - noiseDBm }
    var signalQuality: WiFiSignalQuality { .forSignal(dBm: signalDBm) }
}

/// One ping to the router: its round trip, or nil when no reply came in time.
struct RouterPingSample: Equatable, Sendable {
    let roundTripMs: Double?
    let sentAt: Date
}

enum LocalLinkHealth: Equatable, Sendable {
    case healthy
    case occasionalDelays
    case delaying
}

struct RouterLatencySummary: Codable, Equatable, Sendable {
    /// A round trip this long holds a 60 fps stream back by three frames.
    static let delayThresholdMs = 50.0

    let sampleCount: Int
    let medianMs: Double
    let p95Ms: Double
    /// Pings that came back after `delayThresholdMs`, or not at all.
    let delayedPercent: Double

    init(sampleCount: Int, medianMs: Double, p95Ms: Double, delayedPercent: Double) {
        self.sampleCount = sampleCount
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.delayedPercent = delayedPercent
    }

    /// Nil without a single reply: some routers never answer pings, and
    /// that says nothing about the link. A lost ping counts toward the
    /// delayed share but not toward the round-trip percentiles.
    init?(samples: [RouterPingSample]) {
        let roundTrips = samples.compactMap(\.roundTripMs).sorted()
        guard !roundTrips.isEmpty else { return nil }
        let delayedCount = samples.filter { ($0.roundTripMs ?? .infinity) >= Self.delayThresholdMs }.count
        self.init(
            sampleCount: samples.count,
            medianMs: Percentiles.median(ofSorted: roundTrips),
            p95Ms: Percentiles.p95(ofSorted: roundTrips),
            delayedPercent: Double(delayedCount) / Double(samples.count) * 100
        )
    }

    var health: LocalLinkHealth {
        if delayedPercent < 1 { return .healthy }
        if delayedPercent < 5 { return .occasionalDelays }
        return .delaying
    }
}

enum LocalLinkAdvice: Equatable, Sendable {
    case moveCloserOrUseEthernet
    case useFasterBand
    case turnOnPingProtection
}

enum LocalLinkAssessment {
    /// What would most likely help, most useful first. Advice is about Wi-Fi,
    /// so a Mac without a Wi-Fi sample gets none.
    static func advice(
        router: RouterLatencySummary?,
        wifi: WiFiLinkSample?,
        protectionActive: Bool
    ) -> [LocalLinkAdvice] {
        guard let wifi else { return [] }
        let routerIsDelaying = router.map { $0.health != .healthy } ?? false
        var advice: [LocalLinkAdvice] = []
        if wifi.signalQuality == .weak || (routerIsDelaying && wifi.signalQuality == .fair) {
            advice.append(.moveCloserOrUseEthernet)
        }
        if wifi.band == .band2_4GHz {
            advice.append(.useFasterBand)
        }
        if routerIsDelaying && !protectionActive {
            advice.append(.turnOnPingProtection)
        }
        return advice
    }

    enum DelayOrigin: Equatable, Sendable {
        case localNetwork
        case beyondRouter
        case none
    }

    /// Where a session's delays came from, when it had any: P95 at least
    /// 50 ms above the median, the same margin router pings are held to.
    /// Delays at the router too mean the local network; a quick router
    /// means the path past it.
    static func delayOrigin(
        router: RouterLatencySummary,
        targetMedianMs: Double,
        targetP95Ms: Double
    ) -> DelayOrigin {
        guard targetP95Ms - targetMedianMs >= RouterLatencySummary.delayThresholdMs else { return .none }
        return router.health == .healthy ? .beyondRouter : .localNetwork
    }
}
