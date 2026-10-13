import Foundation

/// Minimal in-memory tar and DEB builders for hostile-input and round-trip tests.
struct ArchiveFixtures {
    struct Entry { let path: String; var data: Data = Data(); var type: UInt8 = 48; var link: String = "" }
    static func tar(_ entries: [Entry]) -> Data {
        var result = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ string: String, _ offset: Int, _ width: Int) {
                for (index, byte) in string.utf8.prefix(width).enumerated() { header[offset + index] = byte }
            }
            field(entry.path, 0, 100); field("0000755", 100, 8); field("0000000", 108, 8); field("0000000", 116, 8)
            field(String(format: "%011o", entry.data.count), 124, 12); field("00000000000", 136, 12)
            field("        ", 148, 8); header[156] = entry.type; field(entry.link, 157, 100); field("ustar", 257, 6); field("00", 263, 2)
            field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", 148, 8)
            result.append(contentsOf: header); result.append(entry.data)
            result.append(Data(repeating: 0, count: (512 - entry.data.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1024)); return result
    }
    static func deb(data: Data) -> Data {
        var result = Data("!<arch>\n".utf8)
        for (name, contents) in [("debian-binary", Data("2.0\n".utf8)), ("data.tar", data)] {
            func padded(_ value: String, _ width: Int) -> String { value + String(repeating: " ", count: width - value.count) }
            result.append(Data((padded(name + "/", 16) + padded("0", 12) + padded("0", 6) + padded("0", 6) + padded("100644", 8) + padded(String(contents.count), 10) + "`\n").utf8))
            result.append(contents); if contents.count % 2 != 0 { result.append(10) }
        }
        return result
    }
}
