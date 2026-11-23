import SciaCore
import UIKit

/// 投稿欄で書くアカウントごとの、送り先と、補完、上限と既定値、アイコン、返信先の探し直しの読み先。決まりはdocs/compose.mdの「ほかのアカウントで書く」にある。
/// ウィンドウのアカウントも、ログインしているほかのアカウントも同じ形で持ち、使う側はどちらで書いているかで処理を分けない。
/// アカウントによる違いは、組み立てる`SessionController.composeSource(for:)`に閉じる。
@MainActor
struct ComposeSource {
    let credential: Credential
    var id: Credential.ID { credential.id }
    /// 送り先。呼ぶたびに作る。
    let makeAccount: @MainActor () -> ComposeAccount<UIImage>
    /// 補完とカスタム絵文字の読み先。呼ぶたびに作る。作るとそのサーバーのカスタム絵文字のキャッシュを読み始めるので、補完を切り替えるときだけ呼ぶ。
    let makeCompletionSources: @MainActor () -> CompletionModel.Sources
    /// 補完の候補を描く設定。
    let displaySettings: AppSettings
    /// 候補のハンドルの書き方に使う、アカウントのドメインを読む。読めていれば何もしない。ウィンドウのアカウントは`AccountSession`が読むのでnil。
    let loadDisplayDomain: (@MainActor () async -> Void)?
    /// サーバーの上限とアカウントの設定。読めなかった値はnil。
    let defaults: @MainActor () async -> (configuration: InstanceConfiguration?, preferences: ServerPreferences?)
    /// 読めているアイコン。
    let avatarURL: URL?
    let loadAvatarURL: @MainActor () async -> URL?
    /// サーバーの機能（引用の決まりなど）を読み終えるまで待つ。
    let loadCapabilities: @MainActor () async -> Void
    /// 読めている引用の決まり。読む前は`ServerCapabilities.mastodon`の決まり。
    let quoteRules: @MainActor () -> QuoteRules
    /// ほかのサーバーの投稿を、このアカウントのサーバーでURIで探す。
    let lookup: @MainActor (Status) async -> OtherAccount.Lookup
}
