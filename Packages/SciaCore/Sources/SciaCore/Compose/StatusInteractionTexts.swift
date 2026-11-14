/// 付け外しの操作の、失敗の見出しと、済んだことのチップの文言。
/// 済んだことをいつ知らせるかは、docs/object-actions.mdの「結果の知らせ」にある。
extension StatusInteractions.Action {
    /// 失敗の見出し。
    /// - Parameter addsOnly: 今の状態によらず付ける操作（メニューで公開範囲を選んだブースト）。外すことがないので、付けられなかったことを言う。
    public func failureTitle(addsOnly: Bool = false) -> String {
        switch self {
        case .favourite: "お気に入りを変更できませんでした"
        case .reblog: addsOnly ? "ブーストできませんでした" : "ブーストを変更できませんでした"
        case .bookmark: "ブックマークを変更できませんでした"
        case .muteConversation: "会話のミュートを変更できませんでした"
        case .pin: "プロフィールの固定を変更できませんでした"
        case .emojiReaction: addsOnly ? "リアクションできませんでした" : "リアクションを変更できませんでした"
        }
    }

    /// 済んだことのチップの文言。どちらにしたかを出す。
    /// - Parameter wasOn: 操作の前に付いていた。付いていたものは外したことを言う。
    public func doneTitle(wasOn: Bool) -> String {
        switch self {
        case .favourite: wasOn ? "お気に入りを取り消しました" : "お気に入りしました"
        case .reblog: wasOn ? "ブーストを取り消しました" : "ブーストしました"
        case .bookmark: wasOn ? "ブックマークを外しました" : "ブックマークしました"
        case .muteConversation: wasOn ? "会話のミュートを解除しました" : "会話をミュートしました"
        case .pin: wasOn ? "プロフィールの固定を外しました" : "プロフィールに固定しました"
        case .emojiReaction: wasOn ? "リアクションを取り消しました" : "リアクションしました"
        }
    }
}

/// 今のアカウントではないアカウントで行った操作の文言。今のアカウントのタイムラインの投稿は変わらないので、どのアカウントで行ったかを頭に付ける。
public enum OtherAccountTexts {
    /// - Parameter handle: 行ったアカウントのハンドル（`StoredCredential.handle`）。
    public static func title(_ title: String, handle: String) -> String {
        "\(handle)で\(title)"
    }

    public static let deleted = "投稿を削除しました"
    public static let deleteFailure = "投稿を削除できませんでした"
    public static let edited = "編集しました"
    public static let scheduled = "予約しました"
    public static let posted = "投稿しました"
}
