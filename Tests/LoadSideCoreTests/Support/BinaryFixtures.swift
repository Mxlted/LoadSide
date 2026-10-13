import Foundation

/// Synthetic Mach-O bytes and private scratch directories shared by engine tests.
struct BinaryFixtures {
    static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    static func put64(_ value: UInt64, at offset: Int, in bytes: inout [UInt8]) {
        for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    static func dylibCommand(_ name: String, kind: UInt32 = 0xc) -> [UInt8] {
        let length = (24 + name.utf8.count + 1 + 7) / 8 * 8
        var result = [UInt8](repeating: 0, count: length)
        put32(kind, at: 0, in: &result); put32(UInt32(length), at: 4, in: &result); put32(24, at: 8, in: &result)
        result.replaceSubrange(24..<(24 + name.utf8.count), with: name.utf8)
        return result
    }
    static func macho(fileType: UInt32 = 2, dependency: String? = nil, encrypted: Bool = false, padding: Bool = true, subtype: UInt32 = 0) -> Data {
        var commands = [UInt8](repeating: 0, count: 152)
        put32(0x19, at: 0, in: &commands); put32(152, at: 4, in: &commands)
        commands.replaceSubrange(8..<14, with: "__TEXT".utf8)
        put32(1, at: 64, in: &commands)
        commands.replaceSubrange(72..<78, with: "__text".utf8)
        commands.replaceSubrange(88..<94, with: "__TEXT".utf8)
        put64(16, at: 112, in: &commands)
        var count: UInt32 = 1
        if let dependency { commands += dylibCommand(dependency); count += 1 }
        if fileType == 6 { commands += dylibCommand("/usr/lib/fixture.dylib", kind: 0xd); count += 1 }
        if encrypted {
            var command = [UInt8](repeating: 0, count: 24)
            put32(0x2c, at: 0, in: &command); put32(24, at: 4, in: &command); put32(1, at: 16, in: &command)
            commands += command; count += 1
        }
        let section = padding ? 4096 : 32 + commands.count
        put64(UInt64(section + 16), at: 48, in: &commands)
        put32(UInt32(section), at: 120, in: &commands)
        var bytes = [UInt8](repeating: 0, count: section + 16)
        put32(0xfeedfacf, at: 0, in: &bytes); put32(0x0100000c, at: 4, in: &bytes); put32(subtype, at: 8, in: &bytes)
        put32(fileType, at: 12, in: &bytes); put32(count, at: 16, in: &bytes); put32(UInt32(commands.count), at: 20, in: &bytes)
        bytes.replaceSubrange(32..<(32 + commands.count), with: commands)
        bytes.replaceSubrange(section..<(section + 16), with: repeatElement(UInt8(0xaa), count: 16))
        return Data(bytes)
    }
    static func machoWithMalformedSignature() -> Data {
        var bytes = Array(macho())
        // A bounds-valid load command points to an invalid signature payload.
        let signatureOffset = bytes.count
        bytes += [UInt8](repeating: 0, count: 32)
        put32(2, at: 16, in: &bytes)
        put32(168, at: 20, in: &bytes)
        put32(0x1d, at: 184, in: &bytes)
        put32(16, at: 188, in: &bytes)
        put32(UInt32(signatureOffset), at: 192, in: &bytes)
        put32(32, at: 196, in: &bytes)
        return Data(bytes)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loadside-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}
