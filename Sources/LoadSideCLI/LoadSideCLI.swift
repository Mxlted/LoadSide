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
            case "inject": try await inject(arguments: Array(arguments.dropFirst()))
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
        let options = try CommandOptions(arguments)
        let ipa = try options.requiredURL("--ipa")
        let certificate = try options.requiredURL("--p12")
        let output = try options.requiredURL("--output")
        let profiles = options.values["--profile", default: []].map { URL(fileURLWithPath: $0) }
        guard !profiles.isEmpty else { throw CommandOptions.missing("--profile") }
        let policy = options.values["--entitlements"]?.first ?? "strict"
        guard let entitlementPolicy = EntitlementPolicy(rawValue: policy) else {
            throw LoadSideError("arguments.entitlements", "Unknown entitlement policy: \(policy)", recovery: "Use strict (default) or compatible (explicitly permit dropping unsupported capabilities).")
        }
        let identifierPolicyValue = options.values["--bundle-id-policy"]?.first ?? "preserve"
        guard let identifierPolicy = BundleIdentifierPolicy(rawValue: identifierPolicyValue) else {
            throw LoadSideError("arguments.bundleIdentifierPolicy", "Unknown bundle identifier policy: \(identifierPolicyValue)", recovery: "Use preserve (default) to keep the app's original identifier, or automatic to intentionally resolve a unique authorized identifier. --bundle-id overrides either policy.")
        }
        let password = try PasswordInput.read(options)
        let request = SigningRequest(
            ipa: ipa, certificate: certificate, password: password, profiles: profiles,
            injections: options.values["--inject", default: []].map { URL(fileURLWithPath: $0) }, output: output,
            bundleIdentifier: options.values["--bundle-id"]?.first,
            displayName: options.values["--name"]?.first, removeExtensions: options.flags.contains("--remove-extensions"), entitlementPolicy: entitlementPolicy,
            bundleIdentifierPolicy: identifierPolicy,
            extensionProfilePolicy: options.flags.contains("--require-matching-extension-profiles") ? .matching
                : options.flags.contains("--reuse-main-profile-for-extensions") ? .reuseMain : nil
        )
        let json = options.flags.contains("--json")
        let result = try await CommandSupport.run {
            try await SigningEngine().run(request) { event in
                CommandSupport.report(event, json: json)
            }
        }
        if json {
            try CommandSupport.printJSON(result)
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

    static func inject(arguments: [String]) async throws {
        let options = try CommandOptions(arguments)
        try options.validateForInjection()
        let request = InjectionRequest(ipa: try options.requiredURL("--ipa"),
            injections: options.values["--inject", default: []].map { URL(fileURLWithPath: $0) },
            output: try options.requiredURL("--output"), displayName: options.values["--name"]?.first,
            removeExtensions: options.flags.contains("--remove-extensions"))
        let json = options.flags.contains("--json")
        let result = try await CommandSupport.run {
            try await InjectionEngine().run(request) { event in
                CommandSupport.report(event, json: json)
            }
        }
        if json {
            try CommandSupport.printJSON(result)
        } else {
            print("Exported UNSIGNED: \(result.output.path)")
            print("Bundle:   \(result.bundleIdentifier)")
            print("Injected: \(result.injectedLibraryCount) libraries")
            print("SHA-256:  \(result.sha256)")
            print("Signing is still required before installation on a standard iOS device.")
            for warning in result.warnings { writeError("warning: \(warning)\n") }
        }
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
    LoadSide — local IPA signing and injection for macOS

    Usage:
      loadside sign --ipa APP.ipa --p12 IDENTITY.p12 --profile APP.mobileprovision --output SIGNED.ipa [options]
      loadside inject --ipa APP.ipa --inject TWEAK.deb --output APP-unsigned.ipa [--inject PATH] [--name TEXT] [--remove-extensions] [--json]
      loadside doctor
      loadside profile PROFILE.mobileprovision
      loadside version

    Required for sign:
      --ipa PATH             Unsigned or previously signed, decrypted IPA
      --p12 PATH             Apple signing identity and private key (PKCS#12)
      --profile PATH         Provisioning profile; repeat for nested apps/extensions
      --output PATH          New IPA path; existing files are never overwritten

    Options:
      --inject PATH          .deb, .dylib, or .framework; repeat for dependencies
      --bundle-id ID         Explicitly set the root bundle identifier
      --bundle-id-policy P   preserve (default) keeps the original; automatic resolves a unique authorized ID
                             Preserve can use an exact profile signing identity while keeping the metadata ID
      --name TEXT            Change the application's display name
      --remove-extensions    Explicitly omit .appex bundles and their features
      --reuse-main-profile-for-extensions
                             Default: retain eligible unmatched extensions with the main profile identity (experimental)
      --require-matching-extension-profiles
                             Require matching profiles for every retained extension; disables experimental reuse
      --entitlements POLICY strict (default), or compatible to drop unauthorized claims
                            Both omit and log known Apple-approval claims if unauthorized
      --password-stdin       Read one password line from standard input
      --password-file PATH   Read a UTF-8 password file with owner-only permissions
      --json                Print result JSON to stdout and progress JSONL to stderr
      --help                Show this help

    The inject command requires no certificate, profile, or password. It removes old
    signatures and exports an UNSIGNED IPA that must be signed before device installation.
    The sign command prompts in the terminal without echoing when no password option is given.
    Ctrl-C cancels the job and cleans temporary signing material.
    LoadSide does not decrypt apps, install to devices, or run DEB scripts.
    """
}
