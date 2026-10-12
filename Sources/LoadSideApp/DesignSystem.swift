import SwiftUI
import LoadSideCore

enum Studio {
    static let background = Color(red: 0.045, green: 0.06, blue: 0.085)
    static let sidebar = Color(red: 0.062, green: 0.08, blue: 0.11)
    static let surface = Color(red: 0.078, green: 0.099, blue: 0.132)
    static let raised = Color(red: 0.10, green: 0.125, blue: 0.162)
    static let line = Color.white.opacity(0.085)
    static let muted = Color(red: 0.55, green: 0.61, blue: 0.69)
    static let mint = Color(red: 0.42, green: 0.91, blue: 0.76)
    static let amber = Color(red: 0.98, green: 0.75, blue: 0.40)
    static let red = Color(red: 1.0, green: 0.45, blue: 0.47)
}

struct StudioCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Studio.line))
    }
}

struct CardHeading: View {
    let number: String
    let title: String
    var detail: String?
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Studio.mint)
                .frame(width: 27, height: 27)
                .background(Studio.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct StudioButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(primary ? Studio.background : Color.white.opacity(0.9))
            .background(primary ? Studio.mint : Studio.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? Color.clear : Studio.line))
            .opacity(!enabled ? 0.38 : (configuration.isPressed ? 0.72 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct InputLabel: View {
    let text: String
    var optional = false
    var body: some View {
        HStack {
            Text(text).font(.system(size: 12, weight: .medium))
            if optional { Text("OPTIONAL").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Studio.muted) }
        }
    }
}

struct FileRow: View {
    let url: URL
    var symbol = "doc"
    var remove: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Studio.mint).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(Studio.muted)
                    .help("Remove \(url.lastPathComponent)")
                    .accessibilityLabel("Remove \(url.lastPathComponent)")
            }
        }
        .padding(11)
        .background(Studio.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .help(url.path)
    }
}

struct StatusPill: View {
    let status: JobStatus
    var color: Color {
        switch status {
        case .completed: Studio.mint
        case .failed: Studio.red
        case .running: Studio.mint
        case .cancelled, .interrupted: Studio.amber
        }
    }
    var body: some View {
        Text(status.title).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.1), in: Capsule())
    }
}

struct NoticeView: View {
    let message: String
    var color = Studio.amber
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(color)
            Text(message).font(.system(size: 12)).foregroundStyle(color.opacity(0.95)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let description: String
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 33, weight: .light)).foregroundStyle(Studio.mint)
                .frame(width: 76, height: 76).background(Studio.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(description).font(.system(size: 13)).foregroundStyle(Studio.muted).multilineTextAlignment(.center).frame(maxWidth: 340)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

extension View {
    func studioField() -> some View {
        self.textFieldStyle(.plain).font(.system(size: 12)).padding(11)
            .background(Studio.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Studio.line))
    }
}
