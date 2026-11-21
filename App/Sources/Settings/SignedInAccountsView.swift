import SciaCore
import SwiftUI

/// アカウントの切り替え、ログアウト、追加。窓の持ち主（`SceneDelegate`）が行い、セッションへ渡す。
struct AccountManagement {
    /// チェックマークを付けるアカウント。ダミーのアカウントを出している間はnil。
    let currentID: @MainActor () -> Credential.ID?
    /// ダミーのアカウントではfalse。ログアウトすると、裏で選んだままの本物のアカウントが消えることがあるため。
    let canLogOut: Bool
    /// 書きかけの投稿があれば確かめてから、そのアカウントに切り替える。
    let switchTo: @MainActor (Credential.ID) -> Void
    /// 確かめてから、そのアカウントからログアウトする。
    let logOut: @MainActor (Credential.ID) -> Void
    /// 書きかけの投稿があれば確かめてから、ログインの画面を出す。
    let add: @MainActor () -> Void
}

/// 「アカウントを管理」の画面に渡すもの。セッションが作る。
struct SignedInAccountsContext {
    let model: SignedInAccountsModel
    let management: AccountManagement
}

/// ログインしているアカウントを並べ、並べ替え、切り替え、ログアウトする画面。決まりはdocs/account-screen.mdの「アカウントを管理」にある。
struct SignedInAccountsView: View {
    let settings: AppSettings
    let context: SignedInAccountsContext

    private var model: SignedInAccountsModel { context.model }
    private var management: AccountManagement { context.management }

    var body: some View {
        List {
            Section {
                ForEach(model.rows) { row in
                    SignedInAccountRow(row: row, settings: settings) {
                        guard !row.isCurrent else { return }
                        management.switchTo(row.id)
                    } logIn: {
                        model.logIn(row.id)
                    }
                    .swipeActions {
                        if management.canLogOut {
                            // 確かめてから消すので、スワイプしきっても行は残し、ログアウトできたら並びから外れる。
                            Button(SettingsTexts.SignedInAccounts.logOut) { management.logOut(row.id) }
                                .tint(.red)
                        }
                    }
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
            }
            Section {
                Button(AccountSwitchTexts.addAccount, action: management.add)
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(SettingsPage.accountManagement.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reload() }
    }
}

private struct SignedInAccountRow: View {
    let row: SignedInAccountsModel.Row
    let settings: AppSettings
    let select: @MainActor () -> Void
    let logIn: @MainActor () -> Void

    var body: some View {
        if row.isLoggedOut {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: select) { label }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                Button(NoticeTexts.logIn, action: logIn)
                    .buttonStyle(.borderless)
                    .padding(.leading, Self.textLeading)
            }
        } else {
            Button(action: select) { label }
                .foregroundStyle(.primary)
        }
    }

    private static let avatarSide: CGFloat = 28
    private static let avatarSpacing: CGFloat = 12
    /// 名前の左端。「ログインし直す」を名前とハンドルの左端にそろえる。
    private static let textLeading = avatarSide + avatarSpacing

    private var label: some View {
        HStack(spacing: Self.avatarSpacing) {
            avatar
                .frame(width: Self.avatarSide, height: Self.avatarSide)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                AccountNameText(name: row.name, emojis: row.emojis, settings: settings)
                Text(verbatim: row.credential.handle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isLoggedOut {
                    Text(SettingsTexts.SignedInAccounts.loggedOut)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.isCurrent {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private var avatar: some View {
        if let profile = row.profile {
            AvatarImage(url: profile.avatarStatic, shape: settings.appearance.avatarShape)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}
