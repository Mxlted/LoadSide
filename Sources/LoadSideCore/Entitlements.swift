import Foundation
import CoreFoundation

struct EntitlementResolution {
    let values: [String: Any]
    let warnings: [String]
}

enum EntitlementResolver {
    /// Profile values authorize requested capabilities; they are not copied wholesale.
    static func resolve(requested: [String: Any], profile: ProvisioningProfile, bundleIdentifier: String,
                        policy: EntitlementPolicy) throws -> EntitlementResolution {
        let appID = "\(profile.appIdentifierPrefix).\(bundleIdentifier)"
        var result = requested
        var warnings: [String] = []
        let oldAppID = requested["application-identifier"] as? String
        let oldPrefix = oldAppID.map { String($0.prefix { $0 != "." }) }
        result["application-identifier"] = appID
        result["com.apple.developer.team-identifier"] = profile.teamIdentifier
        if let groups = requested["keychain-access-groups"] as? [String] {
            result["keychain-access-groups"] = groups.map { group in
                if group == oldAppID { return appID }
                if let oldPrefix, group.hasPrefix(oldPrefix + ".") {
                    return profile.appIdentifierPrefix + group.dropFirst(oldPrefix.count)
                }
                return group
            }
        } else if requested.isEmpty, let allowed = profile.entitlements["keychain-access-groups"], isAllowed([appID], by: allowed) {
            result["keychain-access-groups"] = [appID]
        }
        // Never grant debugger access that the source did not request. A false
        // claim can be omitted; distribution must shed an existing true claim.
        if let requestedDebug = result["get-task-allow"] as? Bool {
            if !requestedDebug { result.removeValue(forKey: "get-task-allow") }
            // True is validated by the same strict/compatible rules as every
            // other capability below. No privilege is silently granted/dropped.
        }
        for key in result.keys.sorted() {
            guard let value = result[key] else { continue }
            let authorized = profile.entitlements[key].map { isAllowed(value, by: $0) } ?? false
            if authorized { continue }
            if key == "get-task-allow", value as? Bool == false, profile.entitlements[key] == nil { result.removeValue(forKey: key); continue }
            if policy == .compatible, !["application-identifier", "com.apple.developer.team-identifier"].contains(key) {
                result.removeValue(forKey: key)
                warnings.append("Removed unsupported entitlement \(key) from \(bundleIdentifier). Features using it may stop working.")
            } else {
                throw LoadSideError("entitlements.unsupported", "Profile “\(profile.name)” does not authorize entitlement “\(key)” requested by \(bundleIdentifier).", recovery: "Use a profile with this capability, or explicitly choose Compatible mode to remove unsupported capabilities.")
            }
        }
        return EntitlementResolution(values: result, warnings: warnings)
    }

    static func matches(_ requested: String, allowed: String) -> Bool {
        if !allowed.contains("*") { return requested == allowed }
        guard allowed.hasSuffix("*"), allowed.filter({ $0 == "*" }).count == 1 else { return false }
        return !requested.contains("*") && requested.hasPrefix(String(allowed.dropLast()))
    }

    static func isAllowed(_ requested: Any, by allowed: Any) -> Bool {
        if let requested = requested as? String, let allowed = allowed as? String { return matches(requested, allowed: allowed) }
        if let requested = requested as? [Any], let allowed = allowed as? [Any] {
            return requested.allSatisfy { item in allowed.contains { isAllowed(item, by: $0) } }
        }
        if let requested = requested as? [String: Any], let allowed = allowed as? [String: Any] {
            return requested.allSatisfy { key, value in allowed[key].map { isAllowed(value, by: $0) } ?? false }
        }
        if let requested = requested as? NSNumber, let allowed = allowed as? NSNumber {
            // A plist boolean and an integer are not interchangeable authorizations.
            guard (CFGetTypeID(requested) == CFBooleanGetTypeID()) == (CFGetTypeID(allowed) == CFBooleanGetTypeID()) else { return false }
            return requested == allowed
        }
        return false
    }
}
