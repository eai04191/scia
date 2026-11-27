import Foundation

/// プロフィールの画面と、そこから開くメモやプロフィールの編集で共通に使う文言。
/// 画面ごとの文言は`AccountNoteTexts`、`ProfileEditTexts`、`ReportTexts`にある。
public enum ProfileTexts {
    /// プロフィールを読めなかったときの文言。プロフィールの画面と、自分のプロフィールの編集の画面で使う。
    public static let loadFailure = "プロフィールを読み込めませんでした"

    /// 書いた文字数。メモの欄と通報の補足で揃え、3桁の区切りを付けない。
    public static func characterCount(_ count: Int) -> String {
        "\(count)文字"
    }

    /// プロフィールを読めなかったときの、再試行のボタン。
    public static let retry = "再試行"
    /// 右上の、ユーザーのメニューを出すボタンの読み上げ。
    public static let userMenu = "ユーザーのメニュー"

    /// ヘッダーに出す文言。
    public enum Header {
        /// 投稿、フォロー、フォロワーの数のあいだに置く空白（全角の空白1つ）。
        public static let countSeparator = "　"
        /// フォローの関係を読めなかったときに、フォローのボタンの場所に出す文言。
        public static let relationshipFailure = "読み込みエラー"
        public static let relationshipRetry = "再試行"
        public static let relationshipRetryHint = "フォローの状態を再読み込みします。"
        /// 関係を読む前の、フォローのボタンの読み上げ。
        public static let relationshipLoading = "フォローの状態を読み込み中"
        /// 相手にフォローされていることを示すバッジ。
        public static let followedBy = "フォローされています"
        /// 長い自己紹介を折りたたんでいるときの、開くボタン。
        public static let showMore = "さらに表示"
        /// ほかのサーバーのアカウントであることを示す1行と、その横のボタン。
        public static let remoteAccount = "ほかのサーバーのアカウント"
        public static let openOriginal = "元のサーバーで開く"
        /// 補足情報の値のリンク先に、このアカウントへのリンクがあると確かめられたときの読み上げの値。
        public static let verified = "確認済み"
        public static let followingListAccessibilityName = "フォローしている人のリスト"
        public static let followersListAccessibilityName = "フォロワーのリスト"

        /// 投稿の数。数を目立たせる。
        public static func statusesCount(_ count: Int) -> PostTexts.EmphasizedText {
            countText(count, label: "投稿")
        }

        /// フォローしている人の数。数を目立たせる。
        public static func followingCount(_ count: Int) -> PostTexts.EmphasizedText {
            countText(count, label: "フォロー")
        }

        /// フォロワーの数。数を目立たせる。
        public static func followersCount(_ count: Int) -> PostTexts.EmphasizedText {
            countText(count, label: "フォロワー")
        }

        private static func countText(_ count: Int, label: String) -> PostTexts.EmphasizedText {
            let number = count.formatted()
            let text = "\(number) \(label)"
            return PostTexts.EmphasizedText(text: text, emphasis: text.startIndex..<text.index(text.startIndex, offsetBy: number.count))
        }
    }

    /// 「投稿」のタブの絞り込み。
    public enum PostsFilter {
        /// 絞り込みのボタンの読み上げ。
        public static let accessibilityLabel = "投稿の絞り込み"
        public static let showReplies = "返信を表示"
        public static let showBoosts = "ブーストを表示"
        /// 絞り込みのメニューの見出し。
        public static let menuTitle = "自分のスレッドの続きは返信を隠しても表示します"

        /// 絞り込みのボタンの読み上げの値。表示しているものを並べる。
        public static func accessibilityValue(_ filter: ProfilePostsFilter) -> String {
            let shown = [filter.showsReplies ? showReplies : nil, filter.showsBoosts ? showBoosts : nil].compactMap { $0 }
            return shown.isEmpty ? "返信とブーストを表示しない" : shown.joined(separator: "、")
        }
    }

    /// 注目のハッシュタグと紹介しているユーザーの棚。
    public enum Shelf {
        public static let featuredTags = "注目のハッシュタグ"
        public static let endorsements = "紹介しているユーザー"
        /// 紹介しているユーザーの棚の終わりに置く、すべてを開くカード。
        public static let showAll = "すべて見る"

        /// 注目のハッシュタグのチップの読み上げ。
        public static func featuredTagAccessibilityLabel(name: String, statusesCount: Int) -> String {
            "#\(name)、\(statusesCount)件の投稿"
        }

        /// 固定された投稿のカードの読み上げ。本文、添付ファイルの数、日時を、あるものだけ並べる。
        public static func pinnedAccessibilityLabel(body: String?, attachmentCount: Int, date: String?) -> String {
            let attachments = attachmentCount == 0 ? nil : "添付ファイル\(attachmentCount)件"
            return [body, attachments, date].compactMap(\.self).joined(separator: "、")
        }
    }

    /// 変更を保存せずに閉じようとしたときの、確かめるシート。
    public enum Discard {
        public static let message = "変更を保存していません"
        public static let discard = "変更を破棄"
        public static let keepEditing = "編集を続ける"
    }
}

/// 自分にしか見えないメモの、書く画面とプロフィールの欄に出す文言。
public enum AccountNoteTexts {
    /// 書く画面の題と入力欄の読み上げ、プロフィールの欄の見出し。
    public static let title = "メモ"
    public static let save = "保存"
    public static let placeholder = "メモを追加"
    public static let saveFailure = "メモを保存できませんでした"
    /// プロフィールの文章のメニューの先頭に足す項目と、メモがあるときのユーザーのメニューの項目。
    public static let edit = "メモを編集"
    /// プロフィールの欄を選択したときの、読み上げのヒント。
    public static let editHint = "メモを編集します。"

    /// 書く画面の入力欄の見出し。
    public static func header(acct: String) -> String {
        "@\(acct)についての自分にしか見えないメモ"
    }

    /// プロフィールの欄の読み上げ。
    public static func accessibilityLabel(note: String) -> String {
        "メモ、\(note)"
    }
}

extension ProfileTab {
    /// プロフィールのタブの切り替えに出す名前。
    public var title: String {
        switch self {
        case .posts: "投稿"
        case .media: "メディア"
        }
    }
}

extension FollowState {
    /// フォローのボタンに出しうる文字。ボタンの枠の幅を、このうちいちばん長いものに合わせる。
    public static let allButtonTitles: [String] = [
        FollowState.notFollowing(locked: false), .notFollowing(locked: true), .requested, .following, .myself,
    ].compactMap(\.buttonTitle)
}
