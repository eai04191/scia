/// 添付ファイルのビューアと、その中の代替テキスト、動画の操作、共有や保存の確認に出す文言。
/// チップの文言は`Notice`（MediaNotices.swift）にある。
public enum MediaViewerTexts {
    /// Macのウィンドウのタイトル。AeroSpaceなどがタイムラインのウィンドウと見分けるために使う。
    public static let windowTitle = "Scia メディア"
    /// 閉じるキーコマンドの名前。
    public static let close = "閉じる"
    /// 右上のメニューのボタンの読み上げ。
    public static let moreActions = "その他の操作"
    public static let editAltText = "代替テキストを編集"
    public static let selectTextInImage = "画像の文字を選択"
    public static let playbackSpeed = "再生速度"
    public static let loop = "ループ再生"
    public static let openInBrowser = "ブラウザで開く"
    public static let imageLoadFailure = "画像を読み込めませんでした"
    public static let unsupportedFile = "このファイルはアプリで表示できません"

    /// 動画やGIFを読み込めなかったときの文。画像の「画像を読み込めませんでした」と揃え、種類の名前で言う。
    public static func playbackFailure(of kind: MediaAttachment.Kind) -> String {
        "\(kind == .gifv ? "GIF" : "動画")を読み込めませんでした"
    }

    /// 画面の下に出す代替テキストと、代替テキストの入力欄。
    public enum AltText {
        public static let title = "代替テキスト"
        /// 書ける説明が空のときに出す文言と、入力欄のプレースホルダ。
        public static let placeholder = "代替テキストを追加"
        public static let doneEditing = "代替テキストを書き終える"
        public static let editHint = "代替テキストを編集します。"
        public static let showFullTextHint = "全文を表示します。"
        public static let translate = "翻訳"

        /// 残りの文字数の読み上げ。
        public static func remainingCharacters(_ remaining: Int) -> String {
            "残り\(remaining)文字"
        }
    }

    /// 動画の再生の操作の読み上げ。
    public enum Video {
        public static func playButton(isPlaying: Bool) -> String {
            isPlaying ? "一時停止" : "再生"
        }

        public static func muteButton(isMuted: Bool) -> String {
            isMuted ? "消音を解除" : "消音"
        }

        public static let skipBackward = "10秒戻る"
        public static let skipForward = "10秒進む"
        public static let position = "再生位置"
        /// 長押しで2倍速にしている間に出す文言と、その読み上げ。
        public static let doubleSpeed = "2倍速"
    }

    /// 共有や保存のために落としている途中のものの、チップと確認。
    public enum Transfer {
        public static let downloading = "ダウンロード中"
        /// 落としている途中のチップを選択すると、操作の状況を開くときの読み上げのヒント。
        public static let showAllHint = "操作の状況を開きます。"
        /// 落としている途中のチップを選択すると、止めるかの確認を出すときの読み上げのヒント。
        public static let stopHint = "ダウンロードを中止するか選べます。"
        public static let stopConfirmationTitle = "ダウンロードを中止しますか？"
        public static let stop = "中止"
        public static let `continue` = "続ける"
    }

    /// 写真に保存できなかったときの文言。
    public enum PhotoLibrary {
        public static let notAuthorizedTitle = "写真に保存できません"
        public static let notAuthorizedMessage = "写真への追加が許可されていません。設定でSciaに写真の追加を許可してください。"
        public static let openSettings = "設定を開く"
        public static let cancel = "キャンセル"
        public static let unsupportedFile = "写真に入らない形式のファイルです。"
        public static let notEnoughSpace = "ストレージの空き容量が足りません。"
        public static let notAuthorized = "写真への追加が許可されていません。"
        public static let failure = "写真に追加できませんでした。"
    }
}
