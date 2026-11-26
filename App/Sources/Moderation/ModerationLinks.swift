import SciaCore
import SwiftUI
import UIKit

/// アカウントの画面の、ミュートしたユーザー、ブロックしたユーザー、ブロックしたドメインに渡すもの。セッションが作る。
struct ModerationScreenContext {
    /// アカウントの画面の中に置く、ミュートかブロックの人のリストを作る。人を選択したら、アカウントの画面を閉じてから、タブの画面にプロフィールを開く。
    let makeAccountList: @MainActor (AccountListKind) -> UIViewController
    let domainBlocks: DomainBlocksModel
    /// ドメインを入れてブロックするアラートを出す。
    let blockDomain: @MainActor () -> Void
}

/// アカウントの画面の、サーバーでの設定のセクションに並べる3つの入口。どれもアカウントの画面を閉じずに、その中で次の画面へ進む。
struct ModerationLinks: View {
    let context: ModerationScreenContext

    var body: some View {
        NavigationLink(ModerationTexts.mutedAccounts) {
            accountList(.mutes, title: ModerationTexts.mutedAccounts)
        }
        NavigationLink(ModerationTexts.blockedAccounts) {
            accountList(.blocks, title: ModerationTexts.blockedAccounts)
        }
        NavigationLink(ModerationTexts.blockedDomains) {
            DomainBlocksView(model: context.domainBlocks, blockDomain: context.blockDomain)
        }
    }

    private func accountList(_ kind: AccountListKind, title: String) -> some View {
        EmbeddedViewController { context.makeAccountList(kind) }
            .ignoresSafeArea()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
