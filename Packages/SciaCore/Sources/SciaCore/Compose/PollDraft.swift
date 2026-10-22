import Foundation

/// 投稿に付ける投票の下書き。決まりは`docs/poll.md`の「投票を作る」にある。
public struct PollDraft: Sendable, Equatable {
    /// 選択肢。書いた順に投票に並ぶ。
    public var options: [String]
    /// 複数の選択肢を選べる。
    public var multiple: Bool
    /// 締め切るまで票数を隠す。
    public var hidesTotals: Bool
    /// 締め切りまでの秒数。
    public var expiresIn: Int

    /// 足したときの選択肢の数と、締め切りまで。Mastodonのweb UIと同じく、選択肢2つ、1日にする。
    public init(options: [String] = ["", ""], multiple: Bool = false, hidesTotals: Bool = false, expiresIn: Int = 86_400) {
        self.options = options
        self.multiple = multiple
        self.hidesTotals = hidesTotals
        self.expiresIn = expiresIn
    }

    /// 締め切りまでの選択肢。Mastodonのweb UIと同じ並び。サーバーの上限の外のものは`expiryChoices(within:)`で除く。
    public static let expiryChoices = [300, 1_800, 3_600, 21_600, 43_200, 86_400, 259_200, 604_800]

    /// 締め切りまでの表記。日、時間、分のうち割り切れる大きな単位で書く。
    public static func expiryTitle(_ seconds: Int) -> String {
        switch seconds {
        case let value where value >= 86_400 && value % 86_400 == 0: "\(value / 86_400)日"
        case let value where value >= 3_600 && value % 3_600 == 0: "\(value / 3_600)時間"
        default: "\(seconds / 60)分"
        }
    }

    /// サーバーが受け付ける締め切りの選択肢。
    public static func expiryChoices(within limits: PollLimits) -> [Int] {
        expiryChoices.filter { limits.expirationRange.contains($0) }
    }

    /// `index`の選択肢を`text`にし、欄の数を書いている途中の形に整える。
    ///
    /// 最後の欄に書いたら、上限まで後ろに空の欄を1つ足す。「選択肢を追加」のボタンを置かずに、次の選択肢を書き始められるようにするため。
    /// 後ろに空の欄が2つ以上並んだら、1つになるまで後ろから詰める。空の欄は送らないので、消すボタンも置かない。
    /// 欄は2つより減らさない。途中の空の欄は、書いている途中かもしれないので詰めない。
    public mutating func setOption(_ text: String, at index: Int, limits: PollLimits) {
        guard options.indices.contains(index) else { return }
        options[index] = text
        options = Self.editingOptions(options, maxOptions: limits.maxOptions)
    }

    static func editingOptions(_ options: [String], maxOptions: Int) -> [String] {
        func isBlank(_ option: String) -> Bool { option.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var options = options
        while options.count > 2, let last = options.last, isBlank(last), isBlank(options[options.count - 2]) {
            options.removeLast()
        }
        if let last = options.last, !isBlank(last), options.count < maxOptions {
            options.append("")
        }
        while options.count < 2 {
            options.append("")
        }
        return options
    }

    /// 送る選択肢。Mastodonと同じく、前後の空白を除き、空のものを捨てる。足したまま書かなかった欄があっても送れるようにするため。
    /// https://github.com/mastodon/mastodon/blob/main/app/models/poll.rb の`prepare_options`
    public var filledOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// サーバーが受け付ける内容になっている。空でない選択肢が2つ以上上限以下で、どれも文字数の上限以内で、同じものがないこと。
    /// https://github.com/mastodon/mastodon/blob/main/app/validators/poll_options_validator.rb
    public func isValid(limits: PollLimits) -> Bool {
        let filled = filledOptions
        return (2...limits.maxOptions).contains(filled.count)
            && filled.allSatisfy { $0.count <= limits.maxCharactersPerOption }
            && Set(filled).count == filled.count
            && limits.expirationRange.contains(expiresIn)
    }

    /// 投稿のフォームに足す項目。
    var formItems: [URLQueryItem] {
        filledOptions.map { URLQueryItem(name: "poll[options][]", value: $0) } + [
            URLQueryItem(name: "poll[expires_in]", value: String(expiresIn)),
            URLQueryItem(name: "poll[multiple]", value: multiple ? "true" : "false"),
            URLQueryItem(name: "poll[hide_totals]", value: hidesTotals ? "true" : "false"),
        ]
    }
}

/// サーバーが受け付ける投票の上限。
/// https://docs.joinmastodon.org/entities/Instance/#polls
public struct PollLimits: Sendable, Equatable {
    public let maxOptions: Int
    public let maxCharactersPerOption: Int
    /// 締め切りまでの秒数の下限と上限。
    public let expirationRange: ClosedRange<Int>

    public init(maxOptions: Int, maxCharactersPerOption: Int, expirationRange: ClosedRange<Int>) {
        self.maxOptions = maxOptions
        self.maxCharactersPerOption = maxCharactersPerOption
        self.expirationRange = expirationRange
    }

    /// Mastodonの既定値。投票の上限を返さないサーバーと、読めるまでに使う。
    public static let mastodonDefault = PollLimits(maxOptions: 4, maxCharactersPerOption: 50, expirationRange: 300...2_629_746)
}
