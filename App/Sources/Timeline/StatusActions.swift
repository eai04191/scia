import SciaCore
import UIKit

/// 投稿に対する操作。一覧では長押しのメニューから選ぶ。
enum StatusAction {
    case reply
    case favourite
    case reblog
    /// 公開範囲を選んでブーストする。
    case reblogWithVisibility(ReblogVisibility)
    case bookmark
    /// 投稿欄で投稿を引用して書き始める。
    case quote
    case muteConversation
    case pin
    case editHistory
    /// 投稿をお気に入りした人の一覧を開く。
    case openFavouritedBy
    /// 投稿をブーストした人の一覧を開く。
    case openRebloggedBy
    case edit
    case delete
}

/// メニューにプレースホルダーのアイコンを出し、アイコンを読んでから差し替える人。
struct PendingMenuIcon {
    let user: MenuUser
    /// 分かっているアカウント。メンションされた人で、一覧にも読み込み済みのものにもいなければnil。
    let account: Account?
    let placeholder: UIImage
}

/// フォローリクエストへの返事。
enum FollowRequestDecision {
    case authorize
    case reject
}

extension TimelineViewController {
    /// 要素が指す投稿。通知なら対象の投稿。ギャップやフォローの通知などではnil。
    func status(for id: ItemID) -> Status? {
        entry(for: id).flatMap(Self.status(of:))
    }

    static func status(of entry: TimelineEntry) -> Status? {
        switch entry {
        case .status(let status), .pinned(let status): status
        case .notification(let notification): notification.status
        case .gap, .unreadable, .account: nil
        }
    }

    /// 長押しのメニュー。並びは設定の投稿のメニューに従い、関係するユーザーはユーザーのメニューのサブメニューにする。決まりはdocs/menus.mdにある。
    /// フォローリクエストの通知では、設定の並びの前に、承認と却下を設定によらず置く。
    /// 出す項目がなければnil。
    /// - Parameter id: メニューを出した要素。共有のシートを、その行から出す。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func contextMenu(for entry: TimelineEntry, id: ItemID, groups: MenuLayout<StatusMenuItem>.Groups? = nil) -> UIMenu? {
        // 組みながら集めた、アイコンのまだない人をまとめて読む。
        defer { loadPendingMenuIcons() }
        // 人の一覧の行では、その人へのユーザーのメニューを、そのまま出す。
        if case .account(let account) = entry {
            defer { reloadRelations([account.id]) }
            return userElement(for: .account(account), id: id).map { UIMenu(children: [$0]) }
        }
        let status = Self.status(of: entry)
        let notification: MastodonNotification? = if case .notification(let notification) = entry { notification } else { nil }
        var shownUserIDs: Set<String> = []
        var children = (groups ?? settings.statusMenuLayout.groups).menuElements { item in
            elements(for: item, status: status, notification: notification, id: id, shownUserIDs: &shownUserIDs)
        }
        if groups == nil, case .notification(let notification) = entry, notification.type == .followRequest {
            children.insert(followRequestMenu(for: notification), at: 0)
        }
        reloadRelations(Array(shownUserIDs))
        return children.isEmpty ? nil : UIMenu(children: children)
    }

    /// メニューに出る人の関係を、まとめて1回で読み直す。組んだメニューは覚えていた関係のまま出し、読み直した関係は次に開いたときから使う。
    /// 覚えていなかった人の関係の項目は、この読み直しを待って中身を渡す。関係で中身が変わる項目を出していなければ読まない。
    private func reloadRelations(_ ids: [String]) {
        guard !ids.isEmpty, settings.userMenuLayout.groups.needsRelationship else { return }
        userMenuActions?.reloadRelations(ids)
    }

    private func followRequestMenu(for request: MastodonNotification) -> UIMenu {
        UIMenu(options: .displayInline, children: [
            UIAction(title: "承認", image: UIImage(systemName: "checkmark")) { [weak self] _ in
                self?.onFollowRequestDecision?(.authorize, request)
            },
            UIAction(title: "却下", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.onFollowRequestDecision?(.reject, request)
            },
        ])
    }

    /// 同じユーザーが2つの項目に当たるときは、先に出る項目で1度だけ出す。
    /// - Parameter notification: 通知のメニューなら、その通知。
    private func elements(for item: StatusMenuItem, status: Status?, notification: MastodonNotification?, id: ItemID, shownUserIDs: inout Set<String>) -> [UIMenuElement] {
        func users(_ users: [MenuUser]) -> [UIMenuElement] {
            users.filter { shownUserIDs.insert($0.id).inserted }.compactMap { userElement(for: $0, id: id) }
        }
        switch item {
        case .notifyingUser:
            // まとめた通知では、並べた人をみな出す。
            return users(notification.map { $0.sampleAccounts.map(MenuUser.account) } ?? [])
        case .reblogWithVisibility:
            guard let status else { return [] }
            return reblogWithVisibilityMenu(for: status, item: item).map { [$0] } ?? []
        case .dismissNotification:
            // 投稿のない通知（フォローなど）でも出す。
            guard let notification else { return [] }
            return [UIAction(title: item.title, image: item.image) { [weak self] _ in
                self?.onDismissNotification?(notification)
            }]
        case .openThread:
            guard let status, canOpenThread(of: status) else { return [] }
            return [UIAction(title: item.title, image: item.image) { [weak self] _ in
                guard let self else { return }
                recordOpenThread()
                onOpenThread?(status, rowFrame(of: id))
            }]
        case .author:
            return users(status.map { [.account($0.displayed.account)] } ?? [])
        case .booster:
            guard let status, status.reblog != nil else { return [] }
            return users([.account(status.account)])
        case .mentionedUsers:
            return users(status?.displayed.mentions.map(MenuUser.mention) ?? [])
        case .customEmojis:
            let emojis = notification?.emojisInRow ?? status?.emojisInRow ?? []
            let subject = status.map { OperationStatus.Subject($0.displayed) }
            return emojis.compactMap { emojiElement(for: $0, subject: subject) }
        case .hashtags:
            guard let shown = status?.displayed else { return [] }
            return hashtagElements(of: shown, id: id)
        case .reply, .favourite, .reblog, .bookmark, .quote, .muteConversation, .pin, .copyLink, .copyText, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .editHistory, .favouritedBy, .rebloggedBy, .hideMedia, .systemTranslate, .selectText, .edit, .delete:
            guard let status else { return [] }
            return statusAction(item, on: status, isNotification: notification != nil, id: id).map { [$0] } ?? []
        }
    }

    /// 投稿への操作。ユーザーの項目は`userElement(for:)`で組むため、nilを返す。
    /// - Parameter isNotification: 通知のメニュー。通知の対象の投稿は、自分が加わっている会話のものなので、会話のミュートを出す。
    private func statusAction(_ item: StatusMenuItem, on status: Status, isNotification: Bool, id: ItemID) -> UIAction? {
        let shown = status.displayed
        // `url`はMastodonのAPIでnullを取りうるため、ないときは押せないまま並べる。`uri`はActivityPubのIDで、ブラウザで開けるページとは限らないため代わりにしない。
        // ブーストなら元の投稿のページを指す。
        let url = shown.url
        if let action = item.urlAction {
            return action.action(url: url, handlers: urlHandlers(id: id))
        }
        switch item {
        case .reply:
            return UIAction(title: item.title, image: item.image) { [weak self] _ in
                self?.onStatusAction?(.reply, status)
            }
        case .favourite:
            return UIAction(
                title: shown.favourited ? "お気に入りを取り消す" : item.title,
                image: shown.favourited ? UIImage(systemName: "star.slash") : item.image
            ) { [weak self] _ in
                self?.onStatusAction?(.favourite, status)
            }
        case .reblog:
            return UIAction(
                title: shown.reblogged ? "ブーストを取り消す" : item.title,
                image: item.image,
                attributes: canReblog(status) ? [] : .disabled
            ) { [weak self] _ in
                self?.onStatusAction?(.reblog, status)
            }
        case .bookmark:
            return UIAction(
                title: shown.bookmarked ? "ブックマークを外す" : item.title,
                image: shown.bookmarked ? UIImage(systemName: "bookmark.slash") : item.image
            ) { [weak self] _ in
                self?.onStatusAction?(.bookmark, status)
            }
        case .quote:
            return quoteAction(item, on: status)
        case .muteConversation:
            // サーバーはどの会話でもミュートできるが、通知が届かない会話をミュートしても変わらないため、自分が加わっていそうな投稿でだけ出す。
            // 自分が途中で返信した会話で、自分へのメンションを含まない投稿には出ない。そのときは、通知か自分の投稿からミュートする。
            guard let myAccountID,
                  isNotification || shown.account.id == myAccountID || shown.mentions.contains(where: { $0.id == myAccountID })
            else { return nil }
            return UIAction(
                title: shown.muted ? "会話のミュートを解除" : item.title,
                image: shown.muted ? UIImage(systemName: "bell") : item.image
            ) { [weak self] _ in
                self?.onStatusAction?(.muteConversation, status)
            }
        case .pin:
            guard let myAccountID, status.canBePinned(by: myAccountID) else { return nil }
            return UIAction(
                title: shown.pinned ? "プロフィールの固定を外す" : item.title,
                image: shown.pinned ? UIImage(systemName: "pin.slash") : item.image
            ) { [weak self] _ in
                self?.onStatusAction?(.pin, status)
            }
        case .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            // 共通の項目は、上で中身から組んだ。
            return nil
        case .editHistory:
            guard shown.editedAt != nil else { return nil }
            return UIAction(title: item.title, image: item.image) { [weak self] _ in
                self?.onStatusAction?(.editHistory, status)
            }
        case .favouritedBy:
            // サーバーの数は、このサーバーが知っている分で、一覧もこのサーバーが知っている人だけを返すため、数が0なら出さない。
            guard shown.favouritesCount > 0 else { return nil }
            return UIAction(title: item.title, subtitle: "\(shown.favouritesCount.formatted())人", image: item.image) { [weak self] _ in
                self?.onStatusAction?(.openFavouritedBy, status)
            }
        case .rebloggedBy:
            guard shown.reblogsCount > 0 else { return nil }
            return UIAction(title: item.title, subtitle: "\(shown.reblogsCount.formatted())人", image: item.image) { [weak self] _ in
                self?.onStatusAction?(.openRebloggedBy, status)
            }
        case .edit:
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            // 投票の締め切りが近い投稿は、送り直すとサーバーが拒むので、押せないまま理由を添える。
            let canEdit = status.canBeEdited(now: now())
            return UIAction(
                title: item.title,
                subtitle: canEdit ? nil : "締め切りまで5分を切った投票は編集できません",
                image: item.image,
                attributes: canEdit ? [] : .disabled
            ) { [weak self] _ in
                self?.onStatusAction?(.edit, status)
            }
        case .delete:
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            return UIAction(title: item.title, image: item.image, attributes: .destructive) { [weak self] _ in
                self?.onStatusAction?(.delete, status)
            }
        case .hideMedia:
            // ぼかしている投稿では出さない。開くときは、閲覧注意と同じくぼかしをタップする。
            guard !shown.mediaAttachments.isEmpty, mediaCover(for: status) == nil else { return nil }
            let isImageOnly = shown.mediaAttachments.allSatisfy { $0.type == .image }
            return UIAction(title: isImageOnly ? "画像を隠す" : item.title, image: item.image) { [weak self] _ in
                self?.hideMedia(of: shown)
            }
        case .copyText:
            guard let text = Self.plainText(of: shown) else { return nil }
            return UIAction(title: item.title, image: item.image) { [weak self] _ in
                UIPasteboard.general.string = text
                guard let self else { return }
                showNotice(.textCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
            }
        case .systemTranslate:
            guard let text = Self.plainText(of: shown) else { return nil }
            return UIAction(title: item.title, image: item.image) { [weak self] _ in
                self?.translation.present(text)
            }
        case .selectText:
            guard let body = selectableBody(for: id, statusID: shown.id) else { return nil }
            return UIAction(title: item.title, image: item.image) { [weak self, weak body] _ in
                guard let self, let body else { return }
                beginTextSelection(in: body, statusID: shown.id)
            }
        case .openThread, .notifyingUser, .author, .booster, .mentionedUsers, .customEmojis, .hashtags, .dismissNotification, .reblogWithVisibility:
            return nil
        }
    }

    /// 投稿のハッシュタグごとの、ハッシュタグのメニューのサブメニュー。中身は本文のハッシュタグを長押ししたときと同じ。
    /// サーバーと同じ決まりでそろえた名前が同じタグは、1度だけ出す。
    private func hashtagElements(of shown: Status, id: ItemID) -> [UIMenuElement] {
        var seen: Set<String> = []
        let handlers = urlHandlers(id: id)
        return shown.tags.filter { seen.insert(Hashtag.normalizedName($0.name)).inserted }.compactMap { tag in
            let menu = HashtagMenu(
                name: tag.name,
                url: tag.url,
                account: shown.account,
                handlers: handlers,
                muteActions: hashtagMuteActions,
                openTimeline: { [weak self] in self?.onOpenHashtag?(tag.name) },
                openAccountStatuses: { [weak self] account in self?.onOpenAccountHashtag?(tag.name, account) }
            )
            return menu.tree.submenu(groups: settings.hashtagMenuLayout.groups).map { MenuRenderer(perform: menu.perform).element($0) }
        }
    }

    /// 引用の項目。引用に対応していないサーバー（`quote_approval`がない）では出さない。押せるかを決められないため。
    /// 投稿者の承認が要るときと、引用できないときは、そのことをサブタイトルに添える。決まりはdocs/quote.mdの「引用して投稿する」にある。
    private func quoteAction(_ item: StatusMenuItem, on status: Status) -> UIAction? {
        guard let availability = status.displayed.quoteApproval?.availability else { return nil }
        let subtitle: String? = switch availability {
        // ログインしていない人向けに届いた投稿は、押してから確かめる。
        case .automatic, .unverified: nil
        case .manual: "投稿者が承認すると表示されます"
        case .denied(followersOnly: true): "フォロワーだけが引用できます"
        case .denied(followersOnly: false): "引用できない投稿です"
        }
        return UIAction(title: item.title, subtitle: subtitle, image: item.image, attributes: availability.canQuote ? [] : .disabled) { [weak self] _ in
            self?.onStatusAction?(.quote, status)
        }
    }

    /// 公開範囲を選んでブーストするサブメニュー。ブーストを取り消すのは「ブースト」の項目に任せ、ブーストしていない投稿でだけ出す。
    /// フォロワーのみの投稿は、選んでも元の投稿と同じ公開範囲でブーストされるため出さない。
    private func reblogWithVisibilityMenu(for status: Status, item: StatusMenuItem) -> UIMenu? {
        let shown = status.displayed
        guard canReblog(status), !shown.reblogged, shown.visibility == .public || shown.visibility == .unlisted else { return nil }
        let choices: [(ReblogVisibility, Status.Visibility)] = [(.public, .public), (.unlisted, .unlisted), (.private, .private)]
        return UIMenu(title: item.title, image: item.image, children: choices.map { reblogVisibility, visibility in
            let option = VisibilityOption(visibility)
            return UIAction(title: option.title, image: UIImage(systemName: option.symbolName)) { [weak self] _ in
                self?.onStatusAction?(.reblogWithVisibility(reblogVisibility), status)
            }
        })
    }

    /// コピーや翻訳に渡す本文。書式やリンクは落とし、文字だけにする。カスタム絵文字は`:shortcode:`のまま残す。
    /// 本文が空白だけならnil。
    private static func plainText(of status: Status) -> String? {
        let text = RichText.status(status).plainText
        return text.allSatisfy(\.isWhitespace) ? nil : text
    }

    /// カスタム絵文字の画像のメディアのメニューを、絵文字の画像と`:shortcode:`のサブメニューにする。「投稿」はこのメニューの中なので出さない。
    /// 画像は行に描いているアニメーションしない版を、メニューに文字色で塗られないよう元の色のまま置く。まだ届いていなければ、項目のアイコンを置く。
    func emojiElement(for emoji: CustomEmoji, subject: OperationStatus.Subject?) -> UIMenuElement? {
        let attachment = emoji.attachment
        // 使う人が開いたメニューなので、前に読めなかった画像も間隔を待たずに読み直す。
        let image = emojiImages.image(for: emoji.staticUrl, retriesNow: true)
        let animation = settings.animatesCustomEmojis && AnimatedImagePlayback.isAllowed ? emojiImages.animation(for: emoji.url) : nil
        let target = MediaMenuTarget(attachment: attachment, source: nil, preview: image) { [weak self] in
            self?.openMedia([attachment], at: 0, subject: subject) { _ in nil }
        }
        guard let children = mediaMenu(for: target, subject: subject, statusMenu: nil)?.children else { return nil }
        return UIMenu(
            title: ":\(emoji.shortcode):",
            image: animation.flatMap { Self.animatedMenuIcon($0.image) } ?? image.map(Self.menuIcon) ?? StatusMenuItem.customEmojis.image,
            children: children
        )
    }

    /// 絵文字の画像を、メニューのアイコンの大きさの正方形に収め、元の色のまま描く。
    /// メニューは並べるときはアイコンの枠に縮めるが、開いたサブメニューの見出しでは画像を元の大きさのまま置き、メニューの外まではみ出したため。
    /// アイコンの大きさは、本文の文字の大きさの設定に合わせる。
    private static func menuIcon(_ image: UIImage) -> UIImage {
        let side = menuIconSide
        guard image.size.width > 0, image.size.height > 0 else { return image }
        let scale = min(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let canvas = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// メニューのアイコンの一辺。本文の文字の大きさの設定に合わせる。
    private static var menuIconSide: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 22)
    }

    /// 動く絵文字を、メニューのアイコンの大きさの、動く画像にする。
    /// `UIImage.animatedImage`はどのコマも同じ長さで送るため、1周を同じ長さの刻みに分け、刻みごとに、その時刻に出ているコマを置く。
    /// 刻みはいちばん短いコマの長さにし、刻みの数が300を超えるなら、刻みを長くして300に収める。そのときは短いコマが間引かれるが、1周の長さは変わらない。
    static func animatedMenuIcon(_ animation: AnimatedImage) -> UIImage? {
        let total = animation.duration
        guard total > 0 else { return nil }
        let shortest = max(animation.durations.min() ?? 0.1, 0.02)
        let count = min(300, max(1, Int((total / shortest).rounded())))
        let step = total / Double(count)
        let scale = UITraitCollection.current.displayScale
        var icons: [Int: UIImage] = [:]
        var frames: [UIImage] = []
        var frameIndex = 0
        var frameEnd = animation.durations[0]
        for slot in 0..<count {
            let time = (Double(slot) + 0.5) * step
            while time >= frameEnd, frameIndex + 1 < animation.frameCount {
                frameIndex += 1
                frameEnd += animation.durations[frameIndex]
            }
            if icons[frameIndex] == nil {
                guard let cgImage = animation.frameImage(at: frameIndex) else { return nil }
                icons[frameIndex] = menuIcon(UIImage(cgImage: cgImage, scale: scale, orientation: .up))
            }
            if let icon = icons[frameIndex] {
                frames.append(icon)
            }
        }
        return UIImage.animatedImage(with: frames, duration: total)?.withRenderingMode(.alwaysOriginal)
    }

    /// 投稿のメニューに置く、ユーザーのメニューのサブメニュー。
    private func userElement(for user: MenuUser, id: ItemID) -> UIMenuElement? {
        makeUserMenu(for: user, id: id).submenu(groups: settings.userMenuLayout.groups, openProfile: openProfile(of: user)) {
            self.userMenuIcon(for: user, id: id)
        }
    }

    /// リンクカードを長押ししたときに出す、リンクのメニュー。出す項目がなければnil。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func linkMenu(for url: URL, id: ItemID, groups: MenuLayout<LinkMenuItem>.Groups? = nil) -> UIMenu? {
        let menu = LinkMenu(url: url, handlers: urlHandlers(id: id)) { [weak self] in self?.openProfile(resolving: url) }
        return menu.menu(groups: groups ?? settings.linkMenuLayout.groups)
    }

    /// Xの投稿の囲みのような、ほかのサービスの投稿を長押ししたときに出すメニュー。出す項目がなければnil。
    /// - Parameters:
    ///   - text: コピーや翻訳に渡す本文。本文がなければnilで、本文を使う項目を出さない。
    ///   - groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func externalPostMenu(url: URL, text: String?, id: ItemID, groups: MenuLayout<ExternalPostMenuItem>.Groups? = nil) -> UIMenu? {
        let handlers = urlHandlers(id: id)
        let tree = ExternalPostMenuTree(url: url, text: text, linkBrowser: handlers.linkBrowser)
        return tree.menu(groups: groups ?? settings.externalPostMenuLayout.groups).map { root in
            MenuRenderer { [weak self] (command: ExternalPostMenuCommand) in
                switch command {
                case .url(let command): handlers.perform(command)
                case .copyText(let text):
                    UIPasteboard.general.string = text
                    self?.showTextCopiedNotice()
                case .translate(let text): self?.translation.present(text)
                }
            }.menu(root)
        }
    }

    /// 本文をコピーしたことを数秒出す。
    private func showTextCopiedNotice() {
        showNotice(.textCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    /// アイコンや人の一覧の行を長押ししたときに出す、その人のユーザーのメニュー。出す項目がなければnil。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func userMenu(for user: MenuUser, id: ItemID, groups: MenuLayout<UserMenuItem>.Groups? = nil) -> UIMenu? {
        defer { loadPendingMenuIcons() }
        return makeUserMenu(for: user, id: id).menu(groups: groups ?? settings.userMenuLayout.groups, openProfile: openProfile(of: user)) {
            self.userMenuIcon(for: user, id: id)
        }
    }

    /// この一覧の行から出すユーザーのメニュー。共有のシートはその行から出す。
    private func makeUserMenu(for user: MenuUser, id: ItemID) -> UserMenu {
        // Mastodonは通報する相手の投稿しか添えられないため、長押しした投稿をその人が書いたときだけ添える。
        let shown = status(for: id)?.displayed
        return UserMenu(subject: UserMenuSubject(user), actions: userMenuActions, handlers: urlHandlers(id: id), host: self, reportableStatusID: shown?.account.id == user.id ? shown?.id : nil)
    }

    /// ユーザーのメニューの「プロフィール」で開く。メンションされたユーザーはアカウントの全体がないため、IDで開く。
    private func openProfile(of user: MenuUser) -> @MainActor () -> Void {
        { [weak self] in
            switch user {
            case .account(let account): self?.onOpenProfile?(account)
            case .mention(let mention): self?.onOpenProfileID?(mention.id)
            }
        }
    }

    /// ユーザーのメニューのアイコンにする、その人のアイコン。読み込み済みの画像を、一覧と同じ形に切り抜く。
    /// メンションされたユーザーは、APIの`Mention`にアイコンのURLがないため、一覧の行か前に読んだアカウントから探す。
    /// まだアイコンを出せなければ記号のプレースホルダーを返し、アカウントとアイコンを読み終えたら、開いているメニューのプレースホルダーを差し替える。
    /// - Parameter id: メニューを出した行。行に描いた大きさのアイコンも探す。本文のメンションのメニューのように、行が決まらなければnil。
    private func userMenuIcon(for user: MenuUser, id: ItemID?) -> UIImage {
        let account: Account? = switch user {
        case .account(let account): account
        case .mention(let mention): account(withID: mention.id) ?? userMenuActions?.accounts.account(mention.id)
        }
        if let account, let image = cachedAvatar(of: account, id: id), let icon = Self.userMenuIcon(image, shape: settings.avatarShape) {
            return icon
        }
        let placeholder = contextMenuIcons.placeholder(symbolName: "person.crop.circle", side: Self.menuIconSide, traitCollection: traitCollection)
        pendingMenuIcons.append(PendingMenuIcon(user: user, account: account, placeholder: placeholder))
        return placeholder
    }

    /// 本文のメンションのメニューの「プロフィール」のアイコン。一覧の投稿のメンションから誰かを引き、投稿のメニューのユーザーの項目と同じアイコンを出す。
    func mentionMenuIcon(for url: URL) -> UIImage? {
        guard let mention = mention(withURL: url) else { return nil }
        defer { loadPendingMenuIcons() }
        return userMenuIcon(for: .mention(mention), id: nil)
    }

    /// 行に描いた大きさか、メニューのアイコンの大きさで読み込み済みのアイコン。
    private func cachedAvatar(of account: Account, id: ItemID?) -> UIImage? {
        let urls = Set([account.avatar, account.avatarStatic].compactMap(\.self))
        let rowKeys = id.flatMap(entry(for:)).map { avatarKeys(for: [$0]) } ?? []
        let rowImage = rowKeys.filter { urls.contains($0.url) }.lazy.compactMap { self.avatarImages.cachedImage(for: $0) }.first
        return rowImage ?? userMenuIconKey(of: account).flatMap { avatarImages.cachedImage(for: $0) }
    }

    /// メニューのアイコンの大きさで読む、止まったアイコン。
    private func userMenuIconKey(of account: Account) -> AvatarImageKey? {
        account.avatarStatic.map { AvatarView.key(url: $0, animates: false, side: Self.menuIconSide, scale: traitCollection.displayScale) }
    }

    /// メニューを組みながら集めた人のアイコンを読み、開いているメニューのプレースホルダーのアイコンを差し替える。
    /// アカウントが分からないメンションされた人は、相手ごとに送らず、まとめて1回で読む。
    /// 読み終える前にメニューを閉じていたら、差し替えるものがないので何もしない。次に開いたときは読み込み済みのアイコンを出す。
    private func loadPendingMenuIcons() {
        let pending = pendingMenuIcons
        pendingMenuIcons = []
        guard !pending.isEmpty else { return }
        Task { [weak self, clock] in
            #if DEBUG
            if let delay = DebugFaults.slowMenuIconDelay {
                try? await clock.sleep(for: delay)
            }
            #endif
            guard let self else { return }
            // アカウントの分かっている人は、まとめ読みを待たずに画像を読み始める。
            for icon in pending {
                if let account = icon.account {
                    loadMenuIcon(of: account, replacing: icon.placeholder)
                }
            }
            let unresolved = pending.filter { $0.account == nil }
            guard !unresolved.isEmpty, let accounts = userMenuActions?.accounts else { return }
            let loaded = await accounts.load(unresolved.map(\.user.id))
            for icon in unresolved {
                if let account = loaded[icon.user.id] {
                    loadMenuIcon(of: account, replacing: icon.placeholder)
                }
            }
        }
    }

    /// `account`のアイコンを読み、開いているメニューの`placeholder`を差し替える。
    private func loadMenuIcon(of account: Account, replacing placeholder: UIImage) {
        guard let key = userMenuIconKey(of: account) else { return }
        Task { [weak self] in
            // 使う人が開いたメニューなので、前に読めなかったアイコンも間隔を待たずに読み直す。
            guard let self, let image = try? await avatarImages.image(for: key, retriesNow: true),
                  let icon = Self.userMenuIcon(image, shape: settings.avatarShape) else { return }
            contextMenuIcons.setIcon(icon, for: placeholder)
        }
    }

    /// アイコンを、メニューのアイコンの大きさで一覧と同じ形に切り抜き、元の色のまま描く。動くアイコンは先頭のコマで止める。
    private static func userMenuIcon(_ avatar: UIImage, shape: AvatarShape) -> UIImage? {
        let image = avatar.images?.first ?? avatar
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let side = menuIconSide
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let clip = switch shape {
        case .roundedSquare: UIBezierPath(roundedRect: bounds, cornerRadius: side * 0.2)
        case .circle: UIBezierPath(ovalIn: bounds)
        }
        let scale = max(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            clip.addClip()
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// プロフィール画面のナビゲーションバーに出す、そのユーザーのユーザーのメニュー。出す項目がなければnil。
    /// - Parameter barButtonItem: 共有のシートを出す起点。
    func profileUserMenu(for account: Account, from barButtonItem: UIBarButtonItem) -> UIMenu? {
        let handlers = URLMenuHandlers(
            linkBrowser: settings.linkBrowser,
            copy: { [weak self] url in URLSharing.copy(url, notifying: self) },
            share: { [weak self, weak barButtonItem] url in
                guard let self else { return }
                URLSharing.presentShareSheet(for: url, from: self) { $0.sourceItem = barButtonItem }
            },
            open: { [weak self] url, browser in self?.openURL(url, in: browser) }
        )
        let menu = UserMenu(subject: UserMenuSubject(.account(account)), actions: userMenuActions, handlers: handlers, host: self)
        return menu.profileScreenMenu(groups: settings.userMenuLayout.groups)
    }

    /// 共有のシートは、メニューを出した行から出す。
    private func urlHandlers(id: ItemID) -> URLMenuHandlers {
        URLMenuHandlers(
            linkBrowser: settings.linkBrowser,
            copy: { [weak self] url in URLSharing.copy(url, notifying: self) },
            share: { [weak self] url in self?.presentShareSheet(for: url, from: id) },
            open: { [weak self] url, browser in self?.openURL(url, in: browser) }
        )
    }

    /// メニューを出した行を起点にする。行が画面の外へ流れていれば一覧を起点にする。
    private func presentShareSheet(for url: URL, from id: ItemID) {
        let source = cell(for: id) ?? collectionView
        URLSharing.presentShareSheet(for: url, from: self) { $0.sourceItem = source }
    }

    private func canReblog(_ status: Status) -> Bool {
        guard let myAccountID else { return false }
        return status.canBeReblogged(by: myAccountID)
    }
}
