//
//  GeForceNOWStreamDiagnosis.swift
//  PingWarden
//
//  Turns a GeForce NOW stream report into the few things worth fixing, and
//  says whether each one started on the local network or past it.
//

import Foundation

struct GeForceNOWStreamFinding: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case serverTooFar
        case wifiTooSlowForStream
        case routerDelays
        case roundTripSpikes
        case packetLoss
        case droppedFrames
        case slowWiFiBand
    }

    enum Severity: Int, Comparable, Sendable {
        case warning = 1
        case problem = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind
    let severity: Severity
    let title: String
    let detail: String
}

enum GeForceNOWStreamDiagnosis {
    /// NVIDIA's system requirements ask for under 80 ms to its data centers.
    static let maximumRecommendedRoundTripMs = 80.0
    /// 100 ms above the average is six frames at 60 fps.
    static let roundTripSpikeMarginMs = 100.0

    /// Most severe first; findings of equal severity keep the order below.
    static func findings(for report: GeForceNOWStreamReport) -> [GeForceNOWStreamFinding] {
        let routerDelays = routerDelayFinding(report)
        return [
            serverTooFarFinding(report),
            wifiTooSlowFinding(report),
            routerDelays,
            roundTripSpikeFinding(report, routerWasDelaying: routerDelays != nil),
            packetLossFinding(report),
            droppedFramesFinding(report),
            slowBandFinding(report),
        ]
        .compactMap { $0 }
        .sorted { $0.severity > $1.severity }
    }

    private static func serverTooFarFinding(_ report: GeForceNOWStreamReport) -> GeForceNOWStreamFinding? {
        guard let average = report.averageRoundTripMs, average >= maximumRecommendedRoundTripMs else { return nil }
        return GeForceNOWStreamFinding(
            kind: .serverTooFar,
            severity: .problem,
            title: "Server is farther than NVIDIA recommends",
            detail: "Round trips to \(report.zoneCode) averaged \(milliseconds(average)). NVIDIA recommends under "
                + "\(milliseconds(maximumRecommendedRoundTripMs)). If GeForce NOW's Server Location setting "
                + "offers a closer server, pick it."
        )
    }

    /// Wi-Fi delivers well under its link rate, so a link under twice the
    /// stream's ceiling leaves no room for retries or other traffic.
    private static func wifiTooSlowFinding(_ report: GeForceNOWStreamReport) -> GeForceNOWStreamFinding? {
        guard report.usesWiFi != false,
              let linkRate = report.wifi?.linkRateMbps, linkRate > 0,
              let bitrate = report.maximumBitrateMbps,
              linkRate < bitrate * 2 else {
            return nil
        }
        let suggestedBitrate = Int((linkRate / 2).rounded(.down))
        return GeForceNOWStreamFinding(
            kind: .wifiTooSlowForStream,
            severity: .problem,
            title: "Wi-Fi link is too slow for this stream",
            detail: "Your Mac's Wi-Fi link was \(megabits(linkRate)) for a stream of up to \(megabits(bitrate)), "
                + "and Wi-Fi delivers well under its link rate. Lower Max bit rate to about "
                + "\(suggestedBitrate) Mbps in GeForce NOW's streaming settings, or move closer to the router."
        )
    }

    /// The client counts a router ping as a spike past a multiple of its own
    /// baseline, often under 10 ms. Only a threshold as long as the app's
    /// own router delay makes the spikes a problem rather than a warning.
    private static func routerDelayFinding(_ report: GeForceNOWStreamReport) -> GeForceNOWStreamFinding? {
        guard let spikePercent = report.routerSpikePercent, spikePercent >= 2 else { return nil }
        let threshold = report.routerSpikeThresholdMs
        let isLongDelay = (threshold ?? 0) >= RouterLatencySummary.delayThresholdMs
        let thresholdText = threshold.map { "longer than \(milliseconds($0))" } ?? "longer than usual"
        return GeForceNOWStreamFinding(
            kind: .routerDelays,
            severity: isLongDelay && spikePercent >= 5 ? .problem : .warning,
            title: "Router pings were slow \(percent(spikePercent, decimals: 0)) of the time",
            detail: "GeForce NOW pinged your router throughout the stream, and \(percent(spikePercent, decimals: 0)) "
                + "took \(thresholdText). Delays this close to your Mac start on your Wi-Fi or router: move closer "
                + "to the router, use Ethernet, or keep Ping Protection on while you play."
        )
    }

    private static func roundTripSpikeFinding(
        _ report: GeForceNOWStreamReport,
        routerWasDelaying: Bool
    ) -> GeForceNOWStreamFinding? {
        guard let average = report.averageRoundTripMs,
              let worst = report.worstRoundTripMs,
              worst >= average + roundTripSpikeMarginMs else {
            return nil
        }
        let origin: String
        if routerWasDelaying {
            origin = "Your router pings were slow at times too, so these spikes may have started on your Wi-Fi."
        } else if report.routerSpikePercent != nil {
            origin = "Your router pings stayed steady, so these spikes came from past your router: "
                + "your internet connection or the route to the server."
        } else {
            origin = "Spikes like these show up as stutter or a blurry picture."
        }
        return GeForceNOWStreamFinding(
            kind: .roundTripSpikes,
            severity: .warning,
            title: "Round trips peaked at \(milliseconds(worst))",
            detail: "The average was \(milliseconds(average)). \(origin)"
        )
    }

    private static func packetLossFinding(_ report: GeForceNOWStreamReport) -> GeForceNOWStreamFinding? {
        guard let loss = report.packetLossPercent, loss >= 1 else { return nil }
        return GeForceNOWStreamFinding(
            kind: .packetLoss,
            severity: .problem,
            title: "Lost \(percent(loss, decimals: 1)) of packets",
            detail: "Lost packets show up as artifacts and stutter."
        )
    }

    private static func droppedFramesFinding(_ report: GeForceNOWStreamReport) -> GeForceNOWStreamFinding? {
        guard let drops = report.frameDropPercent, drops >= 1 else { return nil }
        return GeForceNOWStreamFinding(
            kind: .droppedFrames,
            severity: .warning,
            title: "Dropped \(percent(drops, decimals: 1)) of frames",
            detail: "GeForce NOW drops frames that arrive too late to show."
        )
    }

    private static func slowBandFinding(_ report: GeForceNOWStreamReport) -> GeForceNOWStreamFinding? {
        guard report.usesWiFi != false, report.wifi?.band == .band2_4GHz else { return nil }
        return GeForceNOWStreamFinding(
            kind: .slowWiFiBand,
            severity: .warning,
            title: "Connected over 2.4 GHz Wi-Fi",
            detail: "NVIDIA recommends a 5 GHz network for GeForce NOW. Join your router's 5 GHz network if it has one."
        )
    }

    private static func milliseconds(_ value: Double) -> String {
        String(format: "%.0f ms", value)
    }

    private static func megabits(_ value: Double) -> String {
        String(format: "%.0f Mbps", value)
    }

    private static func percent(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f%%", decimals, value)
    }
}
