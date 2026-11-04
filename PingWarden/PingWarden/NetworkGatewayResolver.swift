//
//  NetworkGatewayResolver.swift
//  PingWarden
//
//  Resolves the active default IPv4 gateway from the system's network
//  state. Used by the dashboard to offer "my router" as a ping target and
//  by the router pings.
//

import Foundation
import SystemConfiguration

enum NetworkGatewayResolver {
    /// configd publishes the primary service's router under this key.
    private static let globalIPv4Key = "State:/Network/Global/IPv4" as CFString

    static func defaultGatewayAddress() -> String? {
        let state = SCDynamicStoreCopyValue(nil, globalIPv4Key) as? [String: Any]
        guard let router = state?["Router"] as? String, !router.isEmpty else {
            return nil
        }
        return router
    }
}
