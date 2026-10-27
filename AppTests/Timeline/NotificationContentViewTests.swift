import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

@Suite(.scratch)
@MainActor
struct NotificationContentViewTests {
    private func image(_ id: String) -> MediaAttachment {
        MediaAttachment(
            id: id,
            type: .image,
            url: URL(string: "https://files.example.social/original/\(id).png"),
            previewUrl: URL(string: "https://files.example.social/small/\(id).png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_475, height: 665))
        )
    }

    private func visibleLabels(in view: UIView) -> [UILabel] {
        view.subviews.filter { !$0.isHidden }.flatMap { subview in
            (subview as? UILabel).map { [$0] } ?? visibleLabels(in: subview)
        }
    }

    /// 一覧は行の高さを画素に丸めるため、行が求める高さより1画素未満だけ低くなることがある。
    /// 足りない分を文字のラベルから削ると、UILabelは収まらない行を描かず、2行の本文が1行で切れて見えた。
    /// 足りない分は行の下の余白で吸い、文字のラベルは求める高さを保つ。
    @Test(arguments: [false, true])
    func labelsKeepTheirHeightWhenRowIsSlightlyShort(withMedia: Bool) throws {
        let vc = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline, avatarImages: .offline, settings: .isolated())
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let status = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: "<p>急に全部のアプリが死んで何と思ったらclaudeにultrakillされてた</p>",
            spoilerText: "",
            url: nil,
            mediaAttachments: withMedia ? [image("1")] : []
        )
        let actor = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: base.account.avatar)
        let notification = MastodonNotification(id: "1", type: .favourite, createdAt: Date(timeIntervalSince1970: 0), account: actor, status: status)
        let view = vc.contentConfiguration(for: notification, base: .cell()).makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height - 0.3)
        view.layoutIfNeeded()
        let labels = visibleLabels(in: view)

        #expect(labels.count >= 2)
        for label in labels {
            #expect(label.bounds.height >= label.intrinsicContentSize.height - 0.01, "\(label.text ?? "") label=\(label.bounds) intrinsic=\(label.intrinsicContentSize)")
        }
    }

    /// 誰が何をしたかの行とまとめた行のアイコンのタップで開くプロフィールは、VoiceOverでは通知の要素の操作で開く。まとめた行では人ごとに出す。
    @Test(arguments: [false, true])
    func profilesOpenFromVoiceOverActions(grouped: Bool) throws {
        let vc = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline, avatarImages: .offline, settings: .isolated())
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)
        let carol = Account(id: "3", username: "carol", acct: "carol", displayName: "Carol", avatar: nil)
        let notification = MastodonNotification(
            id: "1",
            type: .favourite,
            createdAt: Date(timeIntervalSince1970: 0),
            account: bob,
            status: status,
            groupKey: grouped ? "favourite-1" : nil,
            notificationsCount: grouped ? 2 : 1,
            sampleAccounts: grouped ? [bob, carol] : nil
        )
        var opened: [Account.ID] = []
        vc.onOpenProfile = { opened.append($0.id) }
        let view = vc.contentConfiguration(for: notification, base: .cell()).makeContentView()
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        let actions = (element.accessibilityCustomActions ?? []).filter { $0.name.hasSuffix("のプロフィール") }

        #expect(actions.map(\.name) == (grouped ? ["Bobのプロフィール", "Carolのプロフィール"] : ["Bobのプロフィール"]))
        for action in actions {
            _ = action.actionHandler?(action)
        }
        #expect(opened == (grouped ? ["2", "3"] : ["2"]))
    }

    /// 名前の前に差し込むアイコンも、角丸の四角の丸みを「投稿の見た目」の設定に従わせる。丸みを0にすると、四隅も中央と同じ濃さで塗る。
    @Test func headerAvatarFollowsCornerRatio() throws {
        let settings = AppSettings.isolated()
        settings.avatarShape = .roundedSquare
        settings.setValue(0, for: AppearanceCatalog.avatarCornerRatio)
        let vc = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline, avatarImages: .offline, settings: settings)
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)
        let notification = MastodonNotification(id: "1", type: .follow, createdAt: Date(timeIntervalSince1970: 0), account: bob, status: nil)
        let configuration = try #require(vc.contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)
        let attachment = try #require(configuration.header.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let image = try #require(attachment.image?.cgImage)
        // 画像のないアイコンは半透明の灰色で塗るので、濃さは中央の画素と比べる。
        let center = try alpha(of: image, x: image.width / 2, y: image.height / 2)
        #expect(center > 0)
        #expect(try alpha(of: image, x: 0, y: 0) == center)
    }

    /// 上端から数えた位置の画素の濃さ。
    private func alpha(of image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // その1画素だけが、1×1の描く先に入るようずらして描く。CGContextの原点は左下なので、上端からの位置を下からの位置に直す。
        context.draw(image, in: CGRect(x: -CGFloat(x), y: CGFloat(y + 1 - image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
        return pixel[3]
    }
}

@Suite(.scratch)
@MainActor
struct NotificationAppearanceTests {
    private func makeViewController(_ settings: AppSettings) -> TimelineViewController {
        TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline, avatarImages: .offline, settings: settings)
    }

    /// 通知の行の組み方をひととおり。再掲する投稿には、本文、注意書き、画像、投票、引用を付ける。
    private func notifications() throws -> [MastodonNotification] {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: base.account.avatar)
        let carol = Account(id: "3", username: "carol", acct: "carol", displayName: "Carol", avatar: base.account.avatar)
        let image = MediaAttachment(id: "1", type: .image, url: base.account.avatar, previewUrl: base.account.avatar, meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 400, height: 300)))
        let poll = Poll(id: "p", expiresAt: Date(timeIntervalSince1970: 0), expired: true, multiple: false, votesCount: 3, options: [Poll.Option(title: "はい", votesCount: 2), Poll.Option(title: "いいえ", votesCount: 1)])
        let quoted = Status(id: "q", createdAt: base.createdAt, account: bob, content: "<p>引用元。</p>", spoilerText: "", url: nil)
        let mine = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: "<p>" + String(repeating: "再掲する本文。", count: 20) + "</p>",
            spoilerText: "注意書き",
            url: nil,
            mediaAttachments: [image, image],
            poll: poll,
            quote: Quote(state: "accepted", quotedStatus: quoted)
        )
        let date = Date(timeIntervalSince1970: 0)
        return [
            MastodonNotification(id: "1", type: .favourite, createdAt: date, account: bob, status: mine),
            MastodonNotification(id: "2", type: .poll, createdAt: date, account: bob, status: mine),
            MastodonNotification(id: "3", type: .follow, createdAt: date, account: bob),
            MastodonNotification(id: "4", type: .reblog, createdAt: date, account: bob, status: mine, groupKey: "reblog-4", notificationsCount: 3, sampleAccounts: [bob, carol]),
            MastodonNotification(id: "5", type: .mention, createdAt: date, account: bob, status: Status(id: "m", createdAt: date, account: bob, content: "<p>@me メンション。</p>", spoilerText: "", url: nil)),
        ]
    }

    /// 既定値と範囲の両端で、通知の行を組んで落ちず、行の高さが有限になる。通知の一覧は起動してすぐ描くため、ある値で落ちると設定まで戻れない。
    /// - Parameter extreme: 全項目を最小にするならfalse、最大にするならtrue、既定値のままならnil。
    @Test(arguments: [nil, false, true] as [Bool?])
    func extremesLayOutWithFiniteHeights(extreme: Bool?) throws {
        let settings = AppSettings.isolated()
        if let atMaximum = extreme {
            for item in NotificationAppearanceCatalog.values {
                settings.setValue(atMaximum ? item.range.upperBound : item.range.lowerBound, for: item)
            }
        }
        let vc = makeViewController(settings)
        for notification in try notifications() {
            _ = vc.avatarKeys(for: notification)
            let view = vc.contentConfiguration(for: notification, base: .cell()).makeContentView()
            let height = view.systemLayoutSizeFitting(
                CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            #expect(height.isFinite && height > 0 && height < 100_000, "\(notification.type)の行の高さが\(height)になりました")
        }
    }

    /// 再掲する投稿の、サムネイル、投票、引用を示す行のあいだは、それぞれの項目で決まる。
    @Test func quotedSpacingsAreIndependent() throws {
        typealias N = NotificationAppearanceCatalog
        let settings = AppSettings.isolated()
        settings.setValue(11, for: N.quotedMediaSpacing)
        settings.setValue(12, for: N.quotedPollSpacing)
        settings.setValue(13, for: N.quotedNoteSpacing)
        settings.setValue(14, for: N.quotedSpacing)
        settings.setValue(15, for: N.quotedThumbnailSpacing)
        settings.setValue(50, for: N.quotedThumbnailSize)
        let notification = try #require(notifications().first { $0.type == .poll })
        let configuration = try #require(makeViewController(settings).contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)
        #expect(configuration.body.mediaSpacing == 11)
        #expect(configuration.body.pollSpacing == 12)
        #expect(configuration.body.filterNoteSpacing == 13)
        #expect(configuration.metrics.bodySpacing == 14)
        #expect(configuration.body.media?.spacing == 15)
        #expect(configuration.body.media?.arrangement == .strip(side: 50))
    }

    /// 再掲する本文と引用を示す行は「通知の見た目」の文字で描き、投稿の本文の文字との差を保つ。
    @Test func quotedTextFollowsNotificationTypography() throws {
        let settings = AppSettings.isolated()
        settings.setValue(-3, for: NotificationAppearanceCatalog.quotedBodyText)
        let typography = PostTypography(settings: settings)
        let notification = try #require(notifications().first)
        let configuration = try #require(makeViewController(settings).contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)
        let font = try #require(configuration.body.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.pointSize == typography.font(.notificationQuotedBody).pointSize)
        #expect(typography.standardPointSize(.notificationQuotedBody) == typography.standardPointSize(.body) - 3)
    }

    /// メンションは投稿として描き、名前の上に足す誰が何をしたかの行だけを「通知の見た目」で描く。
    @Test func mentionContextFollowsNotificationSettings() throws {
        typealias N = NotificationAppearanceCatalog
        let settings = AppSettings.isolated()
        settings.setValue(9, for: N.symbolSpacing)
        settings.setValue(7, for: N.contextSpacing)
        settings.setValue(3, for: N.contextText)
        // 再掲する投稿の文字を変えても、メンションの本文は変わらない。
        settings.setValue(-5, for: N.quotedBodyText)
        let vc = makeViewController(settings)
        let notification = try #require(notifications().first { $0.type == .mention })
        let configuration = try #require(vc.contentConfiguration(for: notification, base: .cell()) as? PostContentConfiguration)
        let typography = PostTypography(settings: settings)
        #expect(configuration.metrics.contextSymbolSpacing == 9)
        #expect(configuration.metrics.contextSpacing == 7)
        let contextFont = try #require(configuration.context?.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(contextFont.pointSize == typography.font(.notificationContext).pointSize)
        #expect(configuration.context?.notificationSymbolFont?.pointSize == typography.font(.notificationHeader).pointSize)
        let bodyFont = try #require(configuration.body.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(bodyFont.pointSize == typography.font(.body).pointSize)
    }

    /// 名前の前のアイコンと名前のすき間は、設定の値だけ広がる。添付ファイルの文字には字送りが効かないため、効く文字で空ける。
    @Test func headerAvatarNameSpacingWidensHeader() throws {
        func headerWidth(spacing: Double) throws -> CGFloat {
            let settings = AppSettings.isolated()
            settings.setValue(spacing, for: NotificationAppearanceCatalog.headerAvatarNameSpacing)
            let notification = try #require(notifications().first { $0.type == .follow })
            let configuration = try #require(makeViewController(settings).contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)
            let label = UILabel()
            label.attributedText = configuration.header
            return label.intrinsicContentSize.width
        }
        #expect(abs(try headerWidth(spacing: 20) - headerWidth(spacing: 0) - 20) < 0.5)
    }

    /// まとめた通知のアイコンは、行の幅に収まらないほど大きくしても、大きさを保ったまま行の中で切る。
    @Test func largeGroupAvatarsStayInsideRow() throws {
        let settings = AppSettings.isolated()
        settings.setValue(200, for: NotificationAppearanceCatalog.groupAvatarSize)
        let notification = try #require(notifications().first { $0.isGroup })
        let view = makeViewController(settings).contentConfiguration(for: notification, base: .cell()).makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let avatars = allSubviews(of: view).compactMap { $0 as? AvatarView }
        #expect(avatars.count == 2)
        for avatar in avatars {
            #expect(avatar.bounds.size == CGSize(width: 200, height: 200))
        }
        // 見えている範囲は、行の右の余白より内側に収まる。
        let visible = avatars.map { avatar in
            var rect = avatar.convert(avatar.bounds, to: view)
            var ancestor = avatar.superview
            while let current = ancestor, current !== view {
                if current.clipsToBounds { rect = rect.intersection(current.convert(current.bounds, to: view)) }
                ancestor = current.superview
            }
            return rect
        }
        for rect in visible where !rect.isNull {
            #expect(rect.maxX <= 402 - settings.rowMargins.trailing + 0.5)
        }
    }

    /// まとめた通知のアイコンを0にすると、出さないアイコンの画像を先読みしない。
    @Test func zeroGroupAvatarSizeSkipsPrefetch() throws {
        let settings = AppSettings.isolated()
        settings.setValue(0, for: NotificationAppearanceCatalog.groupAvatarSize)
        let notification = try #require(notifications().first { $0.isGroup })
        #expect(makeViewController(settings).avatarKeys(for: notification).isEmpty)
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    /// 名前の前のアイコンは行の高さに対する割合で大きさを決め、0にするとアイコンもすき間も置かない。
    @Test func headerAvatarScaleZeroRemovesAvatar() throws {
        let settings = AppSettings.isolated()
        settings.setValue(0, for: NotificationAppearanceCatalog.headerAvatarScale)
        let vc = makeViewController(settings)
        let notification = try #require(notifications().first { $0.type == .follow })
        let configuration = try #require(vc.contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)
        #expect(configuration.header.string == "Bobにフォローされました")
        #expect(vc.avatarKeys(for: notification).isEmpty)
    }
}
