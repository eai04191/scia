import SciaCore
import SwiftUI

/// 違和感を覚えた瞬間に確保した状態とログに、メモを添えて保存する。
@MainActor
@Observable
final class DiscomfortReportDraft {
    /// レポートに含める、確保した時刻より前のログの範囲。
    static let logWindow: TimeInterval = 10 * 60

    let capturedAt: Date
    /// 確保した時点で書いたログの目印。ここまでのログを集める。
    let logMarker: String
    let stateDumps: [StateDump]
    var memo = ""
    private(set) var logs: Result<[LogLine], any Error>?

    init(capturedAt: Date, logMarker: String, stateDumps: [StateDump]) {
        self.capturedAt = capturedAt
        self.logMarker = logMarker
        self.stateDumps = stateDumps
    }

    func loadLogs() async {
        do {
            logs = .success(try await RecentLogReader.read(from: capturedAt.addingTimeInterval(-Self.logWindow), untilMarker: logMarker))
        } catch {
            logs = .failure(error)
        }
    }

    /// ログの読み込みに失敗した場合も、状態ダンプとメモは残すため、失敗内容をログの代わりに入れて保存する。
    func makeReport() -> DiscomfortReport {
        let lines: [LogLine]
        switch logs {
        case .success(let loaded): lines = loaded
        case .failure(let error): lines = [LogLine(date: capturedAt, category: "report", level: "error", message: "ログを読めませんでした: \(error)")]
        case nil: lines = []
        }
        return DiscomfortReport(capturedAt: capturedAt, memo: memo, stateDumps: stateDumps, logs: lines)
    }
}

struct DiscomfortReportView: View {
    @Bindable var draft: DiscomfortReportDraft
    let store: DiscomfortReportStore
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @FocusState private var memoFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("メモ") {
                    TextEditor(text: $draft.memo)
                        .frame(minHeight: 120)
                        .focused($memoFocused)
                }
                Section("確保した内容") {
                    LabeledContent("時刻", value: draft.capturedAt, format: .dateTime.hour().minute().second())
                    LabeledContent("状態ダンプ", value: "\(draft.stateDumps.count)件")
                    LabeledContent("ログ") { logSummary }
                }
                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("違和感レポート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("破棄", role: .destructive) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(draft.logs == nil)
                }
            }
            .task {
                memoFocused = true
                await draft.loadLogs()
            }
        }
    }

    @ViewBuilder
    private var logSummary: some View {
        switch draft.logs {
        case nil: ProgressView()
        case .success(let lines): Text("\(lines.count)件")
        case .failure: Text("読み込み失敗").foregroundStyle(.red)
        }
    }

    private func save() {
        do {
            try store.save(draft.makeReport())
            dismiss()
        } catch {
            saveError = "保存できませんでした: \(error.localizedDescription)"
        }
    }
}
