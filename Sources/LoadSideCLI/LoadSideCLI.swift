import Foundation
import Darwin
import LoadSideCore

@main
struct LoadSideCLI {
    static let version = "0.1.0-rc.2"

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { print(help); return }
            if arguments.contains("--help") || command == "help" || command == "-h" { print(help); return }
            switch command {
            case "--version", "version": print("LoadSide \(version)")
            case "doctor": try doctor(arguments: Array(arguments.dropFirst()))
            case "profile": try inspectProfile(arguments: Array(arguments.dropFirst()))
            case "sign": try await sign(arguments: Array(arguments.dropFirst()))
            default: throw LoadSideError("arguments.command", "Unknown command: \(command)", recovery: "Run loadside --help for supported commands.")
            }
        } catch is CancellationError {
            writeError("Cancelled. No final IPA was exported.\n")
            Darwin.exit(130)
        } catch let error as LoadSideError {
            writeError("error [\(error.code)]: \(error.message)\n\(error.recovery)\n")
            Darwin.exit(1)
        } catch {
            writeError("error: \(error.localizedDescription)\n")
            Darwin.exit(1)
        }
    }

    static func sign(arguments: [String]) async throws {
        let options = try Options(arguments)
        let ipa = try options.requiredURL("--ipa")
        let certificate = try options.requiredURL("--p12")
        let output = try options.requiredURL("--output")
        let profiles = options.values["--profile", default: []].map { URL(fileURLWithPath: $0) }
        guard !profiles.isEmpty else { throw Options.missing("--profile") }
        if options.flags.contains("--password-stdin"), options.values["--password-file"] != nil {
            throw LoadSideError("arguments.password", "Choose one password input method.", recovery: "Use either --password-stdin or --password-file, or omit both for a hidden terminal prompt.")
        }
        let password: String
        if options.flags.contains("--password-stdin") {
            guard let value = readLine(strippingNewline: true) else {
                throw LoadSideError("credentials.password", "No password was supplied on standard input.", recovery: "Supply one line; an empty line is valid for an unprotected P12.")
            }
            password = value
        } else if let path = options.values["--password-file"]?.first {
            let url = URL(fileURLWithPath: path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            guard mode & 0o077 == 0 else {
                throw LoadSideError("credentials.permissions", "The password file is accessible to other users.", recovery: "Set its permissions to 600, or use the hidden terminal prompt.")
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 16_384, let value = String(data: data, encoding: .utf8) else {
                throw LoadSideError("credentials.password", "The password file must contain at most 16 KiB of UTF-8 text.")
            }
            password = value.hasSuffix("\r\n") ? String(value.dropLast(2)) : value.hasSuffix("\n") ? String(value.dropLast()) : value
        } else {
            guard isatty(STDIN_FILENO) == 1, let pointer = getpass("P12 password (hidden): ") else {
                throw LoadSideError("credentials.password", "An interactive terminal is required to enter the P12 password.", recovery: "Use --password-stdin or --password-file for automation. Password command-line arguments are intentionally unsupported.")
            }
            password = String(cString: pointer)
            memset(pointer, 0, strlen(pointer))
        }
        let policy = options.values["--entitlements"]?.first ?? "strict"
        guard let entitlementPolicy = EntitlementPolicy(rawValue: policy) else {
            throw LoadSideError("arguments.entitlements", "Unknown entitlement policy: \(policy)", recovery: "Use strict (default) or compatible (explicitly permit dropping unsupported capabilities).")
        }
        let identifierPolicyValue = options.values["--bundle-id-policy"]?.first ?? "automatic"
        guard let identifierPolicy = BundleIdentifierPolicy(rawValue: identifierPolicyValue) else {
            throw LoadSideError("arguments.bundleIdentifierPolicy", "Unknown bundle identifier policy: \(identifierPolicyValue)", recovery: "Use automatic (default) to resolve a unique authorized identifier, or preserve to require the app's current identifier. --bundle-id overrides either policy.")
        }
        let request = SigningRequest(
            ipa: ipa, certificate: certificate, password: password, profiles: profiles,
            injections: options.values["--inject", default: []].map { URL(fileURLWithPath: $0) }, output: output,
            bundleIdentifier: options.values["--bundle-id"]?.first,
            displayName: options.values["--name"]?.first, removeExtensions: options.flags.contains("--remove-extensions"), entitlementPolicy: entitlementPolicy,
            bundleIdentifierPolicy: identifierPolicy
        )
        let json = options.flags.contains("--json")
        let task = Task {
            try await SigningEngine().run(request, onEvent: { event in
                if json {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    if let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) { writeError(line + "\n") }
                } else {
                    writeError("[\(Int(event.fraction * 100))%] \(event.stage.title): \(event.message)\n")
                }
            })
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { task.cancel() }
        terminate.setEventHandler { task.cancel() }
        interrupt.resume(); terminate.resume()
        defer { interrupt.cancel(); terminate.cancel() }
        let result = try await task.value
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } else {
            print("Exported: \(result.output.path)")
            print("Bundle:   \(result.bundleIdentifier)")
            print("Signed:   \(result.signedCodeCount) code objects")
            print("SHA-256:  \(result.sha256)")
            for warning in result.warnings { writeError("warning: \(warning)\n") }
        }
    }

    static func doctor(arguments: [String]) throws {
        guard arguments.isEmpty else { throw LoadSideError("arguments.doctor", "doctor does not accept options.") }
        print("LoadSide \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        var missing: [String] = []
        for path in ["/usr/bin/codesign", "/usr/bin/security"] {
            let exists = FileManager.default.isExecutableFile(atPath: path)
            print("\(exists ? "OK" : "MISSING")  \(path)")
            if !exists { missing.append(path) }
        }
        print("OK  System libarchive linked")
        print("OK  Local signing engine available")
        print("Certificate validity and offline profile authorization are checked per job.")
        print("Current revocation status and target-device eligibility are not verified by export.")
        guard missing.isEmpty else { throw LoadSideError("environment.tools", "Required Apple tools are missing.", recovery: "Run LoadSide on a supported macOS installation.") }
    }

    static func inspectProfile(arguments: [String]) throws {
        guard arguments.count == 1 else { throw LoadSideError("arguments.profile", "Provide one mobileprovision path.", recovery: "Usage: loadside profile PROFILE.mobileprovision") }
        let profile = try ProvisioningProfile.inspect(URL(fileURLWithPath: arguments[0]))
        print("Name:       \(profile.name)")
        print("UUID:       \(profile.uuid)")
        print("Team:       \(profile.teamIdentifier)")
        print("App ID:     \(profile.applicationIdentifier)")
        print("Type:       \(profile.distribution)")
        print("Expires:    \(profile.expiresAt.formatted(.iso8601))")
        print("Devices:    \(profile.provisionsAllDevices ? "Enterprise distribution" : String(profile.deviceCount))")
        print("CMS signature and offline Apple trust validation passed. Current revocation status is not checked.")
    }

    static func writeError(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }

    static let help = """
    LoadSide — local IPA signing for macOS

    Usage:
      loadside sign --ipa APP.ipa --p12 IDENTITY.p12 --profile APP.mobileprovision --output SIGNED.ipa [options]
      loadside doctor
      loadside profile PROFILE.mobileprovision
      loadside version

    Required:
      --ipa PATH             Unsigned or previously signed, decrypted IPA
      --p12 PATH             Apple signing identity and private key (PKCS#12)
      --profile PATH         Provisioning profile; repeat for nested apps/extensions
      --output PATH          New IPA path; existing files are never overwritten

    Options:
      --inject PATH          .deb, .dylib, or .framework; repeat for dependencies
      --bundle-id ID         Explicitly set the root bundle identifier
      --bundle-id-policy P   automatic (default) resolves a unique authorized ID; preserve keeps the original
      --name TEXT            Change the application's display name
      --remove-extensions    Explicitly omit .appex bundles and their features
      --entitlements POLICY strict (default), or compatible to drop unauthorized claims
      --password-stdin       Read one password line from standard input
      --password-file PATH   Read a UTF-8 password file with owner-only permissions
      --json                Print result JSON to stdout and progress JSONL to stderr
      --help                Show this help

    With no password option, prompts in the terminal without echoing.
    Ctrl-C cancels the job and cleans temporary signing material.
    LoadSide does not decrypt apps, install to devices, or run DEB scripts.
    """
}

private struct Options {
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    static let valueOptions: Set<String> = ["--ipa", "--p12", "--profile", "--output", "--inject", "--bundle-id", "--bundle-id-policy", "--name", "--entitlements", "--password-file"]
    static let flagOptions: Set<String> = ["--password-stdin", "--json", "--remove-extensions"]
    static let repeatable: Set<String> = ["--profile", "--inject"]

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if Self.flagOptions.contains(option) {
                guard flags.insert(option).inserted else { throw LoadSideError("arguments.duplicate", "Repeated option: \(option)") }
                index += 1
            } else if Self.valueOptions.contains(option) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else { throw Self.missing(option) }
                guard Self.repeatable.contains(option) || values[option] == nil else { throw LoadSideError("arguments.duplicate", "Repeated option: \(option)") }
                values[option, default: []].append(arguments[index + 1])
                index += 2
            } else { throw LoadSideError("arguments.unknown", "Unknown option: \(option)", recovery: "Run loadside --help for supported options.") }
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
