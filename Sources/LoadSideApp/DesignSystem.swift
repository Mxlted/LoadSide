import AppKit
import LoadSideCore
import SwiftUI

/// Shared dimensions keep the roomier app layout consistent across sections.
enum AppMetrics {
    static let minimumWindowSize = CGSize(width: 1056, height: 660)
    static let defaultWindowSize = CGSize(width: 1408, height: 792)
    static let sidebarWidth: CGFloat = 216
    static let pagePadding: CGFloat = 24
    static let workspaceColumnsWidth: CGFloat = 900
    static let iconButtonSize: CGFloat = 30
}

/// Semantic colors follow macOS appearance and keep validation states distinct.
enum Palette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let field = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor).opacity(0.45)
    static let accent = Color.accentColor
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)
}

struct Panel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var padding: CGFloat = 20
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : .clear))
    }
}

struct PageHeading: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    var color: Color = .secondary
    var size: CGFloat = 44
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FileRow: View {
    let url: URL
    var symbol = "doc"
    var showDirectory = false
    var remove: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if showDirectory {
                    Text(url.deletingLastPathComponent().path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
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
                .frame(width: AppMetrics.iconButtonSize, height: AppMetrics.iconButtonSize).contentShape(Rectangle())
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
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.title).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct InlineNotice: View {
    let message: String
    var color: Color = Palette.warning
    var symbol = "exclamationmark.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, 1).accessibilityHidden(true)
            Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let description: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 13) {
            SymbolTile(symbol: symbol, size: 56).padding(.bottom, 3)
            Text(title).font(.title2.weight(.semibold))
            Text(description).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineSpacing(3).frame(maxWidth: 418)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 5)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(33)
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    var monospaced = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 15) {
            Text(label).foregroundStyle(.secondary).frame(width: 128, alignment: .leading)
            Text(value).font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
}

/// Glass belongs to the control layer; form panels intentionally remain opaque.
private struct FloatingControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Palette.separator))
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

extension View {
    func inputField() -> some View {
        self.textFieldStyle(.roundedBorder).font(.system(size: 13))
    }

    func floatingControlSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(FloatingControlSurface(cornerRadius: cornerRadius))
    }

}

/// Shared across the app so the whole disclosure header is one accessible control.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var headerVerticalPadding: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, headerVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Expand or collapse section")
            if configuration.isExpanded {
                configuration.content
                    // SwiftUI resets the style inside disclosure content; keep nested rows consistent.
                    .disclosureGroupStyle(self)
            }
        }
    }
}
