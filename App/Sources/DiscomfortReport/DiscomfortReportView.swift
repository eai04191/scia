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
    /// ログから機械的に組み立てた、確保した時刻の直前の操作。
    private(set) var operations: [OperationTimeline.Step] = []
    /// 一覧の何番目の操作に付けたコメントか。
    private(set) var comments: [Int: String] = [:]

    init(capturedAt: Date, logMarker: String, stateDumps: [StateDump]) {
        self.capturedAt = capturedAt
        self.logMarker = logMarker
        self.stateDumps = stateDumps
    }

    func loadLogs() async {
        do {
            let lines = try await RecentLogReader.read(from: capturedAt.addingTimeInterval(-Self.logWindow), untilMarker: logMarker)
            logs = .success(lines)
            operations = OperationTimeline.steps(from: lines, capturedAt: capturedAt)
        } catch {
            logs = .failure(error)
        }
    }

    /// 空のコメントは、付いていないものとして扱う。
    func setComment(_ text: String, at index: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        comments[index] = trimmed.isEmpty ? nil : trimmed
    }

    /// ログの読み込みに失敗した場合も、状態ダンプとメモは残すため、失敗内容をログの代わりに入れて保存する。
    func makeReport() -> DiscomfortReport {
        let lines: [LogLine]
        switch logs {
        case .success(let loaded): lines = loaded
        case .failure(let error): lines = [LogLine(date: capturedAt, category: "report", level: "error", message: "ログを読めませんでした: \(error)")]
        case nil: lines = []
        }
        let operationComments = comments.keys.sorted().compactMap { index -> OperationComment? in
            guard let text = comments[index], operations.indices.contains(index) else { return nil }
            return OperationComment(date: operations[index].date, operation: operations[index].line, text: text)
        }
        return DiscomfortReport(capturedAt: capturedAt, memo: memo, operationComments: operationComments, stateDumps: stateDumps, logs: lines)
    }
}

struct DiscomfortReportView: View {
    @Bindable var draft: DiscomfortReportDraft
    let store: DiscomfortReportStore
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @FocusState private var memoFocused: Bool
    /// コメントを書いている操作の、一覧での位置。
    @State private var commentingIndex: Int?
    @State private var commentText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("メモ") {
                    TextEditor(text: $draft.memo)
                        .frame(minHeight: 120)
                        .focused($memoFocused)
                }
                if draft.logs != nil {
                    operationsSection
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
            .alert("操作へのコメント", isPresented: Binding(
                get: { commentingIndex != nil },
                set: { if !$0 { commentingIndex = nil } }
            ), presenting: commentingIndex) { index in
                TextField("この操作で気になったこと", text: $commentText)
                Button("保存") { draft.setComment(commentText, at: index) }
                if draft.comments[index] != nil {
                    Button("削除", role: .destructive) { draft.setComment("", at: index) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { index in
                Text(draft.operations[index].line)
            }
            .task {
                memoFocused = true
                await draft.loadLogs()
            }
        }
    }

    private var operationsSection: some View {
        Section {
            if draft.operations.isEmpty {
                Text("記録された操作はありません")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(draft.operations.enumerated()), id: \.offset) { index, step in
                    Button {
                        commentText = draft.comments[index] ?? ""
                        commentingIndex = index
                    } label: {
                        operationRow(step, comment: draft.comments[index])
                    }
                    // Formの中のボタンは文字がすべてtintの色になるため、行は普通の文字の色で出す。
                    .tint(.primary)
                }
            }
        } header: {
            Text("直前の操作")
        } footer: {
            if !draft.operations.isEmpty {
                Text("押すと、その操作にコメントを付けられます")
            }
        }
    }

    private func operationRow(_ step: OperationTimeline.Step, comment: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.line)
                .font(.footnote)
                .foregroundStyle(step.isAppEvent ? .secondary : .primary)
            if let comment {
                Label(comment, systemImage: "text.bubble")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
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
