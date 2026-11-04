import Foundation
import XCTest
@testable import PingWardenCore

final class GeForceNOWZoneTests: XCTestCase {
    private func component(_ id: String, _ name: String, group: String? = nil) -> GeForceNOWZone.StatusComponent {
        let groupJSON = group.map { "\"\($0)\"" } ?? "null"
        let json = "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"group_id\":\(groupJSON)}"
        return try! JSONDecoder().decode(GeForceNOWZone.StatusComponent.self, from: Data(json.utf8))
    }

    func testZonesTakeTheirGroupsRegionWithoutHardwareOrPartnerSuffixes() {
        let zones = GeForceNOWZone.zones(fromStatusComponents: [
            component("g1", "Japan [RTX 5080]"),
            component("g2", "KR GFN1  - Alliance Partner"),
            component("z1", "NP-TYO-01 [RTX 5080]", group: "g1"),
            component("z2", "NPA-GKR-SEL-02 [RTX 4080]", group: "g2"),
            component("z3", "np-tyo-01", group: "g2"),
            component("z4", "Cloud Storage", group: "g1"),
            component("z5", "NP-SOLO-01"),
        ])

        XCTAssertEqual(zones, [
            GeForceNOWZone(code: "NP-SOLO-01", region: nil),
            GeForceNOWZone(code: "NP-TYO-01", region: "Japan"),
            GeForceNOWZone(code: "NPA-GKR-SEL-02", region: "KR GFN1"),
        ])
    }

    func testDisplayNameSaysWhoRunsTheZone() {
        XCTAssertEqual(GeForceNOWZone(code: "NP-TYO-01", region: "Japan").displayName, "GeForce NOW · Japan (NP-TYO-01)")
        XCTAssertEqual(
            GeForceNOWZone(code: "NPA-YES-KUL-01", region: "MY YES").displayName,
            "GeForce NOW Alliance · MY YES (NPA-YES-KUL-01)"
        )
        XCTAssertEqual(GeForceNOWZone(code: "NP-SOLO-01", region: nil).displayName, "GeForce NOW (NP-SOLO-01)")
        XCTAssertEqual(GeForceNOWZone(code: "NP-TYO-01", region: nil).host, "np-tyo-01.cloudmatchbeta.nvidiagrid.net")
    }
}
