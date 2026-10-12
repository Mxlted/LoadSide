import AppKit
import SwiftUI
import LoadSideCore

/// Semantic colors follow macOS appearance and keep validation states distinct.
enum Palette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let field = Color(nsColor: .textBackgroundColor)
    static let separator = Color.primary.opacity(0.09)
    static let accent = Color(red: 0.39, green: 0.46, blue: 0.91)
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.separator))
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

struct FileRow: View {
    let url: URL
    var symbol = "doc"
    var showDirectory = false
    var remove: (() -> Void)?
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if showDirectory {
                    Text(url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 2)
            if let remove { RemoveButton(label: "Remove \(url.lastPathComponent)", action: remove) }
        }.help(url.path)
    }
}

struct RemoveButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

struct StatusPill: View {
    let status: JobStatus
    var color: Color {
        switch status {
        case .completed: Palette.success
        case .failed: Palette.error
        case .running: Palette.accent
        case .cancelled, .interrupted: Palette.warning
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(status.title).font(.system(size: 11, weight: .medium))
        }.foregroundStyle(color).accessibilityElement(children: .combine)
    }
}

struct InlineNotice: View {
    let message: String
    var color: Color = Palette.warning
    var symbol = "exclamationmark.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let description: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 3)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(description).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    var monospaced = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            Text(value).font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
    }
}

extension View {
    func inputField() -> some View {
        self.textFieldStyle(.roundedBorder).font(.system(size: 12))
    }
}
