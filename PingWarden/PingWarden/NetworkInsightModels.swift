//
//  NetworkInsightModels.swift
//  PingWarden
//
//  State for the Dashboard's Local Network and GeForce NOW cards.
//

import AppKit
import Foundation

@MainActor
final class LocalNetworkModel: ObservableObject {
    @Published private(set) var snapshot: LocalLinkMonitor.Snapshot?

    private let monitor = LocalLinkMonitor.shared
    private let consumerID = UUID()
    private var observerToken: UUID?
    private var latestSnapshot: LocalLinkMonitor.Snapshot?
    private var visibilityGate = DeferredRefreshGate()

    func start() {
        guard observerToken == nil else { return }
        observerToken = monitor.addObserver { [weak self] snapshot in
            MainActor.assumeIsolated { self?.receive(snapshot) }
        }
        monitor.start(consumerID: consumerID)
    }

    func stop() {
        monitor.stop(consumerID: consumerID)
        if let observerToken {
            monitor.removeObserver(observerToken)
            self.observerToken = nil
        }
        visibilityGate.reset()
    }

    /// Pings keep running while the window is hidden; only the redraw waits.
    func setPresentationVisible(_ visible: Bool) {
        if visibilityGate.setVisible(visible) {
            snapshot = latestSnapshot
        }
    }

    private func receive(_ snapshot: LocalLinkMonitor.Snapshot) {
        latestSnapshot = snapshot
        if visibilityGate.noteChange() {
            self.snapshot = snapshot
        }
    }
}

@MainActor
final class GeForceNOWStreamModel: ObservableObject {
    @Published private(set) var report: GeForceNOWStreamReport?
    @Published private(set) var findings: [GeForceNOWStreamFinding] = []
    @Published private(set) var isClientInstalled = false

    private static let clientBundleIdentifier = "com.nvidia.gfnpc.mall"
    private static let streamerBundleIdentifier = "com.nvidia.gfnpc.streamer"

    private var terminationObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?

    func start() {
        isClientInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.clientBundleIdentifier) != nil
        reload()
        guard terminationObserver == nil else { return }
        // The client writes a stream's last numbers as its streamer quits.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.streamerBundleIdentifier else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let report = await Task.detached(priority: .utility) {
                GeForceNOWStreamLog.latestReport()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.report = report
            self.findings = report.map(GeForceNOWStreamDiagnosis.findings(for:)) ?? []
        }
    }
}
