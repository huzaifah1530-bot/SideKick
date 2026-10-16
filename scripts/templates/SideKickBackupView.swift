import SwiftUI

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var lines: [String] = []
    @State private var lastPercent = -5
    @State private var started = false

    private var failure: String? { state.bootCheckError?.localizedDescription ?? state.operationError?.message }
    private var title: String { state.currentOperation == .restore ? "Restore Status" : "Backup Status" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("SideKick", systemImage: "bolt.fill").foregroundStyle(.blue).font(.headline)
                Text(title).font(.largeTitle.bold())
                Text(Bundle.main.appName ?? "App").font(.title3).foregroundStyle(.secondary)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                } else if state.currentOperation != nil {
                    ProgressView(value: state.progressFraction).tint(.blue)
                    Text(state.progressText.isEmpty ? "Preparing app data…" : state.progressText)
                        .foregroundStyle(.secondary).monospacedDigit()
                    Text("Keep this screen open. SideKick will continue when this finishes.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(started ? "Returning to SideKick…" : "Waiting for SideKick to start the backup or restore…")
                        .foregroundStyle(.secondary)
                }
                Text("Activity Log").font(.headline).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(line.contains("ERROR") ? .red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            }.padding(24)
        }
        .background(Color(uiColor: .systemBackground))
        .preferredColorScheme(.dark)
        .onReceive(state.$currentOperation) { operation in
            if let operation {
                started = true; lastPercent = -5
                append(operation == .backup ? "Backing up native app data" : "Restoring native app data")
            } else if started { append(failure == nil ? "Data operation finished. Returning to SideKick." : "ERROR · Data operation failed") }
        }
        .onReceive(state.$progressText) { message in
            let percent = Int(state.progressFraction * 100)
            if !message.isEmpty, percent >= lastPercent + 5 || percent == 100 {
                lastPercent = percent; append(message)
            }
        }
        .onReceive(state.$bootCheckError) { error in
            if let error { append("ERROR · " + error.localizedDescription) }
        }
        .onReceive(state.$operationError) { error in
            if let error { append("ERROR · " + error.message) }
        }
    }

    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
        if lines.count > 100 { lines.removeFirst(lines.count - 100) }
    }
}
