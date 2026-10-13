import Foundation
@testable import LoadSideCore

/// Synthetic profile metadata; never a trusted Apple-signed provisioning profile.
func testProfile(id: String = "NEWTEAM.com.example.*", uuid: String = UUID().uuidString,
                 certificate: Data = Data([1, 2, 3]), extras: [String: Any] = [:], expiration: Date = Date().addingTimeInterval(86_400)) throws -> ProvisioningProfile {
    var entitlements: [String: Any] = ["application-identifier": id, "com.apple.developer.team-identifier": "NEWTEAM", "keychain-access-groups": ["NEWTEAM.*"], "get-task-allow": false]
    entitlements.merge(extras) { _, new in new }
    let payload: [String: Any] = ["UUID": uuid, "Name": "Fixture", "TeamIdentifier": ["NEWTEAM"], "ApplicationIdentifierPrefix": ["NEWTEAM"],
                                  "Entitlements": entitlements, "ExpirationDate": expiration, "CreationDate": Date().addingTimeInterval(-60),
                                  "DeveloperCertificates": [certificate], "ProvisionedDevices": ["fixture-device"], "Platform": ["iOS"]]
    let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    return try ProvisioningProfile(url: URL(fileURLWithPath: "/fixture.mobileprovision"), payload: data, data: data)
}
