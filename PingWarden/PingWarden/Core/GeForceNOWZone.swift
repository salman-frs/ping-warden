//
//  GeForceNOWZone.swift
//  PingWarden
//
//  GeForce NOW zones as the public status page lists them, named the way a
//  person picks a server: by region, and by whether NVIDIA runs the zone.
//

import Foundation

struct GeForceNOWZone: Equatable, Sendable {
    let code: String
    /// The status page's group name for the zone, such as "Japan".
    let region: String?

    /// Alliance partners run `NPA-` zones, and only their own memberships
    /// can stream from them.
    var isAlliance: Bool { code.hasPrefix("NPA-") }

    var host: String { "\(code.lowercased()).cloudmatchbeta.nvidiagrid.net" }

    var displayName: String {
        let service = isAlliance ? "GeForce NOW Alliance" : "GeForce NOW"
        guard let region else { return "\(service) (\(code))" }
        return "\(service) · \(region) (\(code))"
    }

    struct StatusComponent: Decodable, Sendable {
        let id: String
        let name: String
        let groupID: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case groupID = "group_id"
        }
    }

    private static let codePattern = #"\bNP[A]?-[A-Z0-9-]+\b"#

    /// Every zone code the components name, each with its group's region.
    /// A code listed twice keeps the first region found for it.
    static func zones(fromStatusComponents components: [StatusComponent]) -> [GeForceNOWZone] {
        let namesByID = Dictionary(components.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var zonesByCode: [String: GeForceNOWZone] = [:]
        for component in components {
            let region = component.groupID.flatMap { namesByID[$0] }.flatMap(cleanedRegion)
            for code in zoneCodes(in: component.name) where zonesByCode[code] == nil {
                zonesByCode[code] = GeForceNOWZone(code: code, region: region)
            }
        }
        return zonesByCode.values.sorted { $0.code < $1.code }
    }

    static func zoneCodes(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: codePattern) else { return [] }
        let uppercased = text.uppercased() as NSString
        return regex
            .matches(in: uppercased as String, range: NSRange(location: 0, length: uppercased.length))
            .map { uppercased.substring(with: $0.range) }
    }

    /// "Japan [RTX 5080]" becomes "Japan" and "KR GFN1  - Alliance Partner"
    /// becomes "KR GFN1": the display name already says which kind it is.
    private static func cleanedRegion(_ groupName: String) -> String? {
        var region = groupName
        if let bracket = region.firstIndex(of: "[") {
            region = String(region[..<bracket])
        }
        region = region.replacingOccurrences(of: "- Alliance Partner", with: "")
        let words = region.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
