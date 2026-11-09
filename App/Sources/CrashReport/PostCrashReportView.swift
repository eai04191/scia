import SciaCore
import SwiftUI
import UIKit

/// 隔離した投稿について、開発者に送る内容を確かめて送る画面。決まりはdocs/crash-quarantine.mdにある。
///
/// 投稿の行の部品は使わない。同じ投稿を描くと、この画面でもクラッシュするため。
struct PostCrashReportView: View {
    private enum Phase {
        case loading
        case failed(ErrorPresentation)
        case loaded(PostCrashReport)
    }

    /// 読み込めなくてもブラウザで開けるよう、タイムラインが持っていた投稿のページ。分からなければnil。
    let fallbackURL: URL?
    let load: @MainActor () async throws -> PostCrashReport
    let describe: @MainActor (any Error) async -> ErrorPresentation
    let sendByMail: @MainActor (String) -> Void
    let sendByMastodon: @MainActor (String) -> Void
    let close: @MainActor () -> Void

    @State private var phase = Phase.loading
    @State private var includesDetail = false

    var body: some View {
        NavigationStack {
            Form {
                explanation
                content
            }
            .navigationTitle("表示できない投稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark", action: close)
                }
            }
        }
        .task(.action) { await reload() }
    }

    /// 通知のチップや行から来た人は、何が起きたのかを知らないので、最初に説明する。
    private var explanation: some View {
        // 押せるものでも項目でもないので、行の形にせず、普通の文として置く。
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("以前この投稿を読み込んだ際に問題が発生したため表示を中止しました。ご不便をおかけして申し訳ありません。")
                Text("この投稿にはSciaが想定していないデータが含まれている可能性があります。原因を特定して修正するために開発者に情報を提供していただけませんか？")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        case .failed(let reason):
            Section {
                FailureReason(reason: reason, lead: "報告する内容を読み込めませんでした。")
                Button("再試行") { Task(.action) { await reload() } }
            }
            if let fallbackURL {
                browserSection(fallbackURL)
            }
        case .loaded(let report):
            loaded(report)
        }
    }

    @ViewBuilder private func loaded(_ report: PostCrashReport) -> some View {
        if let url = report.postURL {
            browserSection(url)
        }
        let text = sentText(report)
        Section {
            Text(text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        } header: {
            Text("開発者に報告する内容")
        }
        if report.maskedJSON != nil {
            Section {
                Toggle("詳しいデータも送る", isOn: $includesDetail)
            } footer: {
                Text("本文の文字を置き換えたデータです。長いためメールでのみ送れます。")
            }
        }
        Section {
            Button("メールで報告") { sendByMail(text) }
            Button("Mastodonのダイレクトで報告") { sendByMastodon(text) }
                .disabled(includesDetail)
        }
    }

    private func browserSection(_ url: URL) -> some View {
        Section {
            Link("ブラウザで開く", destination: url)
        }
    }

    private func sentText(_ report: PostCrashReport) -> String {
        guard includesDetail, let maskedJSON = report.maskedJSON else { return report.text }
        return "\(report.text)\n\n\(maskedJSON)"
    }

    private func reload() async {
        phase = .loading
        do {
            phase = .loaded(try await load())
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(await describe(error))
        }
    }
}

extension PostCrashReportView {
    /// UIKitの画面に重ねて出す画面を作る。
    static func makeController(
        fallbackURL: URL?,
        load: @escaping @MainActor () async throws -> PostCrashReport,
        describe: @escaping @MainActor (any Error) async -> ErrorPresentation,
        sendByMail: @escaping @MainActor (String, UIViewController) -> Void,
        sendByMastodon: @escaping @MainActor (String, UIViewController) -> Void
    ) -> UIViewController {
        weak var weakHost: UIViewController?
        let host = UIHostingController(rootView: PostCrashReportView(
            fallbackURL: fallbackURL,
            load: load,
            describe: describe,
            sendByMail: { text in weakHost.map { sendByMail(text, $0) } },
            sendByMastodon: { text in weakHost.map { sendByMastodon(text, $0) } },
            close: { weakHost?.dismiss(animated: true) }
        ))
        weakHost = host
        return host
    }
}
