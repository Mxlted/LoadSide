import LoadSideCore
import XCTest

@testable import LoadSideCLI

final class CommandOptionsTests: XCTestCase {
    func testRepeatedProfilesAndInjectionsPreserveInputOrder() throws {
        let options = try CommandOptions([
            "--profile", "main.mobileprovision", "--profile", "extension.mobileprovision",
            "--inject", "first.dylib", "--inject", "second.dylib", "--json"
        ])
        XCTAssertEqual(options.values["--profile"], ["main.mobileprovision", "extension.mobileprovision"])
        XCTAssertEqual(options.values["--inject"], ["first.dylib", "second.dylib"])
        XCTAssertEqual(options.flags, ["--json"])
    }

    func testUnknownDuplicateAndMissingOptionsKeepSpecificDiagnostics() {
        for arguments in [["--unknown"], ["--password", "must-not-be-an-argument"]] {
            assertError("arguments.unknown") { _ = try CommandOptions(arguments) }
        }
        for arguments in [["--json", "--json"], ["--ipa", "one.ipa", "--ipa", "two.ipa"]] {
            assertError("arguments.duplicate") { _ = try CommandOptions(arguments) }
        }
        for arguments in [["--ipa"], ["--ipa", ""], ["--ipa", "--json"]] {
            assertError("arguments.missing") { _ = try CommandOptions(arguments) }
        }
        assertError("arguments.missing") { _ = try CommandOptions([]).requiredURL("--ipa") }
    }

    func testConflictingExtensionPoliciesAreRejectedBeforeRequiredInputs() {
        for conflict in ["--require-matching-extension-profiles", "--remove-extensions"] {
            assertError("arguments.extensionPolicy") {
                _ = try CommandOptions(["--reuse-main-profile-for-extensions", conflict])
            }
        }
    }

    func testInjectionRejectsEverySigningOptionWithoutReadingCredentials() throws {
        let signingValues = ["--p12", "--profile", "--bundle-id", "--bundle-id-policy", "--entitlements", "--password-file"]
        for option in signingValues {
            assertError("arguments.inject") {
                try CommandOptions([option, "unused"]).validateForInjection()
            }
        }
        for flag in ["--password-stdin", "--reuse-main-profile-for-extensions", "--require-matching-extension-profiles"] {
            assertError("arguments.inject") {
                try CommandOptions([flag]).validateForInjection()
            }
        }
        try CommandOptions([
            "--ipa", "input.ipa", "--inject", "tweak.dylib", "--output", "output.ipa",
            "--name", "Example", "--json", "--remove-extensions"
        ]).validateForInjection()
    }

    private func assertError(_ code: String, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, code, file: file, line: line)
        }
    }
}
