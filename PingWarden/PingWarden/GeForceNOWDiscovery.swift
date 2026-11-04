//
//  GeForceNOWDiscovery.swift
//  PingWarden
//
//  Asynchronously discovers GeForce NOW datacenter zones from the public
//  status API and returns them as PingTarget entries the dashboard can probe.
//

import Foundation

enum GeForceNOWDiscovery {
    private static let endpoint = URL(string: "https://status.geforcenow.com/api/v2/components.json")

    /// Zones from the last successful fetch, kept in memory for the
    /// process and in defaults across launches. `DashboardViewModel` is a
    /// `@StateObject` that is rebuilt every time the Dashboard or Targets
    /// pane appears, so without this a saved GeForce NOW target could not
    /// be matched until a fresh network round-trip finished, and the shared
    /// probe spent those seconds measuring a fallback target instead.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var memoryCache: (zones: [GeForceNOWZone], fetchedAt: Date)?
    private static let cachedCodesKey = "DashboardGFNZoneCodes"
    private static let cachedRegionsKey = "DashboardGFNZoneRegions"
    private static let cachedAtKey = "DashboardGFNZoneCodesFetchedAt"
    private static let cacheRetention: TimeInterval = 30 * 24 * 3600

    /// The last successfully discovered zones, or `nil` when nothing has
    /// been fetched yet on this Mac (or the persisted copy is too old to
    /// trust). Cheap and synchronous, so a fresh view model can build its
    /// full target list before it registers a probe demand.
    static func cachedTargets(userDefaults: UserDefaults = .standard) -> (targets: [PingTarget], fetchedAt: Date)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let memoryCache {
            return (makeTargets(from: memoryCache.zones), memoryCache.fetchedAt)
        }
        guard let codes = userDefaults.stringArray(forKey: cachedCodesKey), !codes.isEmpty else {
            return nil
        }
        let fetchedAt = Date(timeIntervalSince1970: userDefaults.double(forKey: cachedAtKey))
        guard Date().timeIntervalSince(fetchedAt) < cacheRetention else { return nil }
        // Older caches hold codes without regions.
        let regions = userDefaults.dictionary(forKey: cachedRegionsKey) as? [String: String] ?? [:]
        let zones = codes
            .filter { GeForceNOWZone.zoneCodes(in: $0) == [$0] }
            .map { GeForceNOWZone(code: $0, region: regions[$0]) }
        guard !zones.isEmpty else { return nil }
        memoryCache = (zones, fetchedAt)
        return (makeTargets(from: zones), fetchedAt)
    }

    private static func storeCache(zones: [GeForceNOWZone], fetchedAt: Date, userDefaults: UserDefaults = .standard) {
        cacheLock.lock()
        memoryCache = (zones, fetchedAt)
        cacheLock.unlock()
        userDefaults.set(zones.map(\.code), forKey: cachedCodesKey)
        let regionsByCode = zones.reduce(into: [String: String]()) { regions, zone in
            regions[zone.code] = zone.region
        }
        userDefaults.set(regionsByCode, forKey: cachedRegionsKey)
        userDefaults.set(fetchedAt.timeIntervalSince1970, forKey: cachedAtKey)
    }

    /// Remove both cache tiers. Used by the removal flow.
    static func clearCache(userDefaults: UserDefaults = .standard) {
        cacheLock.lock()
        memoryCache = nil
        cacheLock.unlock()
        userDefaults.removeObject(forKey: cachedCodesKey)
        userDefaults.removeObject(forKey: cachedRegionsKey)
        userDefaults.removeObject(forKey: cachedAtKey)
    }

    static func target(for zone: GeForceNOWZone) -> PingTarget {
        PingTarget(displayName: zone.displayName, host: zone.host, port: 443, source: .geforceNow)
    }

    private static func makeTargets(from zones: [GeForceNOWZone]) -> [PingTarget] {
        zones.sorted { $0.code < $1.code }.map(target(for:))
    }

    private struct ComponentsResponse: Decodable {
        let components: [GeForceNOWZone.StatusComponent]
    }

    /// Returns the discovered zone targets, or `nil` when the fetch failed
    /// (network error, non-2xx, decode failure). `nil` is distinct from a
    /// successful-but-empty response so callers can keep previously
    /// discovered zones on a transient failure instead of wiping them —
    /// which would silently reset the user's selected GFN target.
    static func fetchTargets() async -> [PingTarget]? {
        guard let endpoint else { return nil }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            let payload = try JSONDecoder().decode(ComponentsResponse.self, from: data)
            let zones = GeForceNOWZone.zones(fromStatusComponents: payload.components)
            // An empty list is a successful answer that says "no zones";
            // keep the previous cache rather than persisting nothing.
            if !zones.isEmpty {
                storeCache(zones: zones, fetchedAt: Date())
            }
            return makeTargets(from: zones)
        } catch {
            return nil
        }
    }
}
