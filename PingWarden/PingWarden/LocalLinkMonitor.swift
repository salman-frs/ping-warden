//
//  LocalLinkMonitor.swift
//  PingWarden
//
//  Watches the hop between this Mac and its router while a consumer needs
//  it: an ICMP echo to the default gateway every 100 ms, the rate GeForce
//  NOW uses for its own router check, and the Wi-Fi link from CoreWLAN once
//  a second. Neither needs the helper or any permission.
//

import CoreWLAN
import Darwin
import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.salmanfrs.pingwarden", category: "LocalLinkMonitor")

final class LocalLinkMonitor: @unchecked Sendable {
    static let shared = LocalLinkMonitor()

    enum RouterStatus: Sendable {
        case measuring
        case noGateway
        case cannotPing
        /// Pings went out for the last minute and none came back. Some
        /// routers never answer them.
        case notAnswering
        case measured(RouterLatencySummary)

        var summary: RouterLatencySummary? {
            if case .measured(let summary) = self { return summary }
            return nil
        }
    }

    struct Snapshot: Sendable {
        /// Router pings from the last minute.
        let router: RouterStatus
        /// Pings that finished since the previous snapshot, oldest first.
        let newPings: [RouterPingSample]
        /// Nil when the Mac does not reach the internet over Wi-Fi.
        let wifi: WiFiLinkSample?
    }

    fileprivate static let pingIntervalNanoseconds: UInt64 = 100_000_000
    fileprivate static let replyTimeoutNanoseconds: UInt64 = 1_000_000_000
    fileprivate static let publishIntervalNanoseconds: UInt64 = 1_000_000_000
    fileprivate static let summaryWindowSeconds: TimeInterval = 60

    private let lock = NSLock()
    private var consumers = Set<UUID>()
    private var observers: [UUID: (Snapshot) -> Void] = [:]
    /// Bumped on every start and stop, so a probe loop from an earlier
    /// start notices it is no longer current and exits.
    private var generation: UInt64 = 0
    private let pathMonitor = NWPathMonitor()
    /// CoreWLAN can be slow to answer. Read on the probe thread, it would
    /// hold replies in the socket and add its delay to their round trips.
    private let wifiQueue = DispatchQueue(label: "com.salmanfrs.pingwarden.locallink.wifi", qos: .utility)
    private var latestWiFi: WiFiLinkSample?

    private init() {
        pathMonitor.start(queue: DispatchQueue(label: "com.salmanfrs.pingwarden.locallink.path", qos: .utility))
    }

    func start(consumerID: UUID) {
        lock.lock()
        let isFirstConsumer = consumers.isEmpty
        consumers.insert(consumerID)
        if isFirstConsumer { generation &+= 1 }
        let runGeneration = generation
        lock.unlock()

        guard isFirstConsumer else { return }
        log.info("Starting router pings")
        let thread = Thread { [self] in
            // Without latencyCritical, App Nap coalesces the 100 ms wakeups
            // and the delay shows up as router latency that is not there.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Measuring router latency"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            RouterProbeLoop(monitor: self, generation: runGeneration).run()
        }
        thread.name = "LocalLinkMonitor.probe"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop(consumerID: UUID) {
        lock.lock()
        let removed = consumers.remove(consumerID) != nil
        if removed && consumers.isEmpty {
            generation &+= 1
            log.info("Stopping router pings because no consumers remain")
        }
        lock.unlock()
    }

    @discardableResult
    func addObserver(_ observer: @escaping (Snapshot) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = observer
        lock.unlock()
        return token
    }

    func removeObserver(_ token: UUID) {
        lock.lock()
        observers.removeValue(forKey: token)
        lock.unlock()
    }

    fileprivate func isCurrent(_ runGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == runGeneration
    }

    fileprivate func publish(_ snapshot: Snapshot, generation runGeneration: UInt64) {
        DispatchQueue.main.async { [self] in
            lock.lock()
            let callbacks = generation == runGeneration ? Array(observers.values) : []
            lock.unlock()
            callbacks.forEach { $0(snapshot) }
        }
    }

    fileprivate func requestWiFiSample() {
        wifiQueue.async { [self] in
            let sample = readWiFiSample()
            lock.lock()
            latestWiFi = sample
            lock.unlock()
        }
    }

    fileprivate func latestWiFiSample() -> WiFiLinkSample? {
        lock.lock()
        defer { lock.unlock() }
        return latestWiFi
    }

    private func readWiFiSample() -> WiFiLinkSample? {
        guard pathMonitor.currentPath.usesInterfaceType(.wifi),
              let interface = CWWiFiClient.shared().interface() else {
            return nil
        }
        let signal = interface.rssiValue()
        // CoreWLAN reports 0 dBm while the interface is not associated.
        guard signal != 0 else { return nil }
        let channel = interface.wlanChannel()
        return WiFiLinkSample(
            signalDBm: signal,
            noiseDBm: interface.noiseMeasurement(),
            transmitRateMbps: interface.transmitRate(),
            channel: channel?.channelNumber,
            band: channel.flatMap { Self.band(for: $0.channelBand) }
        )
    }

    private static func band(for channelBand: CWChannelBand) -> WiFiBand? {
        switch channelBand {
        case .band2GHz: return .band2_4GHz
        case .band5GHz: return .band5GHz
        case .band6GHz: return .band6GHz
        default: return nil
        }
    }
}

/// One run of router pings on its own thread, from a start until the
/// monitor's generation moves on.
private final class RouterProbeLoop {
    private struct Outstanding {
        let sentAt: Date
        let sentUptime: UInt64
    }

    private let monitor: LocalLinkMonitor
    private let generation: UInt64
    private let identifier = UInt16.random(in: 1...UInt16.max)
    private var sequence: UInt16 = 0
    private var socketFD: Int32 = -1
    private var gateway: (address: String, socketAddress: sockaddr_in)?
    private var outstanding: [UInt16: Outstanding] = [:]
    private var recentPings: [RouterPingSample] = []
    private var newPings: [RouterPingSample] = []

    init(monitor: LocalLinkMonitor, generation: UInt64) {
        self.monitor = monitor
        self.generation = generation
    }

    /// Without a socket the loop still runs, so Wi-Fi readings keep coming.
    func run() {
        socketFD = Self.openNonBlockingICMPSocket()
        defer { if socketFD >= 0 { close(socketFD) } }

        refreshGateway()
        monitor.requestWiFiSample()
        var nextPing = DispatchTime.now().uptimeNanoseconds
        var nextPublish = nextPing + LocalLinkMonitor.publishIntervalNanoseconds
        while monitor.isCurrent(generation) {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= nextPing {
                sendPing()
                nextPing = max(nextPing + LocalLinkMonitor.pingIntervalNanoseconds, now)
            }
            expireUnanswered(now: now)
            if now >= nextPublish {
                refreshGateway()
                publish()
                nextPublish = max(nextPublish + LocalLinkMonitor.publishIntervalNanoseconds, now)
            }
            waitForReplies(until: min(nextPing, nextPublish))
        }
    }

    private static func openNonBlockingICMPSocket() -> Int32 {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard descriptor >= 0 else {
            log.error("Could not open an ICMP socket: \(errno)")
            return -1
        }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) >= 0 else {
            log.error("Could not make the ICMP socket non-blocking: \(errno)")
            close(descriptor)
            return -1
        }
        return descriptor
    }

    private func refreshGateway() {
        let address = GatewayAddressCache.shared.address()
        guard address != gateway?.address else { return }
        outstanding.removeAll()
        recentPings.removeAll()
        gateway = address.flatMap { address in
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else { return nil }
            return (address, socketAddress)
        }
    }

    private func sendPing() {
        guard socketFD >= 0, var destination = gateway?.socketAddress else { return }
        sequence &+= 1
        let packet = ICMPEcho.request(identifier: identifier, sequence: sequence)
        let sentAt = Date()
        let sentUptime = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketFD, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent == packet.count {
            outstanding[sequence] = Outstanding(sentAt: sentAt, sentUptime: sentUptime)
        } else {
            record(RouterPingSample(roundTripMs: nil, sentAt: sentAt))
        }
    }

    private func waitForReplies(until deadline: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        // Rounded up: a timeout rounded down to 0 would spin until the deadline.
        let timeoutMs = deadline > now ? Int32((deadline - now + 999_999) / 1_000_000) : 0
        guard socketFD >= 0 else {
            usleep(useconds_t(timeoutMs) * 1000)
            return
        }
        var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeoutMs) > 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let received = recv(socketFD, &buffer, buffer.count, 0)
            guard received > 0 else { return }
            let receivedUptime = DispatchTime.now().uptimeNanoseconds
            guard let reply = ICMPEcho.reply(in: Array(buffer[0..<received])),
                  reply.identifier == identifier,
                  let request = outstanding.removeValue(forKey: reply.sequence) else {
                continue
            }
            let roundTripMs = Double(receivedUptime - request.sentUptime) / 1_000_000
            record(RouterPingSample(roundTripMs: roundTripMs, sentAt: request.sentAt))
        }
    }

    private func expireUnanswered(now: UInt64) {
        for (sequence, request) in outstanding where now >= request.sentUptime + LocalLinkMonitor.replyTimeoutNanoseconds {
            outstanding.removeValue(forKey: sequence)
            record(RouterPingSample(roundTripMs: nil, sentAt: request.sentAt))
        }
    }

    private func record(_ ping: RouterPingSample) {
        recentPings.append(ping)
        newPings.append(ping)
    }

    private func publish() {
        let cutoff = Date().addingTimeInterval(-LocalLinkMonitor.summaryWindowSeconds)
        recentPings.removeAll { $0.sentAt < cutoff }
        let snapshot = LocalLinkMonitor.Snapshot(
            router: routerStatus(),
            newPings: newPings.sorted { $0.sentAt < $1.sentAt },
            wifi: monitor.latestWiFiSample()
        )
        monitor.requestWiFiSample()
        newPings.removeAll()
        monitor.publish(snapshot, generation: generation)
    }

    private func routerStatus() -> LocalLinkMonitor.RouterStatus {
        if socketFD < 0 { return .cannotPing }
        if gateway == nil { return .noGateway }
        if let summary = RouterLatencySummary(samples: recentPings) { return .measured(summary) }
        return recentPings.isEmpty ? .measuring : .notAnswering
    }
}
