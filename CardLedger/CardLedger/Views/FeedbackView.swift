import SwiftUI
import UIKit

/// Sheet for alpha testers to share feedback along with an allowlisted, privacy-safe diagnostics report (CL-14).
struct FeedbackView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var note = ""
    @State private var includeMetricKit = false
    @State private var report: DiagnosticsReport?
    @State private var hasCheckedHealth = false
    @State private var reloadNonce = 0
    @State private var copied = false
    @State private var showPreview = false

    private var metricKitPayloads: [MetricKitDiagnosticSummary] {
        MetricKitCollector.shared.summaries()
    }

    private var exportFile: DiagnosticsExportFile? {
        guard let report, let data = try? report.formattedJSON() else { return nil }
        return DiagnosticsExportFile(
            filename: DiagnosticsReport.defaultFilename(today: store.today),
            data: data
        )
    }

    private var shareMessage: String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Card Ledger tester feedback (privacy-safe diagnostics report attached)."
        }
        return trimmed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What happened or what did you expect?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Describe the issue (optional)")
                } footer: {
                    Text("Do not include account numbers or sensitive details in your note.")
                }

                Section {
                    LabeledContent("App version", value: report.map { "\($0.app.version) (\($0.app.build))" } ?? "Loading…")
                    LabeledContent("API version", value: apiVersionLabel)
                    LabeledContent("Connections", value: "\(report?.connections.count ?? 0)")
                    LabeledContent("Parser error codes", value: "\(report?.parserFailures.count ?? store.parserFailures.count)")
                    DisclosureGroup("Preview diagnostics JSON", isExpanded: $showPreview) {
                        if let report {
                            ScrollView(.horizontal, showsIndicators: true) {
                                Text(report.formattedJSONString())
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .padding(.vertical, 4)
                            }
                        } else {
                            ProgressView()
                        }
                    }
                } header: {
                    Text("Diagnostics report")
                } footer: {
                    Text("Includes only app and API versions, bank sync states, and statement parser failure codes. Never includes transactions, merchants, amounts, card numbers, emails, or tokens.")
                }

                Section {
                    Toggle("Include crash and hang reports", isOn: $includeMetricKit)
                    let count = metricKitPayloads.count
                    LabeledContent(
                        "Recorded on this iPhone",
                        value: count == 0 ? "None yet" : "\(count) \(count == 1 ? "report" : "reports")"
                    )
                    if count > 0 {
                        Button("Clear saved crash reports", role: .destructive) {
                            MetricKitCollector.shared.clear()
                            copied = false
                            reloadNonce += 1
                        }
                    }
                } header: {
                    Text("Crash and hang diagnostics (MetricKit)")
                } footer: {
                    Text("Optional. When enabled, attaches Apple MetricKit crash stack traces and hang durations collected on this device. No financial data is included.")
                }

                Section {
                    if let file = exportFile {
                        ShareLink(
                            item: file,
                            subject: Text("Card Ledger feedback"),
                            message: Text(shareMessage),
                            preview: SharePreview(file.filename, image: Image(systemName: "doc.text"))
                        ) {
                            Label("Share feedback & diagnostics…", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        HStack {
                            Text("Preparing diagnostics…")
                            Spacer()
                            ProgressView()
                        }
                    }

                    Button {
                        guard let report else { return }
                        UIPasteboard.general.string = report.formattedJSONString()
                        copied = true
                    } label: {
                        Label(copied ? "Diagnostics JSON copied" : "Copy diagnostics JSON",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(report == nil)
                }
            }
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: "\(includeMetricKit)-\(reloadNonce)") {
                let shouldCheckHealth = !hasCheckedHealth
                hasCheckedHealth = true
                copied = false
                report = await store.buildDiagnosticsReport(
                    includeMetricKit: includeMetricKit,
                    refreshAPIHealth: shouldCheckHealth
                )
            }
        }
    }

    private var apiVersionLabel: String {
        guard let report else { return "Checking…" }
        if let v = report.api.apiVersion {
            return "v\(v) (\(report.api.healthStatus))"
        }
        switch report.api.healthStatus {
        case "not_signed_in": return "Not signed in"
        case "unreachable": return "Offline"
        default: return "Unavailable"
        }
    }
}
