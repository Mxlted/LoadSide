import Foundation
import XCTest
@testable import LoadSideCore

final class ModelsTests: XCTestCase {
    func testEventRedactionPreservesEngineIdentityAndTiming() throws {
        let event = SigningEvent(stage: .credentials, fraction: 0.25, message: "password secret repeated secret", level: .warning)
        let redacted = event.redacting(secret: "secret")

        XCTAssertEqual(redacted.message, "password [redacted] repeated [redacted]")
        XCTAssertEqual(redacted.id, event.id)
        XCTAssertEqual(redacted.date, event.date)
        XCTAssertEqual(redacted.stage, event.stage)
        XCTAssertEqual(redacted.fraction, event.fraction)
        XCTAssertEqual(redacted.level, event.level)
        XCTAssertEqual(event.message, "password secret repeated secret")

        let restored = try JSONDecoder().decode(SigningEvent.self, from: JSONEncoder().encode(redacted))
        XCTAssertEqual(restored.id, event.id)
        XCTAssertEqual(restored.date, event.date)
        XCTAssertEqual(restored.message, redacted.message)
    }

    func testEmptyOrAbsentSecretLeavesEventUnchanged() {
        let event = SigningEvent(stage: .signing, fraction: 0.5, message: "Signing a nested framework")
        for secret in ["", "absent"] {
            let redacted = event.redacting(secret: secret)
            XCTAssertEqual(redacted.id, event.id)
            XCTAssertEqual(redacted.date, event.date)
            XCTAssertEqual(redacted.message, event.message)
        }
    }
}
