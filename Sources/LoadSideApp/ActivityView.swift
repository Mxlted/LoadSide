import SwiftUI
import LoadSideCore

struct ActivityView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Every step, accounted for.").font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                    Text("Local signing history, verification results, and actionable diagnostics.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                }
                Spacer()
                if !model.history.isEmpty {
                    Button("Clear history") { confirmClear = true }.buttonStyle(StudioButtonStyle())
                }
            }
            if let storageNotice = model.storageNotice { NoticeView(message: storageNotice) }
            if model.history.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "Your first export starts here", description: "Signing sessions appear here with a complete event log and verification results. Nothing leaves this Mac.")
                Button("Open workspace") { model.section = .workspace }.buttonStyle(StudioButtonStyle(primary: true)).frame(maxWidth: .infinity).padding(.bottom, 40)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    ScrollView {
                        VStack(spacing: 9) {
                            ForEach(model.history) { job in
                                Button { model.selectedJobID = job.id } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Image(systemName: "shippingbox").foregroundStyle(Studio.mint)
                                            Spacer()
                                            StatusPill(status: job.status)
                                        }
                                        Text(job.sourceName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(2).truncationMode(.middle)
                                        Text(job.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Studio.muted)
                                    }
                                    .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedJob?.id == job.id ? Studio.mint.opacity(0.055) : Studio.surface, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.selectedJob?.id == job.id ? Studio.mint.opacity(0.30) : Studio.line))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(width: 220)
                    if let job = model.selectedJob {
                        ScrollView { jobDetail(job) }.frame(maxWidth: .infinity)
                    }
                }
            }
        }.padding(30)
        .alert("Clear local signing history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This removes saved event logs and verification records. Exported IPA files remain on disk. A running session is kept.")
        }
    }

    private func jobDetail(_ job: JobRecord) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text(job.result?.displayName ?? job.sourceName).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                        Spacer()
                        StatusPill(status: job.status)
                    }
                    HStack(spacing: 14) {
                        Text(job.startedAt.formatted(date: .abbreviated, time: .standard))
                        if let finished = job.finishedAt {
                            Text("\(String(format: "%.1f", finished.timeIntervalSince(job.startedAt))) seconds")
                        }
                    }.font(.system(size: 10)).foregroundStyle(Studio.muted)
                    Text("Session \(job.id.uuidString)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted).textSelection(.enabled)
                    if job.removeExtensions == true {
                        Label("App extension removal was requested for this session", systemImage: "minus.circle")
                            .font(.system(size: 11)).foregroundStyle(Studio.amber)
                    }
                    if let failure = job.failure {
                        NoticeView(message: failure, color: job.status == .failed ? Studio.red : Studio.amber)
                        if let recovery = job.recovery { Text(recovery).font(.system(size: 12)).foregroundStyle(Studio.muted).lineSpacing(3).textSelection(.enabled) }
                    }
                    if let result = job.result {
                        Rectangle().fill(Studio.line).frame(height: 1)
                        resultLine("Bundle ID", result.bundleIdentifier)
                        resultLine("Certificate", result.certificateName)
                        resultLine("Team", result.teamIdentifier)
                        resultLine("Signed code", "\(result.signedCodeCount) objects")
                        resultLine("Injection", "\(result.injectedLibraryCount) libraries")
                        resultLine("Export", result.output.path)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("SHA-256").font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(Studio.muted)
                            Text(result.sha256).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineSpacing(3).foregroundStyle(Studio.mint)
                        }
                        ForEach(result.warnings, id: \.self) { NoticeView(message: $0) }
                    }
                    HStack(spacing: 10) {
                        if job.status == .completed {
                            Button { model.reveal(job.output) } label: { Label("Show export", systemImage: "folder") }
                                .buttonStyle(StudioButtonStyle(primary: true))
                                .disabled(!FileManager.default.fileExists(atPath: job.output.path))
                                .help(FileManager.default.fileExists(atPath: job.output.path) ? "Reveal exported IPA in Finder" : "The exported file was moved or deleted")
                        }
                        Button { model.exportDiagnostics(job) } label: { Label("Save diagnostics", systemImage: "square.and.arrow.down") }
                            .buttonStyle(StudioButtonStyle())
                    }
                }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Event log").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(job.events.count) EVENTS").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.7).foregroundStyle(Studio.muted)
                    }
                    if job.events.isEmpty {
                        Text("Waiting for pipeline events…").font(.system(size: 12)).foregroundStyle(Studio.muted)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(job.events) { event in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(event.date.formatted(date: .omitted, time: .standard)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted).frame(width: 72, alignment: .leading)
                                    Circle().fill(event.level == .error ? Studio.red : event.level == .warning ? Studio.amber : Studio.mint.opacity(0.7)).frame(width: 5, height: 5).padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(event.stage.title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Studio.muted)
                                        Text(event.message).font(.system(size: 11, design: .monospaced)).foregroundStyle(event.level == .error ? Studio.red : event.level == .warning ? Studio.amber : .white.opacity(0.85)).lineSpacing(3).textSelection(.enabled)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 11)
                                Rectangle().fill(Studio.line).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func resultLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 11)).foregroundStyle(Studio.muted).frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
