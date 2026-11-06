import SciaCore
import SwiftUI
import UIKit

/// ユーザーのメニューの「リストに追加」で開くシート。自分のリストを並べ、その人が入っているリストにチェックマークを付ける。
/// 押すたびにその場で足したり外したりする。決まりはdocs/lists.mdの「リストに追加」にある。
struct ListMembershipView: View {
    let model: ListMembershipModel
    let acct: String
    /// 「リストを作成」で、名前を入れるアラートを出す。作れたら、作ったリストを渡す。
    let requestCreate: (@escaping @MainActor (MastodonList) -> Void) -> Void
    let dismiss: () -> Void
    /// フォローを確かめている、足そうとしたリスト。
    @State private var followingListID: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("リストに追加")
                .navigationSubtitle("@\(acct)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了", action: dismiss)
                    }
                }
        }
        .alert(
            followConfirmation.title,
            isPresented: Binding { followingListID != nil } set: { if !$0 { followingListID = nil } },
            presenting: followingListID
        ) { listID in
            Button("キャンセル", role: .cancel) {}
            Button(followConfirmation.buttons.last?.title ?? "") {
                model.followAndAdd(listID)
            }
        } message: { _ in
            Text(followConfirmation.message ?? "")
        }
    }

    private var followConfirmation: Confirmation<Proceed> {
        .followToList(acct: acct)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let presentation):
            ContentUnavailableView {
                Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
            } description: {
                FailureReason(reason: presentation)
            } actions: {
                Button("再読み込み") { model.load() }
            }
        case .loaded:
            List {
                Section {
                    ForEach(model.lists) { list in
                        row(list)
                    }
                    Button {
                        requestCreate { list in toggle(list.id) }
                    } label: {
                        Label("リストを作成", systemImage: "plus")
                    }
                    // 押せないときに、UIKitのように灰色にならず黒い文字になるため、色を決める。
                    .foregroundStyle(model.isFollowing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .disabled(model.isFollowing)
                } footer: {
                    if model.availability == .blocked {
                        Text("ブロックしているかされているため、フォローもリストへの追加もできません。")
                    }
                }
            }
        }
    }

    private func row(_ list: MastodonList) -> some View {
        let isMember = model.memberListIDs.contains(list.id)
        // 入っているリストからは、ブロックしていても外せる。
        let isDisabled = model.isFollowing || (!isMember && model.availability == .blocked)
        return Button {
            toggle(list.id)
        } label: {
            HStack {
                Text(list.title)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if isMember {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                }
            }
        }
        // 標準では文字が色付きになるので、通常の色にする。押せない行は、押せないことが分かるよう薄くする。
        .foregroundStyle(isDisabled ? .secondary : .primary)
        .accessibilityAddTraits(isMember ? .isSelected : [])
        .disabled(isDisabled)
    }

    private func toggle(_ listID: String) {
        if model.toggle(listID) == .needsFollow {
            followingListID = listID
        }
    }

    /// シートで出す画面。半分の高さから開き、引き上げられる。
    static func sheet(model: ListMembershipModel, acct: String, requestCreate: @escaping (@escaping @MainActor (MastodonList) -> Void) -> Void) -> UIViewController {
        weak var presented: UIViewController?
        let controller = UIHostingController(rootView: ListMembershipView(model: model, acct: acct, requestCreate: requestCreate) {
            presented?.dismiss(animated: true)
        })
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        controller.sheetPresentationController?.prefersGrabberVisible = true
        presented = controller
        return controller
    }
}
