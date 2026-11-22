import SciaCore
import SwiftUI
import UIKit

/// ブロックしたドメインを並べ、右上の＋で足し、左へスワイプして解除する。サーバー上のアカウントのものなので、アカウントの画面から開く。
/// 決まりはdocs/moderation-lists.mdの「ブロックしたドメイン」にある。
struct DomainBlocksView: View {
    let model: DomainBlocksModel
    /// ドメインを入れてブロックするアラートを出す。入力はUIKitのアラートで受ける。
    let blockDomain: @MainActor () -> Void
    @State private var unblockFailure: ErrorPresentation?

    var body: some View {
        content
            .navigationTitle(ModerationTexts.blockedDomains)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(ModerationTexts.blockDomain, systemImage: "plus") { blockDomain() }
                        .disabled(model.domains == nil)
                }
            }
            .failureAlert(ModerationTexts.unblockFailed, reason: $unblockFailure)
            .task(.action) { model.reload(purpose: .action) }
    }

    @ViewBuilder
    private var content: some View {
        if let domains = model.domains {
            List {
                ForEach(domains, id: \.self) { domain in
                    Text(domain)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .swipeActions {
                            // 解除を受け付けてからリストから外すので、スワイプしきっても行は残す。
                            Button(ModerationTexts.unblock) {
                                model.unblock(domain) { unblockFailure = $0 }
                            }
                            .tint(.red)
                        }
                        .onAppear {
                            if domain == domains.last { model.loadMore(purpose: .display) }
                        }
                }
                footer
            }
            .overlay {
                if domains.isEmpty {
                    ContentUnavailableView(ModerationTexts.noBlockedDomains, systemImage: "network.slash")
                }
            }
        } else if let failure = model.loadFailure {
            ContentUnavailableView {
                Label(SettingsTexts.loadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                FailureReason(reason: failure)
            } actions: {
                Button(SettingsTexts.reload) { model.reload(purpose: .action) }
            }
        } else {
            ProgressView()
        }
    }

    /// 続きを読んでいる間と、読めなかったときの行。
    @ViewBuilder
    private var footer: some View {
        if model.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if let failure = model.loadMoreFailure {
            VStack(alignment: .leading, spacing: 4) {
                Text(ModerationTexts.loadMoreFailed)
                FailureReason(reason: failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(SettingsTexts.reload) { model.loadMore(purpose: .action) }
        }
    }

    /// `scia://domain-blocks`で開く、単独のシート。アカウントの画面からは、その中で進むので使わない。
    static func makeSheet(model: DomainBlocksModel, blockDomain: @escaping @MainActor () -> Void) -> UIViewController {
        UIHostingController(rootView: DomainBlocksSheet(model: model, blockDomain: blockDomain))
    }
}

private struct DomainBlocksSheet: View {
    let model: DomainBlocksModel
    let blockDomain: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DomainBlocksView(model: model, blockDomain: blockDomain)
                .toolbar {
                    // 右上は「ドメインをブロック」に使うので、閉じるボタンは左に置く。
                    ToolbarItem(placement: .cancellationAction) {
                        Button(SettingsTexts.done) { dismiss() }
                    }
                }
        }
    }
}
