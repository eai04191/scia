import Foundation

/// 「操作の状況」の画面の文言。
public enum OperationStatusTexts {
    /// 画面の題。アカウントのメニューの、この画面を開く項目の名前にも使う。
    public static let title = "操作の状況"
    public static let done = "完了"
    public static let empty = "操作なし"
    public static let emptyDescription = "ダウンロードなどの進行中の操作と、失敗した操作がここに表示されます。"
    public static let activitiesHeader = "進行中"
    public static let noFailures = "失敗はありません"
    public static let failuresHeader = "最近の失敗"

    /// 最近の失敗の節の注記。
    /// - Parameter limit: 残す失敗の数（`OperationStatus.failureLimit`）。
    public static func failuresFooter(limit: Int) -> String {
        // iOSでは、SwiftUIの`Text`に数を埋めて出していて、`Text`が桁区切りを付けていたため、同じにする。
        "直近の\(limit.formatted())件が表示されます。"
    }

    /// 失敗の行をスワイプして消すボタン。
    public static let delete = "削除"
    /// 最近の失敗の見出しに添える、すべて消すボタン。
    public static let clearFailures = "消去"

    /// 進行中の操作を止めるボタンの読み上げ。
    public static let stop = "中止"
    /// 投稿のある失敗の行のヒント。
    public static let openStatusHint = "投稿を開きます。"
}

/// チップの列と、失敗の理由の部品の文言。
public enum NoticeTexts {
    /// チップに添える、ほかに出ている数。
    public static func additionalCount(_ count: Int) -> String {
        "+\(count)件"
    }

    /// ほかに出ている数を添えたチップの読み上げ。
    public static func accessibilityLabel(title: String, additionalCount: Int) -> String {
        "\(title)、ほかに\(additionalCount)件"
    }

    /// チップを閉じる、VoiceOverの操作。
    public static let close = "閉じる"
    /// チップの列の高さを測るための2行の文。表示しない。
    public static let sizingSample = "あ\nあ"

    /// ログアウトされたアカウントにログインし直すボタン。
    public static let logIn = "ログインし直す"
    /// チップの列の、ログインし直しを促すボタン。
    public static let logInPrompt = "ログインし直してください"
    public static let logInHint = "ログインし直します。"
    public static let reloadHint = "再読み込みします。"
}

/// ステータスバーの通知の文言。
public enum StatusBarTickerTexts {
    /// 押すと通知のタブを開くことのヒント。
    public static let openHint = "通知タブを開きます。"
}

extension StatusBarTickerItem {
    /// ステータスバーの通知の読み上げ。通知のタイムラインの行と同じく、誰が何をしたかを読み、続けて対象の投稿の文頭を読む。
    /// 絵文字のリアクションは、何の絵文字かまで読む。カスタム絵文字はショートコードで読む。
    public var accessibilityLabel: String {
        let name = account.displayNameOrUsername
        let action: String
        if let emoji = reactionEmoji {
            action = "\(name)が\(emoji.isCustom ? ":\(emoji.name):" : emoji.name)でリアクションしました"
        } else {
            let phrase = NotificationAppearance(kind).phrase
            action = phrase.includesName ? "\(phrase.before)\(name)\(phrase.after)" : phrase.before
        }
        return switch subject {
        case .text(let text): "\(action)。\(text.plainText)"
        case .media(_, _, let isImageOnly): "\(action)。\(isImageOnly ? "画像" : "メディア")だけの投稿"
        case .handle(let handle): "\(action)。\(handle)"
        case .none: action
        }
    }
}
