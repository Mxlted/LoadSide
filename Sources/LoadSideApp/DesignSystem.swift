import AppKit
import SwiftUI
import LoadSideCore

/// Semantic colors follow macOS appearance and keep validation states distinct.
enum Palette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let field = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor).opacity(0.45)
    static let accent = Color.accentColor
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)
}

struct Panel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var padding: CGFloat = 18
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.primary.opacity(0.45) : Palette.separator))
    }
}

struct PageHeading: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 23, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    var color: Color = Palette.accent
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
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
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
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
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct InlineNotice: View {
    let message: String
    var color: Color = Palette.warning
    var symbol = "exclamationmark.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, 1).accessibilityHidden(true)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let description: String
    var body: some View {
        VStack(spacing: 12) {
            SymbolTile(symbol: symbol, size: 64).padding(.bottom, 6)
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(description).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineSpacing(3).frame(maxWidth: 380)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    var monospaced = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(.secondary).frame(width: 116, alignment: .leading)
            Text(value).font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}

/// Glass belongs to the control layer; form panels intentionally remain opaque.
private struct FloatingControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Palette.separator))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                materialSurface(content)
            }
            #else
            materialSurface(content)
            #endif
        }
    }

    private func materialSurface(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Palette.separator))
    }
}

private struct AdaptiveGlassButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder private func fallback(_ content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(.bordered) }
    }
}

extension View {
    func inputField() -> some View {
        self.textFieldStyle(.roundedBorder).font(.system(size: 12))
    }

    func floatingControlSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(FloatingControlSurface(cornerRadius: cornerRadius))
    }

    func adaptiveGlassButton(prominent: Bool = false) -> some View {
        modifier(AdaptiveGlassButton(prominent: prominent))
    }
}
