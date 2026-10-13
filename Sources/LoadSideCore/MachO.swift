import Foundation

public struct MachOSlice: Sendable {
    public let cpuType: UInt32
    public let cpuSubtype: UInt32
    public let fileType: UInt32
    public let isEncrypted: Bool
    public let dependencies: [String]
    public let installName: String?
    public let rpaths: [String]
    public let platform: UInt32?
    /// Structural presence of LC_CODE_SIGNATURE, regardless of payload validity.
    public let hasCodeSignature: Bool
    public var architecture: String {
        switch cpuType {
        case 0x0100000c: return cpuSubtype & 0x00ffffff == 2 ? "arm64e" : "arm64"
        case 12: return "arm-\(cpuSubtype & 0x00ffffff)"
        case 0x01000007: return "x86_64"
        case 7: return "i386"
        default: return "cpu-\(cpuType)-\(cpuSubtype)"
        }
    }
}
public struct MachOInfo: Sendable {
    public let slices: [MachOSlice]
    public var isEncrypted: Bool { slices.contains(where: \.isEncrypted) }
    public var hasCodeSignature: Bool { slices.contains(where: \.hasCodeSignature) }
    public var architectures: [String] { slices.map(\.architecture) }
}

/// A bounds-checked Mach-O reader and conservative header editor. It never moves code or link-edit data.
public enum MachO {
    private struct Command {
        let kind: UInt32
        let bytes: [UInt8]
        let string: String?
    }
    private struct ParsedSlice {
        let offset: Int
        let size: Int
        let little: Bool
        let is64: Bool
        let headerSize: Int
        let commandSize: Int
        let commands: [Command]
        let contentStart: Int?
        let info: MachOSlice
    }
    private static let dylibCommands: Set<UInt32> = [0xc, 0x18 | 0x80000000, 0x1f | 0x80000000, 0x20, 0x23 | 0x80000000]

    public static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(
            read32(Array(data), 0, false))
    }
    public static func inspect(_ url: URL) throws -> MachOInfo { try inspect(data: readFile(url)) }
    public static func inspect(data: Data) throws -> MachOInfo { MachOInfo(slices: try parse(Array(data)).map(\.info)) }
    public static func addDylib(path: String, to url: URL) throws {
        try edit(url, replacements: [:], installName: nil, addedDependency: path)
    }
    public static func rewrite(_ url: URL, dependencies: [String: String], installName: String? = nil) throws {
        try edit(url, replacements: dependencies, installName: installName, addedDependency: nil)
    }

    private static func readFile(_ url: URL) throws -> Data {
        try BoundedFile.read(
            url, maximumBytes: 512 * 1_024 * 1_024,
            invalid: LoadSideError("macho.limit", "Mach-O input must be a regular file no larger than 512 MiB: \(url.lastPathComponent)"))
    }
    private static func edit(_ url: URL, replacements: [String: String], installName: String?, addedDependency: String?) throws {
        try Task.checkCancellation()
        var bytes = Array(try readFile(url))
        let slices = try parse(bytes)
        for slice in slices {
            guard !slice.info.isEncrypted else {
                throw LoadSideError("macho.encrypted", "Encrypted Mach-O code cannot be modified. Supply a decrypted IPA.")
            }
            var commands: [UInt8] = []
            var count = slice.commands.count
            for command in slice.commands {
                let replacement: String?
                if command.kind == 0xd {
                    replacement = installName
                } else if dylibCommands.contains(command.kind), let name = command.string {
                    replacement = replacements[name]
                } else {
                    replacement = nil
                }
                if let replacement, replacement != command.string {
                    commands += try stringCommand(
                        kind: command.kind, name: replacement, original: command.bytes, little: slice.little, alignment: slice.is64 ? 8 : 4)
                } else {
                    commands += command.bytes
                }
            }
            if let addedDependency, !slice.info.dependencies.contains(addedDependency) {
                commands += try stringCommand(
                    kind: 0xc, name: addedDependency, original: [UInt8](repeating: 0, count: 24), little: slice.little,
                    alignment: slice.is64 ? 8 : 4)
                count += 1
            }
            let oldEnd = slice.offset + slice.headerSize + slice.commandSize
            let newEnd = slice.offset + slice.headerSize + commands.count
            if commands.count > slice.commandSize {
                guard let contentStart = slice.contentStart, newEnd <= slice.offset + contentStart,
                    bytes[oldEnd..<newEnd].allSatisfy({ $0 == 0 })
                else {
                    throw LoadSideError(
                        "macho.headerPadding",
                        "\(url.lastPathComponent) has insufficient verified Mach-O header padding for \(slice.info.architecture).",
                        recovery:
                            "Rebuild this binary with additional linker header padding (-headerpad_max_install_names). LoadSide will not move machine code or invalidate offsets."
                    )
                }
            }
            bytes.replaceSubrange((slice.offset + slice.headerSize)..<newEnd, with: commands)
            if newEnd < oldEnd { bytes.replaceSubrange(newEnd..<oldEnd, with: repeatElement(UInt8(0), count: oldEnd - newEnd)) }
            put32(&bytes, slice.offset + 16, UInt32(count), slice.little)
            put32(&bytes, slice.offset + 20, UInt32(commands.count), slice.little)
        }
        _ = try parse(bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try Data(bytes).write(to: url, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }
    private static func stringCommand(kind: UInt32, name: String, original: [UInt8], little: Bool, alignment: Int) throws -> [UInt8] {
        guard !name.isEmpty, !name.utf8.contains(0), name.utf8.count < 4096 else { throw invalid("Invalid dylib install name.") }
        let size = (24 + name.utf8.count + 1 + alignment - 1) / alignment * alignment
        var bytes = [UInt8](repeating: 0, count: size)
        for index in 12..<24 { bytes[index] = original[index] }
        put32(&bytes, 0, kind, little)
        put32(&bytes, 4, UInt32(size), little)
        put32(&bytes, 8, 24, little)
        bytes.replaceSubrange(24..<(24 + name.utf8.count), with: name.utf8)
        return bytes
    }
    private static func parse(_ bytes: [UInt8]) throws -> [ParsedSlice] {
        guard bytes.count >= 4 else { throw invalid("File is too short for a Mach-O header.") }
        let magic = read32(bytes, 0, false)
        if [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            guard bytes.count >= 8 else { throw invalid("Truncated universal header.") }
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let is64 = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(read32(bytes, 4, little))
            let stride = is64 ? 32 : 20
            guard count > 0, count <= 64, count <= (bytes.count - 8) / stride else {
                throw invalid("Invalid universal architecture table.")
            }
            let tableEnd = 8 + count * stride
            var ranges: [Range<Int>] = []
            var result: [ParsedSlice] = []
            var architectures = Set<String>()
            for index in 0..<count {
                let p = 8 + index * stride
                let rawOffset = is64 ? read64(bytes, p + 8, little) : UInt64(read32(bytes, p + 8, little))
                let rawSize = is64 ? read64(bytes, p + 16, little) : UInt64(read32(bytes, p + 12, little))
                let alignment = read32(bytes, p + (is64 ? 24 : 16), little)
                guard rawOffset <= UInt64(bytes.count), rawSize <= UInt64(bytes.count) - rawOffset,
                    rawOffset >= UInt64(tableEnd), rawSize >= 28, alignment <= 30,
                    rawOffset % (UInt64(1) << alignment) == 0
                else { throw invalid("Universal slice exceeds file bounds or has invalid alignment.") }
                let offset = Int(rawOffset)
                let size = Int(rawSize)
                let range = Int(rawOffset)..<Int(rawOffset + rawSize)
                guard !ranges.contains(where: { $0.overlaps(range) }) else { throw invalid("Overlapping universal slices.") }
                ranges.append(range)
                let slice = try parseSlice(bytes, offset, size)
                guard slice.info.cpuType == read32(bytes, p, little), slice.info.cpuSubtype == read32(bytes, p + 4, little) else {
                    throw invalid("Universal architecture does not match its Mach-O header.")
                }
                let architecture = "\(slice.info.cpuType):\(slice.info.cpuSubtype)"
                guard architectures.insert(architecture).inserted else { throw invalid("Duplicate universal architecture.") }
                result.append(slice)
            }
            return result
        }
        return [try parseSlice(bytes, 0, bytes.count)]
    }
    private static func parseSlice(_ bytes: [UInt8], _ offset: Int, _ size: Int) throws -> ParsedSlice {
        guard size >= 28 else { throw invalid("Truncated Mach-O header.") }
        let magic = read32(bytes, offset, false)
        guard [UInt32(0xfeedface), 0xfeedfacf, 0xcefaedfe, 0xcffaedfe].contains(magic) else { throw invalid("Unsupported Mach-O magic.") }
        let little = magic == 0xcefaedfe || magic == 0xcffaedfe
        let is64 = magic == 0xfeedfacf || magic == 0xcffaedfe
        let header = is64 ? 32 : 28
        guard size >= header else { throw invalid("Truncated Mach-O header.") }
        let count = Int(read32(bytes, offset + 16, little))
        let commandSize = Int(read32(bytes, offset + 20, little))
        guard commandSize <= size - header, commandSize <= 16 * 1_024 * 1_024, count <= commandSize / 8, count <= 65_536 else {
            throw invalid("Invalid Mach-O command table bounds.")
        }
        let commandEnd = offset + header + commandSize
        var cursor = offset + header
        var commands: [Command] = []
        var dependencies: [String] = []
        var rpaths: [String] = []
        var encrypted = false
        var installName: String?
        var platform: UInt32?
        var contentStart: Int?
        var textRange: Range<Int>?
        var firstTextSection: Int?
        func reference(_ start: UInt64, _ length: UInt64) throws {
            if length == 0 { return }
            guard start >= UInt64(header + commandSize), start <= UInt64(size), length <= UInt64(size) - start else {
                throw invalid("Mach-O payload overlaps headers or exceeds slice bounds.")
            }
            contentStart = min(contentStart ?? Int(start), Int(start))
        }
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor <= commandEnd - 8 else { throw invalid("Truncated Mach-O load command.") }
            let kind = read32(bytes, cursor, little)
            let length = Int(read32(bytes, cursor + 4, little))
            guard length >= 8, length % (is64 ? 8 : 4) == 0, length <= commandEnd - cursor else {
                throw invalid("Invalid Mach-O command size.")
            }
            var name: String?
            if dylibCommands.contains(kind) || kind == 0xd || kind == 0x8000001c {
                let minimum = kind == 0x8000001c ? 12 : 24
                guard length >= minimum else { throw invalid("Truncated dylib or runtime path command.") }
                let start = Int(read32(bytes, cursor + 8, little))
                guard start >= minimum, start < length, let end = bytes[(cursor + start)..<(cursor + length)].firstIndex(of: 0),
                    let string = String(bytes: bytes[(cursor + start)..<end], encoding: .utf8), !string.isEmpty
                else { throw invalid("Malformed dylib or runtime path string.") }
                name = string
                if kind == 0xd {
                    installName = string
                } else if kind == 0x8000001c {
                    rpaths.append(string)
                } else {
                    dependencies.append(string)
                }
            }
            if kind == 0x21 || kind == 0x2c {
                guard length >= (kind == 0x2c ? 24 : 20) else { throw invalid("Truncated encryption command.") }
                encrypted = encrypted || read32(bytes, cursor + 16, little) != 0
                try reference(UInt64(read32(bytes, cursor + 8, little)), UInt64(read32(bytes, cursor + 12, little)))
            }
            // File offsets in every common payload-bearing load command constrain usable header padding.
            if [UInt32(0x1d), 0x1e, 0x26, 0x29, 0x2b, 0x2e, 0x80000033, 0x80000034, 0x36, 0x37, 0x38].contains(kind) {
                guard length >= 16 else { throw invalid("Truncated link-edit command.") }
                try reference(UInt64(read32(bytes, cursor + 8, little)), UInt64(read32(bytes, cursor + 12, little)))
            } else if kind == 2 {
                guard length >= 24 else { throw invalid("Truncated symbol table command.") }
                try reference(UInt64(read32(bytes, cursor + 8, little)), UInt64(read32(bytes, cursor + 12, little)) * (is64 ? 16 : 12))
                try reference(UInt64(read32(bytes, cursor + 16, little)), UInt64(read32(bytes, cursor + 20, little)))
            } else if kind == 0xb {
                guard length >= 80 else { throw invalid("Truncated dynamic symbol table command.") }
                for (position, width) in [(32, 8), (40, is64 ? 56 : 52), (48, 4), (56, 4), (64, 8), (72, 8)] {
                    try reference(
                        UInt64(read32(bytes, cursor + position, little)),
                        UInt64(read32(bytes, cursor + position + 4, little)) * UInt64(width))
                }
            } else if kind == 0x22 || kind == 0x80000022 {
                guard length >= 48 else { throw invalid("Truncated dyld information command.") }
                for position in stride(from: 8, to: 48, by: 8) {
                    try reference(UInt64(read32(bytes, cursor + position, little)), UInt64(read32(bytes, cursor + position + 4, little)))
                }
            } else if kind == 0x80000028 {
                guard length >= 24 else { throw invalid("Truncated entry point command.") }
                try reference(read64(bytes, cursor + 8, little), 1)
            } else if kind == 0x31 {
                guard length >= 40 else { throw invalid("Truncated note command.") }
                try reference(read64(bytes, cursor + 24, little), read64(bytes, cursor + 32, little))
            } else if kind == 3 || kind == 0x16 {
                guard length >= 16 else { throw invalid("Truncated symbol metadata command.") }
                try reference(
                    UInt64(read32(bytes, cursor + 8, little)), UInt64(read32(bytes, cursor + 12, little)) * (kind == 0x16 ? 4 : 1))
            }
            if kind == 0x32 {
                guard length >= 24, Int(read32(bytes, cursor + 20, little)) <= (length - 24) / 8 else {
                    throw invalid("Malformed build version command.")
                }
                platform = read32(bytes, cursor + 8, little)
            } else if [UInt32(0x25), 0x24, 0x2f, 0x30].contains(kind) {
                guard length >= 16 else { throw invalid("Truncated minimum OS version command.") }
                platform = [UInt32(0x25): UInt32(2), 0x24: 1, 0x2f: 3, 0x30: 4][kind]
            }
            if kind == 1 || kind == 0x19 {
                let segment64 = kind == 0x19
                let base = segment64 ? 72 : 56
                let sectionSize = segment64 ? 80 : 68
                guard length >= base, segment64 == is64 else { throw invalid("Truncated or incompatible segment command.") }
                let sectionCount = Int(read32(bytes, cursor + (segment64 ? 64 : 48), little))
                guard sectionCount <= (length - base) / sectionSize else { throw invalid("Section table exceeds segment command.") }
                let fileOffset = segment64 ? read64(bytes, cursor + 40, little) : UInt64(read32(bytes, cursor + 32, little))
                let fileSize = segment64 ? read64(bytes, cursor + 48, little) : UInt64(read32(bytes, cursor + 36, little))
                guard fileOffset <= UInt64(size), fileSize <= UInt64(size) - fileOffset else {
                    throw invalid("Segment exceeds Mach-O slice bounds.")
                }
                let segName = String(bytes: bytes[(cursor + 8)..<(cursor + 24)].prefix(while: { $0 != 0 }), encoding: .utf8)
                if segName == "__TEXT", fileOffset == 0, fileSize >= UInt64(header + commandSize) { textRange = 0..<Int(fileSize) }
                for index in 0..<sectionCount {
                    let section = cursor + base + index * sectionSize
                    let sectionLength = segment64 ? read64(bytes, section + 40, little) : UInt64(read32(bytes, section + 36, little))
                    let start = UInt64(read32(bytes, section + (segment64 ? 48 : 40), little))
                    let flags = read32(bytes, section + (segment64 ? 64 : 56), little) & 0xff
                    if sectionLength > 0 && ![UInt32(1), 0xc, 0x12].contains(flags) {
                        guard start >= UInt64(header + commandSize), start <= UInt64(size), sectionLength <= UInt64(size) - start,
                            start >= fileOffset, start + sectionLength <= fileOffset + fileSize
                        else { throw invalid("File-backed section overlaps headers or exceeds segment bounds.") }
                        try reference(start, sectionLength)
                        if segName == "__TEXT", fileOffset == 0 { firstTextSection = min(firstTextSection ?? Int(start), Int(start)) }
                    }
                    try reference(
                        UInt64(read32(bytes, section + (segment64 ? 56 : 48), little)),
                        UInt64(read32(bytes, section + (segment64 ? 60 : 52), little)) * 8)
                }
            }
            commands.append(Command(kind: kind, bytes: Array(bytes[cursor..<(cursor + length)]), string: name))
            cursor += length
        }
        guard cursor == commandEnd else { throw invalid("Load command sizes do not match sizeofcmds.") }
        // Header expansion is allowed only before a verified section inside the mapped __TEXT segment.
        if let start = contentStart, let firstTextSection, let textRange, textRange.contains(firstTextSection) {
            contentStart = min(start, firstTextSection)
        } else {
            contentStart = nil
        }
        return ParsedSlice(
            offset: offset, size: size, little: little, is64: is64, headerSize: header, commandSize: commandSize, commands: commands,
            contentStart: contentStart,
            info: MachOSlice(
                cpuType: read32(bytes, offset + 4, little), cpuSubtype: read32(bytes, offset + 8, little),
                fileType: read32(bytes, offset + 12, little), isEncrypted: encrypted, dependencies: dependencies, installName: installName,
                rpaths: rpaths, platform: platform,
                hasCodeSignature: commands.contains { $0.kind == 0x1d }))
    }
    private static func read32(_ bytes: [UInt8], _ offset: Int, _ little: Bool) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << ((little ? index : 3 - index) * 8) }
        return value
    }
    private static func read64(_ bytes: [UInt8], _ offset: Int, _ little: Bool) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << ((little ? index : 7 - index) * 8) }
        return value
    }
    private static func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32, _ little: Bool) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((little ? index : 3 - index) * 8)) }
    }
    private static func invalid(_ message: String) -> LoadSideError { LoadSideError("macho.invalid", message) }
}
