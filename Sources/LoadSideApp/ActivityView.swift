import SwiftUI
import LoadSideCore

struct ActivityView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var confirmClear = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                PageHeading(title: "Activity", detail: "Signed and unsigned exports, verification details, and logs.")
                Spacer()
                if !model.history.isEmpty {
                    Button("Clear History…") { confirmClear = true }.adaptiveGlassButton()
                }
            }.padding(22)
            if let notice = model.storageNotice { InlineNotice(message: notice).padding(.horizontal, 24).padding(.bottom, 15) }
            if model.history.isEmpty {
                EmptyState(symbol: "clock", title: "No export activity", description: "Exports appear here with verification details, warnings, and a diagnostic log.")
            } else {
                HSplitView {
                    List(selection: Binding<UUID?>(
                        get: { model.selectedJob?.id },
                        set: { model.selectedJobID = $0 }
                    )) {
                        ForEach(model.history) { job in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(job.sourceName).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.middle)
                                StatusPill(status: job.status)
                                if job.jobMode == .injectOnly {
                                    Text("Inject only · Unsigned").font(.system(size: 10)).foregroundStyle(Palette.warning)
                                }
                                Text(job.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 9).tag(job.id)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 300)
                    if let job = model.selectedJob {
                        ScrollView { JobDetailView(model: model, job: job).padding(20) }.frame(minWidth: 380, maxWidth: .infinity)
                    }
                }
            }
        }
        .alert("Clear local export history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: { Text("This removes saved event logs and verification records. Exported IPA files remain on disk. A running session is kept.") }
    }
}

private struct JobDetailView: View {
    @ObservedObject var model: WorkspaceModel
    let job: JobRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(job.result?.displayName ?? job.injectionResult?.displayName ?? job.sourceName).font(.system(size: 21, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                    Text(job.startedAt.formatted(date: .abbreviated, time: .standard)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(status: job.status)
            }
            if job.status == .running {
                ProgressView(value: job.events.map(\.fraction).max() ?? 0)
                Text(job.events.last?.message ?? "Preparing export…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let failure = job.failure { InlineNotice(message: failure, color: job.status == .failed ? Palette.error : Palette.warning) }
            if let recovery = job.recovery { Text(recovery).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            if job.injectionResult != nil {
                InlineNotice(message: "This IPA is unsigned. Injection and archive checks completed, but signing is required before installation.", symbol: "signature")
            }
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    MetadataRow(label: "Workflow", value: job.jobMode == .injectOnly ? "Inject only · unsigned export" : "Sign and export")
                    if let result = job.result {
                        MetadataRow(label: "Bundle ID", value: result.bundleIdentifier, monospaced: true)
                        MetadataRow(label: "Certificate", value: result.certificateName)
                        MetadataRow(label: "Team", value: result.teamIdentifier, monospaced: true)
                        MetadataRow(label: "Verified code", value: "\(result.signedCodeCount) objects")
                        MetadataRow(label: "Injected", value: "\(result.injectedLibraryCount) libraries")
                        MetadataRow(label: "Output", value: result.output.path)
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text("SHA-256").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Text(result.sha256).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if let result = job.injectionResult {
                        MetadataRow(label: "Bundle ID", value: result.bundleIdentifier, monospaced: true)
                        MetadataRow(label: "Injected", value: "\(result.injectedLibraryCount) libraries")
                        MetadataRow(label: "Output", value: result.output.path)
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text("SHA-256").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Text(result.sha256).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if job.jobMode != .injectOnly {
                        MetadataRow(label: "Entitlements", value: job.entitlementPolicy == .strict ? "Strict" : "Compatible (removals allowed)")
                        MetadataRow(label: "Extension profiles", value: job.extensionProfilePolicy == .reuseMain ? "Reuse main identity (experimental)" : "Require matching profiles")
                    }
                    MetadataRow(label: "Extensions", value: job.removeExtensions == true ? "Removal requested" : "Retained")
                    if let finished = job.finishedAt { MetadataRow(label: "Duration", value: "\(String(format: "%.1f", finished.timeIntervalSince(job.startedAt))) seconds") }
                    MetadataRow(label: "Session", value: job.id.uuidString, monospaced: true)
                }
            }
            if let warnings = job.result?.warnings ?? job.injectionResult?.warnings {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in InlineNotice(message: warning) }
            }
            HStack {
                if job.status == .completed {
                    Button { model.reveal(job.output) } label: { Label("Show in Finder", systemImage: "folder") }
                        .disabled(!FileManager.default.fileExists(atPath: job.output.path))
                        .help(FileManager.default.fileExists(atPath: job.output.path) ? "Reveal exported IPA" : "This export has been moved or deleted")
                }
                Button { model.exportDiagnostics(job) } label: { Label("Save Diagnostics…", systemImage: "square.and.arrow.up") }
                Spacer()
            }
            Divider()
            HStack {
                SectionHeading(title: "Event log")
                Spacer()
                Text("\(job.events.count) events").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if job.events.isEmpty {
                Text("Waiting for the export engine…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(job.events) { event in
                        HStack(alignment: .top, spacing: 9) {
                            Text(event.date.formatted(date: .omitted, time: .standard)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                            Image(systemName: event.level == .error ? "xmark.circle.fill" : event.level == .warning ? "exclamationmark.triangle.fill" : "circle.fill")
                                .font(.system(size: event.level == .info ? 5 : 10)).foregroundStyle(eventColor(event)).frame(width: 12, height: 12)
                                .accessibilityLabel(event.level.rawValue)
                            Text(event.message).font(.system(size: 11, design: .monospaced)).foregroundStyle(event.level == .info ? Color.primary.opacity(0.85) : eventColor(event)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
    }
    private func eventColor(_ event: SigningEvent) -> Color {
        switch event.level { case .info: .secondary; case .warning: Palette.warning; case .error: Palette.error }
    }
}
