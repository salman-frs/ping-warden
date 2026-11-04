//
//  NetworkInsightCards.swift
//  PingWarden
//
//  Dashboard cards that say where delays start: on the local network,
//  measured live against the router, or in a finished GeForce NOW stream,
//  read from the client's own log.
//

import SwiftUI

// MARK: - Local Network Card

struct LocalNetworkCard: View {
    @ObservedObject var model: LocalNetworkModel
    @ObservedObject private var protectionExperience = ProtectionExperienceCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Local Network")
                    .font(.headline)
                Spacer()
                Text("Your Wi-Fi and router, pinged 10 times a second")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .dashboardCardHeader()

            if let snapshot = model.snapshot {
                verdict(snapshot)
                metricGrid(snapshot)
                adviceList(snapshot)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Measuring your router…")
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .dashboardCardStyle()
    }

    @ViewBuilder
    private func verdict(_ snapshot: LocalLinkMonitor.Snapshot) -> some View {
        switch snapshot.router {
        case .measuring:
            Text("Measuring your router…")
                .font(.subheadline)
        case .noGateway:
            Label("No router address found", systemImage: "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .cannotPing:
            Label("Ping Warden could not send pings to your router", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .notAnswering:
            Label("Your router does not answer pings, so its delay cannot be measured", systemImage: "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .measured(let router):
            VStack(alignment: .leading, spacing: 4) {
                Label(Self.headline(for: router.health), systemImage: Self.symbol(for: router.health))
                    .font(.subheadline)
                    .foregroundStyle(Self.color(for: router.health))
                Text(String(
                    format: "%.1f%% of router pings in the last minute took over %.0f ms or got no reply.",
                    router.delayedPercent,
                    RouterLatencySummary.delayThresholdMs
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func metricGrid(_ snapshot: LocalLinkMonitor.Snapshot) -> some View {
        let router = snapshot.router.summary
        return HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                MetricRow(label: "Router", value: router.map { Self.milliseconds($0.medianMs) } ?? "--")
                MetricRow(label: "Router P95", value: router.map { Self.milliseconds($0.p95Ms) } ?? "--")
                MetricRow(
                    label: "Delayed",
                    value: router.map { String(format: "%.1f%%", $0.delayedPercent) } ?? "--",
                    tint: router.map { Self.color(for: $0.health) } ?? .primary
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                if let wifi = snapshot.wifi {
                    MetricRow(
                        label: "Signal",
                        value: "\(wifi.signalDBm) dBm",
                        tint: Self.color(for: wifi.signalQuality)
                    )
                    MetricRow(label: "Link Rate", value: String(format: "%.0f Mbps", wifi.transmitRateMbps))
                    MetricRow(label: "Band", value: Self.bandText(wifi), useMonospacedValue: false)
                } else {
                    MetricRow(label: "Connection", value: "Not Wi-Fi", useMonospacedValue: false)
                }
            }
        }
    }

    @ViewBuilder
    private func adviceList(_ snapshot: LocalLinkMonitor.Snapshot) -> some View {
        let advice = LocalLinkAssessment.advice(
            router: snapshot.router.summary,
            wifi: snapshot.wifi,
            protectionActive: protectionExperience.policyState.effectiveProtectionEnabled
        )
        if !advice.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(advice, id: \.self) { item in
                    Label(Self.text(for: item), systemImage: "lightbulb")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(InnerCalloutBackground(cornerRadius: 8, fallbackOpacity: 0.28))
        }
    }

    private static func headline(for health: LocalLinkHealth) -> String {
        switch health {
        case .healthy: return "Your local network is responding quickly"
        case .occasionalDelays: return "Your local network has occasional delays"
        case .delaying: return "Your local network is delaying packets"
        }
    }

    private static func symbol(for health: LocalLinkHealth) -> String {
        switch health {
        case .healthy: return "checkmark.circle.fill"
        case .occasionalDelays: return "exclamationmark.triangle"
        case .delaying: return "xmark.circle.fill"
        }
    }

    private static func color(for health: LocalLinkHealth) -> Color {
        switch health {
        case .healthy: return LatencyPalette.excellent
        case .occasionalDelays: return LatencyPalette.fair
        case .delaying: return LatencyPalette.poor
        }
    }

    private static func color(for quality: WiFiSignalQuality) -> Color {
        switch quality {
        case .strong: return LatencyPalette.excellent
        case .fair: return LatencyPalette.fair
        case .weak: return LatencyPalette.poor
        }
    }

    private static func text(for advice: LocalLinkAdvice) -> String {
        switch advice {
        case .moveCloserOrUseEthernet:
            return "Move closer to your router, or connect with Ethernet."
        case .useFasterBand:
            return "Join your router's 5 GHz network. 2.4 GHz is slower and more crowded."
        case .turnOnPingProtection:
            return "Turn on Ping Protection so AWDL cannot take the Wi-Fi radio away while you play."
        }
    }

    private static func bandText(_ wifi: WiFiLinkSample) -> String {
        let band = wifi.band?.label ?? "Unknown band"
        guard let channel = wifi.channel else { return band }
        return "\(band), channel \(channel)"
    }

    private static func milliseconds(_ value: Double) -> String {
        String(format: "%.0f ms", value)
    }
}

// MARK: - GeForce NOW Stream Card

struct GeForceNOWStreamCard: View {
    @ObservedObject var model: GeForceNOWStreamModel
    @ObservedObject var dashboard: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let report = model.report {
                metrics(report)
                findings(report)
                Text("Read from GeForce NOW's own log on this Mac. Nothing is uploaded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Play something in GeForce NOW. When the stream ends, its network report appears here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dashboardCardStyle()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Last GeForce NOW Stream")
                    .font(.headline)
                if let report = model.report {
                    Text("\(report.startedAt.formatted(date: .abbreviated, time: .shortened)), \(ProtectedSessionCard.durationText(report.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let server = serverTarget, server.id != dashboard.selectedTargetID {
                Button("Ping This Server") {
                    dashboard.selectedTargetID = server.id
                }
                .buttonStyle(.bordered)
                .help("Measure latency to \(server.displayName) on this dashboard")
            }
        }
        .dashboardCardHeader()
    }

    /// The stream's zone in the target list, when discovery knows it.
    private var serverTarget: PingTarget? {
        guard let zoneCode = model.report?.zoneCode else { return nil }
        let id = GeForceNOWDiscovery.target(for: GeForceNOWZone(code: zoneCode, region: nil)).id
        return dashboard.targets.first { $0.id == id }
    }

    private func metrics(_ report: GeForceNOWStreamReport) -> some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                MetricRow(label: "Server", value: report.zoneCode, useMonospacedValue: false)
                MetricRow(label: "Video", value: Self.videoText(report), useMonospacedValue: false)
                MetricRow(label: "Wi-Fi Link", value: Self.wifiText(report), useMonospacedValue: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                MetricRow(
                    label: "Round Trip",
                    value: report.averageRoundTripMs.map(Self.milliseconds) ?? "--",
                    tint: report.averageRoundTripMs.map(LatencyPalette.forLatency) ?? .primary
                )
                MetricRow(
                    label: "Worst",
                    value: report.worstRoundTripMs.map(Self.milliseconds) ?? "--",
                    tint: report.worstRoundTripMs.map(LatencyPalette.forLatency) ?? .primary
                )
                MetricRow(
                    label: "Router Spikes",
                    value: report.routerSpikePercent.map { String(format: "%.0f%%", $0) } ?? "--",
                    tint: report.routerSpikePercent.map { $0 < 2 ? LatencyPalette.excellent : LatencyPalette.fair } ?? .primary
                )
            }
        }
    }

    @ViewBuilder
    private func findings(_ report: GeForceNOWStreamReport) -> some View {
        if !report.hasMeasurements {
            Text("GeForce NOW's log has no measurements for this stream.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.findings.isEmpty {
            Label("No network problems found in this stream", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(LatencyPalette.excellent)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.findings, id: \.title) { finding in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: finding.severity == .problem ? "xmark.circle.fill" : "exclamationmark.triangle")
                            .foregroundStyle(finding.severity == .problem ? LatencyPalette.poor : LatencyPalette.fair)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title)
                                .font(.subheadline)
                            Text(finding.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(InnerCalloutBackground(cornerRadius: 8, fallbackOpacity: 0.28))
        }
    }

    private static func videoText(_ report: GeForceNOWStreamReport) -> String {
        guard let mode = report.videoMode else { return report.codec ?? "--" }
        let resolution = "\(mode.width)×\(mode.height) at \(mode.framesPerSecond) fps"
        return report.codec.map { "\(resolution), \($0)" } ?? resolution
    }

    private static func wifiText(_ report: GeForceNOWStreamReport) -> String {
        if report.usesWiFi == false { return "Not Wi-Fi" }
        guard let rate = report.wifi?.linkRateMbps else { return "--" }
        let rateText = String(format: "%.0f Mbps", rate)
        return report.wifi?.band.map { "\(rateText), \($0.label)" } ?? rateText
    }

    private static func milliseconds(_ value: Double) -> String {
        String(format: "%.0f ms", value)
    }
}
