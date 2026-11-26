public import Foundation

/// 見本の投稿に添付する写真。どれもUnsplashの写真（Unsplash License）を、見本の大きさに縮めてAVIFにした。
/// 比率の上限を見せる写真は、既定の上限を超える比率にする。上限ちょうどでは、値を変えても見本が変わらないため。
public enum PreviewPhoto: String, CaseIterable, Sendable {
    /// 縦長の比率の上限（既定は3:4）を超える、2:3の写真。
    case tall = "preview-tall"
    /// 横長の比率の上限（既定は3:1）を超える、4:1の写真。ボートが入るよう、元の16:9から切り抜いた。
    case wide = "preview-wide"
    /// 2枚並べる投稿の1枚目。
    case gridFirst = "preview-grid-1"
    /// 2枚並べる投稿の2枚目。
    case gridSecond = "preview-grid-2"

    /// 撮った人。Unsplashの写真のページに出る名前。
    public var photographer: String {
        switch self {
        case .tall: "Nick"
        case .wide: "Ishan @seefromthesky"
        case .gridFirst, .gridSecond: "Alperen Erfidan"
        }
    }

    /// Unsplashの写真のページ。
    public var page: String {
        switch self {
        case .tall: "https://unsplash.com/photos/ElDn5SmTmB4"
        case .wide: "https://unsplash.com/photos/qE1Y8GQKhEk"
        case .gridFirst: "https://unsplash.com/photos/jDGw_rE0XAk"
        case .gridSecond: "https://unsplash.com/photos/cM-6-zgw-pg"
        }
    }

    /// 写真を付けた見本の投稿の本文に書くクレジット。Unsplashの「Photo by 撮った人 on Unsplash」の書き方で、「Photo」を写真のページへのリンクにする。
    /// 同じ人の写真が続くときは、「Photo and photo by 撮った人 on Unsplash」とまとめる。
    public static func credit(_ photos: [PreviewPhoto]) -> String {
        var groups: [(photographer: String, photos: [PreviewPhoto])] = []
        for photo in photos {
            if groups.last?.photographer == photo.photographer {
                groups[groups.count - 1].photos.append(photo)
            } else {
                groups.append((photo.photographer, [photo]))
            }
        }
        let credits = groups.map { group in
            let links = group.photos.enumerated().map { index, photo in
                "<a href=\"\(photo.page)\">\(index == 0 ? "Photo" : "photo")</a>"
            }
            return links.joined(separator: " and ") + " by \(group.photographer) on Unsplash"
        }
        return "<p>\(credits.joined(separator: TextLists.plainSeparator))</p>"
    }
}

/// 見本の投稿と通知に使う画像の場所。画像はUIが用意し、通信しないで読めるURLで渡す（`ImageStores`の`localData`で返す）。
public struct PreviewSampleSources: Sendable {
    /// 見本のアカウントのアイコン。
    public var avatar: URL?
    /// アニメーションを再生する設定の違いを見せる、動くアイコン。用意できなければnilにし、動かないアイコンを使う。
    public var animatedAvatar: URL?
    /// リンクカードの画像。外観ごとに用意する。
    public var darkCard: URL?
    public var lightCard: URL?
    public var photos: [PreviewPhoto: URL]
    /// リンクカードのリンク先。なければ、リンクカードの見本を出さない。
    public var linkCardURL: URL?

    public init(avatar: URL?, animatedAvatar: URL?, darkCard: URL?, lightCard: URL?, photos: [PreviewPhoto: URL], linkCardURL: URL?) {
        self.avatar = avatar
        self.animatedAvatar = animatedAvatar
        self.darkCard = darkCard
        self.lightCard = lightCard
        self.photos = photos
        self.linkCardURL = linkCardURL
    }
}

/// 「投稿の見た目」で、最後に触った項目。見本のどこを示すかと、どの見本を足すかを決める。
public enum AppearanceFocus: Hashable, Sendable {
    case value(AppearanceValue)
    case choice(AppearanceChoice)

    /// 見本を描く外観を決める、この項目が効く外観。
    public enum Scheme: Sendable {
        case light
        case dark
    }

    /// この項目が効く外観。どちらの外観でも効く項目はnil。外観ごとにしか効かない項目を触っている間は、見本をその外観で描く。
    public var scheme: Scheme? {
        switch self {
        case .value(AppearanceCatalog.reactionGlowDarkOpacity): .dark
        case .value(AppearanceCatalog.reactionGlowLightOpacity): .light
        case .choice(let choice) where choice.appliesOnlyInLightAppearance: .light
        default: nil
        }
    }
}

/// 「投稿の見た目」のプレビューに並べる見本の投稿。調整できる部品がどれかの投稿に出るように組む。決まりはdocs/appearance.mdの「プレビュー」にある。
/// 注意書きの開閉と本文のあいだを見せるため、注意書きのある見本（`spoilerStatuses`）は、UIが開いておく。
public struct AppearancePreviewSamples: Sendable {
    /// 見本の投稿を書いた、自分のアカウントのID。見本を並べる一覧に、自分のアカウントとして渡す。
    public static let myAccountID = "preview-scia"

    private let posts: [Status]
    private let lightPosts: [Status]
    private let quote: Status

    public init(now: Date, sources: PreviewSampleSources) {
        posts = Self.posts(now: now, cardImage: sources.darkCard, sources: sources)
        lightPosts = Self.posts(now: now, cardImage: sources.lightCard, sources: sources)
        quote = Self.quote(now: now, sources: sources)
    }

    /// 注意書きのある見本。開いた状態は投稿のIDで持つので、外観ごとの見本で同じIDを1回だけ開く。
    public var spoilerStatuses: [Status] {
        posts.filter { !$0.displayed.spoilerText.isEmpty }
    }

    /// プレビューに並べる見本。引用のカードを出した投稿は、いつも最後に並べる。Xの投稿のカードも同じ値で描くが、Xの投稿は設定でオンにしたときだけ出すため、見本には出さない。
    /// - Parameters:
    ///   - isDark: ダークの外観で描く。リンクカードの画像を外観に合わせる。
    ///   - groups: 見本を出す分類。渡すと、その分類の見本（`sampleIDs(for:focus:appearance:)`）だけを返す。nilならすべての見本を返す。
    ///   - focus: 触っている項目。`groups`を渡したとき、その項目にしか要らない見本を足す。
    public func statuses(isDark: Bool, groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceFocus? = nil, appearance: AppearanceChoices) -> [Status] {
        let shown = groups.map { Self.sampleIDs(for: $0, focus: focus, appearance: appearance) }
        return ((isDark ? posts : lightPosts) + [quote]).filter { shown?.contains($0.id) ?? true }
    }

    /// アクションバーの分類の見本では、いつも出す設定でなくても、見本にアクションバーを出す。
    public static func showsActionBar(inGroups groups: Set<AppearanceGroup.ID>?) -> Bool {
        groups?.contains(AppearanceCatalog.actionBarGroupID) == true
    }

    /// 分類の見本の投稿のID。分類ごとの見本に、触っている項目にしか要らない見本を足す。分類が空なら、分類を並べた画面に出す部品の少ない投稿を1件だけにする。
    public static func sampleIDs(for groups: Set<AppearanceGroup.ID>, focus: AppearanceFocus?, appearance: AppearanceChoices) -> Set<String> {
        let names = groups.isEmpty ? ["basic"] : groups.flatMap { groupSamples[$0] ?? [] } + focusSamples(focus, appearance: appearance)
        return Set(names.map { "preview-\($0)" })
    }

    /// 分類ごとに出す見本。その分類の項目の場所を示せる、なるべく小さい投稿を選ぶ。どの見本も、その分類のどれかの項目に要るものにする。
    /// 行の余白と区切り線は投稿のあいだの見た目なので、行には2件を出す。
    private static let groupSamples: [AppearanceGroup.ID: [String]] = [
        "row": ["basic", "next"],
        "context": ["boost-plain", "emoji-only"],
        "avatar": ["parent", "child"],
        "name": ["basic", "name"],
        "body": ["paragraphs"],
        "spoiler": ["reply"],
        "media": ["thread"],
        "linkCard": ["boost"],
        AppearanceCatalog.xPostGroupID: ["quote"],
        "poll": ["poll"],
        "reactions": ["reactions"],
        "reactionGlow": ["boost-plain", "wide"],
        // 件数を表示する項目があるので、件数の付いた見本にする。
        AppearanceCatalog.actionBarGroupID: ["boost-plain"],
    ]

    /// 分類のうち一部の項目にしか要らない見本。上限を見せる大きい見本などは、ふだん出すと見本の枠からはみ出すので、その項目を触っている間だけ出す。
    /// 右に並べる写真にだけ効く項目は、投稿の添付ファイルを本文の下に並べ、カードの添付ファイルだけを右に並べるときは、引用の見本で見せる。
    private static func focusSamples(_ focus: AppearanceFocus?, appearance: AppearanceChoices) -> [String] {
        let onlyEmbedIsBeside = appearance.mediaArrangement == .belowBody && appearance.resolvedEmbedMediaArrangement == .besideBody
        return switch focus {
        case .value(AppearanceCatalog.bodyTruncationThreshold), .value(AppearanceCatalog.bodyTruncatedLines): ["long"]
        case .value(AppearanceCatalog.emojiOnlyScale), .value(AppearanceCatalog.emojiOnlyLimit): ["emoji-only"]
        case .value(AppearanceCatalog.filterNoteText), .value(AppearanceCatalog.filterNoteSpacing): ["filtered"]
        case .value(AppearanceCatalog.mediaTallestAspectRatio): ["media"]
        case .value(AppearanceCatalog.mediaWidestAspectRatio): ["wide"]
        case .choice(.embedMediaArrangement): ["quote"]
        case .choice(.showsReadMore): ["long"]
        case .choice(.showsFilterNote): ["filtered"]
        case .value(AppearanceCatalog.mediaBesideSide), .choice(.tiltsStackedPhotos): onlyEmbedIsBeside ? ["quote"] : []
        default: []
        }
    }

    private static let quoteID = "preview-quote"

    /// 投稿を引用した投稿。引用元には、カードの中の部品が出るよう、本文と画像を付ける。
    private static func quote(now: Date, sources: PreviewSampleSources) -> Status {
        let image = sources.photos[.wide]
        let avatar = sources.avatar
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち", avatar: avatar)
        let scia = Account(id: myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: avatar)
        let attachment = MediaAttachment(
            id: "preview-quote-image",
            type: .image,
            url: image,
            previewUrl: image,
            // 見本の枠に収まるよう、横長の写真にする。
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_600, height: 400))
        )
        let quoted = Status(
            id: "preview-quoted",
            createdAt: now.addingTimeInterval(-3_600),
            account: scia,
            content: PreviewPhoto.credit([.wide]),
            spoilerText: "",
            url: nil,
            mediaAttachments: [attachment]
        )
        return Status(
            id: quoteID,
            createdAt: now.addingTimeInterval(-60),
            account: friend,
            content: "<p>投稿を引用した投稿です。</p>",
            spoilerText: "",
            url: nil,
            quote: Quote(state: "accepted", quotedStatus: quoted)
        )
    }

    private static func posts(now: Date, cardImage: URL?, sources: PreviewSampleSources) -> [Status] {
        let avatar = sources.avatar
        // アニメーションを再生する設定の違いを見せるため、アイコンと絵文字には色相の回るアニメーション版を付ける。
        let animated = sources.animatedAvatar ?? avatar
        let scia = Account(id: myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: animated, avatarStatic: avatar)
        // カスタム絵文字の大きさを見せるため、アプリのアイコンを絵文字にする。
        let emojis = avatar.map { [CustomEmoji(shortcode: "scia", url: animated ?? $0, staticUrl: $0)] } ?? []
        // 名前の絵文字とカスタム絵文字の大きさを見せるため、名前にも絵文字と本文と同じカスタム絵文字を付ける。
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち🌱:scia:", avatar: animated, avatarStatic: avatar, emojis: emojis)
        // 入りきらない名前の行末のぼかしを見せるため、名前の長いアカウントも用意する。
        // 名前の絵文字の大きさも同じ投稿で見せるため、名前に絵文字とカスタム絵文字を入れる。
        let longNamed = Account(id: "preview-long", username: "long", acct: "long@example.com", displayName: "とても長い名前🌱:scia:のアカウントで、名前の行に入りきりません", avatar: animated, avatarStatic: avatar, emojis: emojis)
        func photo(_ photo: PreviewPhoto, width: Int, height: Int, description: String? = nil) -> MediaAttachment {
            let url = sources.photos[photo]
            return MediaAttachment(
                id: photo.rawValue,
                type: .image,
                url: url,
                previewUrl: url,
                description: description,
                meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: width, height: height))
            )
        }
        // 縦長と横長の比率の上限を見せるため、縦長の写真と横長の写真を1枚ずつ出す投稿を用意する。
        let tallImage = photo(.tall, width: 1_200, height: 1_800)
        let wideImage = photo(.wide, width: 1_600, height: 400)
        // 代替テキストのバッジを見せるため、1枚には代替テキストを付ける。
        let describedImage = photo(.gridFirst, width: 800, height: 800, description: "窓辺の猫")
        let image = photo(.gridSecond, width: 800, height: 800)
        let ownFilter = FilterResult(
            filter: FilterResult.Filter(id: "preview-filter", title: "見本", context: [.home], filterAction: .warn),
            keywordMatches: ["見本"]
        )
        let card = sources.linkCardURL.map {
            PreviewCard(
                url: $0,
                // 行数を増やしたときの折り返しを見せるため、タイトルも説明も1行に入りきらない長さにする。
                title: "eai04191/scia: ストリーミングAPIに対応した、手触りの良いiOS向けMastodonクライアント",
                description: "ストリーミングAPIで新着が流れてくる、手触りの良いiOS向けMastodonクライアントです。読んでいる最中に新着が来ても視点が動きません。",
                type: .link,
                providerName: "GitHub",
                image: cardImage
            )
        }
        // 絵文字のリアクションのボタンのあいだと折り返しを見せるため、Unicodeの絵文字とカスタム絵文字のリアクションを、見本の枠で2行に折り返す数だけ付ける。
        let reactions = [("👍", 12, true), ("🎉", 5, false)].map { EmojiReaction(emoji: ReactionEmoji(name: $0.0), count: $0.1, me: $0.2) }
            + emojis.map { EmojiReaction(emoji: ReactionEmoji(customEmoji: $0), count: 3, me: false) }
            + [("😂", 2), ("🙏", 1), ("❤️", 128), ("👀", 1)].map { EmojiReaction(emoji: ReactionEmoji(name: $0.0), count: $0.1, me: false) }
        func status(_ id: String, minutes: Double, account: Account, content: String, spoiler: String = "", media: [MediaAttachment] = [], poll: Poll? = nil, card: PreviewCard? = nil, replyingTo: Account? = nil, inReplyTo: Status.ID = "preview-thread", visibility: Status.Visibility = .public, edited: Bool = false, emojis: [CustomEmoji] = [], filtered: [FilterResult] = [], favourited: Bool = false, reblogged: Bool = false, emojiReactions: [EmojiReaction] = [], counts: (replies: Int, reblogs: Int, favourites: Int) = (0, 0, 0)) -> Status {
            Status(
                id: "preview-\(id)",
                createdAt: now.addingTimeInterval(-minutes * 60),
                account: account,
                content: content,
                spoilerText: spoiler,
                url: nil,
                mentions: replyingTo.map { [Mention(id: $0.id, username: $0.username, url: nil, acct: $0.acct)] } ?? [],
                emojis: emojis,
                mediaAttachments: media,
                visibility: visibility,
                inReplyToId: replyingTo.map { _ in inReplyTo },
                inReplyToAccountId: replyingTo?.id,
                poll: poll,
                card: card,
                filtered: filtered,
                editedAt: edited ? now : nil,
                favourited: favourited,
                reblogged: reblogged,
                favouritesCount: counts.favourites,
                reblogsCount: counts.reblogs,
                emojiReactions: emojiReactions,
                repliesCount: counts.replies
            )
        }
        // お気に入りとブーストの光を見せるため、ブーストした投稿は、お気に入りとブーストをした投稿にする。
        let boosted = status("boosted", minutes: 30, account: friend, content: #"<p>段落の1つ目です。設定を変えるとタイムラインの投稿がこのように表示されます🎉:scia:</p><p>段落の2つ目です。<a href="https://github.com/eai04191/scia">github.com/eai04191/scia</a></p>"#, card: card, emojis: emojis, favourited: true, reblogged: true)
        let boost = Status(id: "preview-boost", createdAt: now.addingTimeInterval(-180), account: scia, content: "", spoilerText: "", url: nil, reblog: boosted)
        // 名前の上の行と光の分類の画面に出す、リンクカードのないブースト。アクションバーの分類の画面にも出すので、件数を付ける。
        let plainBoosted = status("boosted-plain", minutes: 40, account: friend, content: "<p>ブーストされた投稿です。</p>", emojis: emojis, favourited: true, reblogged: true, counts: (2, 12, 34))
        let plainBoost = Status(id: "preview-boost-plain", createdAt: now.addingTimeInterval(-240), account: scia, content: "", spoilerText: "", url: nil, reblog: plainBoosted)
        let poll = Poll(
            id: "preview-poll",
            expiresAt: now.addingTimeInterval(86_400),
            expired: false,
            multiple: false,
            votesCount: 12,
            options: [Poll.Option(title: "円", votesCount: nil), Poll.Option(title: "四角", votesCount: nil)]
        )
        return [
            // 分類を並べた画面に出す、部品の少ない投稿。
            status("basic", minutes: 1, account: scia, content: "<p>設定を変えるとタイムラインの投稿がこのように表示されます。</p>"),
            boost,
            // 注意書きのある投稿の画像はぼかされ、サムネイル同士のgapが見えないため、画像は注意書きのない投稿に付ける。
            status("thread", minutes: 20, account: scia, content: PreviewPhoto.credit([.gridFirst, .gridSecond]), media: [describedImage, image]),
            // 公開範囲の記号と編集済みの「*」を見せるため、未収載で編集した投稿にする。
            status("reply", minutes: 12, account: friend, content: "<p>注意書きの下の本文です。</p>", spoiler: "注意書き", replyingTo: scia, visibility: .unlisted, edited: true),
            status("media", minutes: 8, account: scia, content: PreviewPhoto.credit([.tall]), media: [tallImage]),
            // 絵文字だけの本文を見せるため、先頭にメンションの付いた、絵文字だけの返信を用意する。メンションは大きくしない。
            status("emoji-only", minutes: 7.5, account: friend, content: #"<p><span class="h-card"><a href="https://example.com/@scia" class="u-url mention">@<span>scia</span></a></span> 👍:scia:🎉</p>"#, replyingTo: scia, emojis: emojis),
            // 長い本文を切って「続きを読む」を出すところを見せるため、1行ずつの段落を、既定の切り始める行数より1行だけ多く並べる。
            // 切り始める行数を少し増やすと切らなくなり、値の違いが見本に出る。
            status("long", minutes: 7.2, account: scia, content: (1...33).map { "<p>長い本文の\($0)行目です。</p>" }.joined()),
            // 片方だけのときの光の幅を見せるため、お気に入りだけをした投稿にする。
            status("wide", minutes: 7, account: friend, content: PreviewPhoto.credit([.wide]), media: [wideImage], favourited: true),
            status("poll", minutes: 5, account: longNamed, content: "<p>アイコンの形はどちらが好きですか？</p>", poll: poll),
            status("reactions", minutes: 4, account: friend, content: "<p>絵文字のリアクションが付いた投稿です。</p>", emojiReactions: reactions),
            status("filtered", minutes: 2, account: scia, content: "<p>自分のフィルターに一致した自分の投稿です。</p>", filtered: [ownFilter]),
            // 名前の行の部品を1件で見せる投稿。入りきらない名前、公開範囲の記号、編集済みの「*」を出し、名前と画像のあいだを見せるため本文を付けないので、写真のクレジットは書かない。
            // 画像は、見本の枠に収まるよう横長にする。
            status("name", minutes: 1.5, account: longNamed, content: "", media: [wideImage], visibility: .unlisted, edited: true),
            // 段落のあいだ、引用のインデント、本文の絵文字を見せる投稿。
            status("paragraphs", minutes: 1.2, account: friend, content: "<p>段落の1つ目です🎉:scia:</p><blockquote><p>引用した文です。</p></blockquote><p>段落の2つ目です。</p>", emojis: emojis),
            plainBoost,
            // 行の余白と区切り線を見せる、部品の少ない投稿の次に並べる1行の投稿。
            status("next", minutes: 0.5, account: scia, content: "<p>次の投稿です。</p>"),
            // 返信をつなぐ線を見せる、本文だけの2件。タイムラインと同じく、すぐ上の投稿への返信は線でつなぎ、返信のラベルを出さない。
            status("parent", minutes: 1.1, account: scia, content: "<p>返信でつながった投稿の最初の投稿です。</p>"),
            status("child", minutes: 1, account: friend, content: "<p>返信です。</p>", replyingTo: scia, inReplyTo: "preview-parent"),
        ]
    }
}

/// 「通知の見た目」のプレビューに並べる見本の通知。調整できる部品がどれかの行に出るように組む。決まりはdocs/appearance.mdの「プレビュー」にある。
public struct NotificationAppearancePreviewSamples: Sendable {
    public static let myAccountID = AppearancePreviewSamples.myAccountID

    /// 見本の通知が使う写真。UIは、この写真とアイコン（`PreviewSampleSources.avatar`）だけを用意すればよい。
    /// サムネイル同士のgapが見えるよう、違う写真を2枚付ける。同じ人の写真にし、クレジットを1行に収める。
    public static let photos: [PreviewPhoto] = [.gridFirst, .gridSecond]

    private let notifications: [MastodonNotification]

    public init(now: Date, sources: PreviewSampleSources) {
        notifications = Self.notifications(date: now.addingTimeInterval(-600), sources: sources)
    }

    /// プレビューに並べる見本。
    /// - Parameters:
    /// - Parameter groups: 見本を出す分類。渡すと、その分類の見本（`sampleIDs(for:)`）だけを返す。nilならすべての見本を返す。
    public func notifications(groups: Set<AppearanceGroup.ID>? = nil) -> [MastodonNotification] {
        let shown = groups.map { Self.sampleIDs(for: $0) }
        return notifications.filter { shown?.contains($0.id) ?? true }
    }

    /// 分類の見本の通知のID。分類が空なら、分類を並べた画面に出す部品の少ない通知を1件だけにする。
    public static func sampleIDs(for groups: Set<AppearanceGroup.ID>) -> Set<String> {
        let names = groups.isEmpty ? ["follow"] : groups.flatMap { groupSamples[$0] ?? [] }
        return Set(names.map { "preview-\($0)" })
    }

    /// 分類ごとに出す見本。その分類の項目が効く部品の出る、なるべく小さい通知を選び、既定の設定では見本の枠に収まるようにする。
    /// 種類の記号の文字の列とのgapは、メンションなどの名前の上の行の記号にも効くので、メンションも出す。
    private static let groupSamples: [AppearanceGroup.ID: [String]] = [
        "group": ["group"],
        "header": ["follow"],
        "symbol": ["follow", "mention"],
        "account": ["follow"],
        "quoted": ["reblog"],
        "context": ["mention"],
    ]

    private static func notifications(date: Date, sources: PreviewSampleSources) -> [MastodonNotification] {
        let avatar = sources.avatar
        let scia = Account(id: myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: avatar)
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち", avatar: avatar)
        let others = ["さくら", "もみじ", "つばき"].enumerated().map { index, name in
            Account(id: "preview-other-\(index)", username: "other\(index)", acct: "other\(index)@example.com", displayName: name, avatar: avatar)
        }
        func photo(_ photo: PreviewPhoto) -> MediaAttachment {
            let url = sources.photos[photo]
            return MediaAttachment(id: photo.rawValue, type: .image, url: url, previewUrl: url, meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 800, height: 800)))
        }
        let photos = Self.photos
        let quoted = Status(id: "preview-quoted", createdAt: date, account: friend, content: "<p>引用した投稿です。</p>", spoilerText: "", url: nil)
        // 本文の行数とサムネイルと引用を示す行を見せるため、長い本文に画像を並べ、投稿を引用した自分の投稿にする。
        // 写真のクレジットは、本文を設定した行数で切っても見えるよう、本文の先頭に書く。
        let reshown = Status(
            id: "preview-reshown",
            createdAt: date,
            account: scia,
            content: PreviewPhoto.credit(photos) + "<p>ブーストされた自分の投稿です。本文が長いときは設定した行数で切ります。誰が何をしたかの行を主役にするため、本文は控えめな色で短く出します。添付ファイルは小さなサムネイルを1列に並べます。</p>",
            spoilerText: "",
            url: nil,
            mediaAttachments: photos.map(photo),
            quote: Quote(state: "accepted", quotedStatus: quoted)
        )
        let mention = Status(
            id: "preview-mentioning",
            createdAt: date,
            account: friend,
            content: #"<p><span class="h-card"><a href="https://example.com/@scia" class="u-url mention">@<span>scia</span></a></span> メンションです。</p>"#,
            spoilerText: "",
            url: nil,
            mentions: [Mention(id: scia.id, username: scia.username, url: nil, acct: scia.acct)]
        )
        return [
            // 分類を並べた画面に出す、部品の少ない通知。誰が何をしたかの行と、種類の記号と、ハンドルを見せる。
            MastodonNotification(id: "preview-follow", type: .follow, createdAt: date, account: friend),
            // まとめた通知のアイコンを見せる、誰が何をしたかの行だけのまとめた通知。
            MastodonNotification(
                id: "preview-group", type: .follow, createdAt: date, account: others[0],
                groupKey: "follow-preview", notificationsCount: 5, sampleAccounts: others + [friend]
            ),
            MastodonNotification(id: "preview-reblog", type: .reblog, createdAt: date, account: friend, status: reshown),
            MastodonNotification(id: "preview-mention", type: .mention, createdAt: date, account: friend, status: mention),
        ]
    }
}
