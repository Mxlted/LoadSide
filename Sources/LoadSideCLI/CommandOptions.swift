import Foundation
import LoadSideCore

struct CommandOptions {
    private(set) var values: [String: [String]] = [:]
    private(set) var flags: Set<String> = []
    static let valueOptions: Set<String> = [
        "--ipa", "--p12", "--profile", "--output", "--inject", "--bundle-id", "--bundle-id-policy", "--name", "--entitlements",
        "--password-file"
    ]
    static let flagOptions: Set<String> = [
        "--password-stdin", "--json", "--remove-extensions", "--reuse-main-profile-for-extensions", "--require-matching-extension-profiles"
    ]
    static let repeatable: Set<String> = ["--profile", "--inject"]

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if Self.flagOptions.contains(option) {
                guard flags.insert(option).inserted else { throw LoadSideError("arguments.duplicate", "Repeated option: \(option)") }
                index += 1
            } else if Self.valueOptions.contains(option) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else {
                    throw Self.missing(option)
                }
                guard Self.repeatable.contains(option) || values[option] == nil else {
                    throw LoadSideError("arguments.duplicate", "Repeated option: \(option)")
                }
                values[option, default: []].append(arguments[index + 1])
                index += 2
            } else {
                throw LoadSideError(
                    "arguments.unknown", "Unknown option: \(option)", recovery: "Run loadside --help for supported options.")
            }
        }
        if flags.contains("--reuse-main-profile-for-extensions") {
            guard !flags.contains("--require-matching-extension-profiles"), !flags.contains("--remove-extensions") else {
                throw LoadSideError(
                    "arguments.extensionPolicy",
                    "Experimental extension profile reuse cannot be combined with matching-only profiles or extension removal.",
                    recovery: "Choose one extension profile policy, or use --remove-extensions alone.")
            }
        }
    }

    func validateForInjection() throws {
        let allowedValues: Set<String> = ["--ipa", "--output", "--inject", "--name"]
        let allowedFlags: Set<String> = ["--json", "--remove-extensions"]
        let unsupported = Set(values.keys).subtracting(allowedValues).union(flags.subtracting(allowedFlags))
        guard unsupported.isEmpty else {
            throw LoadSideError(
                "arguments.inject", "The inject command does not accept \(unsupported.sorted().joined(separator: ", ")).",
                recovery: "Use loadside sign for signing options. Injection exports an unsigned IPA and never requests credentials.")
        }
    }

    func requiredURL(_ key: String) throws -> URL {
        guard let path = values[key]?.first else { throw Self.missing(key) }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    static func missing(_ key: String) -> LoadSideError {
        LoadSideError("arguments.missing", "Missing value for \(key).", recovery: "Run loadside --help for usage.")
    }
}
