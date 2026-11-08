import SciaCore
import UIKit

/// メニューにプレースホルダーのアイコンを出し、アイコンを読んでから差し替える人。
struct PendingMenuIcon {
    /// アイコンのURLを持つアカウントを、どう知るか。
    enum Source {
        /// 分かっているアカウント。
        case account(Account)
        /// タイムラインにも読み込み済みのものにもいない、メンションされた人のID。まとめて読む。
        case mention(id: String)
        /// 「別のアカウントで」のアカウント自身。プロフィールを読み終えるのを待つ。
        case otherAccount(OtherAccount)
    }

    let source: Source
    let placeholder: UIImage
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
        case .gap, .unreadable, .account, .notificationRequest, .search: nil
        }
    }

    /// メニュー。出す項目がなければnil。
    /// - Parameter id: メニューを出した要素。共有のシートを、その行から出す。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func contextMenu(for entry: TimelineEntry, id: ItemID, groups: MenuLayout<StatusMenuItem>.Groups? = nil) -> UIMenu? {
        // 検索の結果と「フォロー中のハッシュタグ」のハッシュタグの行では、本文のハッシュタグを長押ししたときと同じハッシュタグのメニューを出す。
        if case .search(.hashtag(let hashtag)) = entry {
            return hashtagRowMenu(for: hashtag, id: id)
        }
        return statusMenu(for: entry, id: id, groups: groups)?.menu
    }

    /// ハッシュタグの行のハッシュタグのメニュー。「すべての投稿」は、行を押したときと同じく、そのハッシュタグのタイムラインを開く。投稿がないので「投稿したユーザーの投稿」は出さない。
    private func hashtagRowMenu(for hashtag: Hashtag, id: ItemID) -> UIMenu? {
        HashtagMenu(
            name: hashtag.name,
            url: hashtag.url,
            account: nil,
            handlers: urlHandlers(id: id),
            actions: hashtagMenuActions,
            openTimeline: { [weak self] in self?.onSearchRowSelect?(.hashtag(hashtag)) },
            openAccountStatuses: { _ in }
        ).built(groups: settings.hashtagMenuLayout.groups)?.menu
    }

    /// メニューの木と描き方。並びは設定の投稿のメニューに従い、関係するユーザーはユーザーのメニューのサブメニューにする。決まりはdocs/menus.mdにある。
    /// 項目の出し分けはSciaCoreの`StatusMenuTree`が決め、ここでは画面の状態（スレッドを開けるか、ぼかしているか、本文を選べるか）を渡し、押された操作を行う。
    /// 出す項目がなければnil。
    /// - Parameter id: メニューを出した要素。共有のシートを、その行から出す。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときと、ほかの対象のメニューの中のサブメニューで組むときに渡す。渡したときは、フォローリクエストの承認と却下を置かない。
    func statusMenu(for entry: TimelineEntry, id: ItemID, groups: MenuLayout<StatusMenuItem>.Groups? = nil) -> BuiltMenu<StatusMenuCommand>? {
        let status = Self.status(of: entry)
        let notification: MastodonNotification? = if case .notification(let notification) = entry { notification } else { nil }
        let subject = status.map { OperationStatus.Subject($0.displayed) }
        let emojis = CustomEmojiMenus(timeline: self, subject: subject)
        let body = status.flatMap { selectableBody(for: id, statusID: $0.displayed.id) }
        let request: NotificationRequest? = if case .notificationRequest(let request) = entry { request } else { nil }
        let renderer = statusMenuRenderer(status: status, notification: notification, request: request, id: id, selectableBody: body, emojis: emojis)
        // 人のリストの行では、その人へのユーザーのメニューを、単独で出す形で出す。投稿のメニューに入れるサブメニューの形のままだと、項目がそのサブメニュー1つだけのメニューになるため。
        if case .account(let account) = entry {
            let userGroups = settings.userMenuLayout.groups
            let user = MenuUser.account(account)
            var tree = UserMenuTree(subject: UserMenuSubject(user), actions: userMenuActions, linkBrowser: settings.linkBrowser)
            tree.otherAccountGroups = userMenuSubmenuGroups
            defer {
                reloadRelations([account.id], groups: userGroups)
                tree.refreshOtherAccounts(groups: userGroups)
            }
            guard let root = tree.menu(groups: userGroups, avatar: .user(user)) else { return nil }
            return BuiltMenu(root: root.map { .user(user, $0) }, renderer: renderer) { [weak self] in self?.loadPendingMenuIcons() }
        }
        // 保留中の通知の行では、受け入れると無視の下に、その人へのユーザーのメニューをサブメニューで出す。
        if let request {
            let userGroups = userMenuSubmenuGroups
            let user = MenuUser.account(request.account)
            let tree = UserMenuTree(subject: UserMenuSubject(user), actions: userMenuActions, linkBrowser: settings.linkBrowser)
            defer {
                reloadRelations([request.account.id], groups: userGroups)
                tree.refreshOtherAccounts(groups: userGroups)
            }
            let node = tree.submenu(groups: userGroups, avatar: .user(user))
            return BuiltMenu(root: StatusMenuTree.notificationRequestMenu(user: node?.map { .user(user, $0) }), renderer: renderer) { [weak self] in self?.loadPendingMenuIcons() }
        }
        var tree = statusMenuTree(status: status, notification: notification, id: id, canSelectText: body != nil)
        tree.customEmoji = { emojis.node(for: $0) }
        // メニューを開くので、ハッシュタグの状態と、ほかのアカウントのアイコンを、次に開くときのために読み直す。
        tree.hashtagActions = hashtagMenuActions
        tree.otherAccounts = otherAccounts?.list() ?? []
        let built = tree.menu(groups: groups ?? defaultStatusMenuGroups(for: id, status: status), includesFollowRequest: groups == nil)
        reloadRelations(built.shownUserIDs, groups: tree.userMenu)
        built.refreshOtherAccountUsers()
        // 前に別のアカウントで見つけた投稿は、組んだメニューでは覚えていた状態で出し、探し直した状態は次に開いたときから使う。
        if built.showsOtherAccounts, let status {
            otherAccounts?.refresh(status, people: built.otherAccountPeople, relationIDs: built.otherAccountRelationIDs)
        }
        // 描きながら集めた、アイコンのまだない人をまとめて読む。
        return built.root.map { BuiltMenu(root: $0, renderer: renderer) { [weak self] in self?.loadPendingMenuIcons() } }
    }

    /// 設定の並びで組む投稿のメニューの並び。アクションバーを出している投稿のメニューでは、設定に従って、アクションバーに並べた項目とボタンの長押しで出す項目を、押せないものも含めて除く（docs/post-action-bar.mdの「ボタン」）。並びを渡して組むメニュー（ほかのメニューの中のサブメニュー、割り当てた1項目）は、ここを通らないので除かない。
    /// 引用の囲みのメニューは、囲みのある投稿の`id`で引用元の投稿について組むので、メニューの投稿がその投稿そのものでなければ除かない。アクションバーは引用元への操作ではないため。
    private func defaultStatusMenuGroups(for id: ItemID, status: Status?) -> MenuLayout<StatusMenuItem>.Groups {
        let groups = settings.statusMenuLayout.groups
        guard let status, self.status(for: id)?.id == status.id, showsActionBar(itemID: id, shown: status.displayed) else { return groups }
        let removed = settings.postActionBarLayout.itemsRemovedFromMenu(
            barItems: !settings.showsActionBarItemsInMenu,
            longPressItems: !settings.showsActionBarLongPressItemsInMenu
        )
        return groups.excluding(removed)
    }

    /// 投稿のメニューの木。項目の出し分けに要る画面の状態を渡す。カスタム絵文字のメディアのメニューは、組む側が足す。
    /// 組むだけでは通信しない。メニューに出る人の関係を読み直すのは、メニューを出す側が行う。
    func statusMenuTree(status: Status?, notification: MastodonNotification?, id: ItemID, canSelectText: Bool) -> StatusMenuTree {
        var tree = StatusMenuTree(status: status, notification: notification, now: now(), linkBrowser: settings.linkBrowser)
        tree.rowStatus = self.status(for: id)
        tree.myAccountID = myAccountID
        tree.canOpenThread = status.map(canOpenThread(of:)) ?? false
        tree.mediaIsCovered = status.map { mediaCover(for: $0) != nil } ?? false
        tree.canSelectText = canSelectText
        if notification == nil, let shown = status?.displayed, translations?.hasTranslation(of: shown) == true {
            tree.translationDisplay = translations?.isShowingOriginal(shown) == true ? .original : .translation
        }
        tree.canSelectPosts = canSelectPost(id)
        tree.supportsEmojiReactions = supportsEmojiReactions
        tree.userMenu = userMenuSubmenuGroups
        tree.userActions = userMenuActions
        tree.hashtagMenu = settings.hashtagMenuLayout.submenuGroups(actions: settings.hashtagActions)
        tree.hashtagActions = hashtagMenuActions?.withoutRefresh
        tree.otherAccounts = otherAccounts?.list(loadsProfiles: false) ?? []
        tree.otherAccountGroups = settings.statusMenuLayout.submenuGroups(actions: settings.statusActions)
        return tree
    }

    /// ユーザーのメニューの、ほかのメニューの中に出すときの並び。ユーザーのメニューの「別のアカウントで」の中身も、この並びで組む。
    var userMenuSubmenuGroups: MenuLayout<UserMenuItem>.Groups {
        settings.userMenuLayout.submenuGroups(actions: settings.userActions)
    }

    /// メニューに出る人の関係を、まとめて1回で読み直す。組んだメニューは覚えていた関係のまま出し、読み直した関係は次に開いたときから使う。
    /// 覚えていなかった人の関係の項目は、この読み直しを待って中身を渡す。関係で中身が変わる項目を出していなければ読まない。
    /// - Parameter groups: ユーザーのメニューを組んだ並び。サブメニューでは隠した関係の項目も出るので、組んだ並びで決める。
    private func reloadRelations(_ ids: [String], groups: MenuLayout<UserMenuItem>.Groups) {
        guard !ids.isEmpty, groups.needsRelationship else { return }
        userMenuActions?.reloadRelations(ids)
    }

    /// 投稿のメニューの描き方と、押された操作の行い方。
    /// - Parameter selectableBody: 「テキストを選択」で選ぶ本文。メニューを組んだときの行のものを使う。
    private func statusMenuRenderer(status: Status?, notification: MastodonNotification?, request: NotificationRequest?, id: ItemID, selectableBody: PostBodyView?, emojis: CustomEmojiMenus) -> MenuRenderer<StatusMenuCommand> {
        MenuRenderer { [weak self, weak selectableBody] command in
            switch command {
            case .status(let action):
                guard let status else { return }
                self?.onStatusAction?(action, status)
            case .openThread:
                guard let self, let status else { return }
                recordOpenThread()
                onOpenThread?(status, rowFrame(of: id))
            case .dismissNotification:
                guard let notification else { return }
                self?.onDismissNotification?(notification)
            case .hideMedia:
                guard let status else { return }
                self?.hideMedia(of: status.displayed)
            case .copyText(let text):
                UIPasteboard.general.string = text
                self?.showTextCopiedNotice()
            case .translate(let text):
                self?.translation.present(text)
            case .toggleTranslation:
                guard let status else { return }
                self?.translations?.toggleOriginal(of: status.displayed)
            case .selectText:
                guard let self, let selectableBody, let status else { return }
                beginTextSelection(in: selectableBody, statusID: status.displayed.id)
            case .select:
                self?.beginPostSelection(with: id)
            case .url(let command):
                self?.urlHandlers(id: id).perform(command)
            case .followRequest(let decision):
                guard let notification else { return }
                self?.onFollowRequestDecision?(decision, notification)
            case .notificationRequest(let decision):
                guard let request else { return }
                self?.onNotificationRequestDecision?(decision, request)
            case .user(let user, let command):
                guard let self else { return }
                makeUserMenu(for: user, id: id).perform(command, openProfile: openProfile(of: user))
            case .hashtag(let tag, let command):
                guard let status else { return }
                self?.hashtagMenu(for: tag, of: status.displayed, id: id).perform(command)
            case .customEmoji(let emoji, let command):
                emojis.perform(command, on: emoji)
            case .otherAccount(let command):
                self?.onOtherAccountAction?(command)
            case .logIn(let account):
                FailureRecovery.logIn(account, from: self?.view)
            case .customize:
                self?.openMenuSettings(.statusMenu)
            }
        } customIcon: { [weak self] icon in
            switch icon {
            case .avatar(.user(let user), _): self?.userMenuIcon(for: user, id: id)
            case .avatar(.otherAccount(let account), _): self?.otherAccountMenuIcon(for: account)
            case .customEmoji(let emoji, _): emojis.icon(for: emoji)
            case .avatar(.mentionLink, _), .symbol: nil
            }
        }
    }

    /// 投稿のメニューの「ハッシュタグ」の、タグごとのハッシュタグのメニュー。中身は本文のハッシュタグを長押ししたときと同じ。
    private func hashtagMenu(for tag: Tag, of shown: Status, id: ItemID) -> HashtagMenu {
        HashtagMenu(
            name: tag.name,
            url: tag.url,
            account: shown.account,
            handlers: urlHandlers(id: id),
            actions: hashtagMenuActions,
            openTimeline: { [weak self] in self?.onOpenHashtag?(tag.name) },
            openAccountStatuses: { [weak self] account in self?.onOpenAccountHashtag?(tag.name, account) }
        )
    }

    /// 本文をコピーしたことを数秒出す。
    func showTextCopiedNotice() {
        showNotice(.textCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    /// カスタム絵文字の画像のメディアのメニューを、絵文字の画像と`:shortcode:`のサブメニューにする。「投稿」はこのメニューの中なので出さない。
    /// プロフィールの文章のメニューに置く。
    func emojiElement(for emoji: CustomEmoji, subject: OperationStatus.Subject?) -> UIMenuElement? {
        let emojis = CustomEmojiMenus(timeline: self, subject: subject)
        return emojis.node(for: emoji).map { node in
            MenuRenderer { command in
                emojis.perform(command, on: emoji)
            } customIcon: { icon in
                guard case .customEmoji(let emoji, _) = icon else { return nil }
                return emojis.icon(for: emoji)
            }.element(node)
        }
    }

    /// 絵文字の画像を、メニューのアイコンの大きさの正方形に収め、元の色のまま描く。
    /// メニューは並べるときはアイコンの枠に縮めるが、開いたサブメニューの見出しでは画像を元の大きさのまま置き、メニューの外まではみ出したため。
    /// アイコンの大きさは、本文の文字の大きさの設定に合わせる。
    static func menuIcon(_ image: UIImage) -> UIImage {
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

    private static var menuIconSide: CGFloat {
        AvatarIcon.menuSide
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

    /// リンクカードを長押ししたときに出す、リンクのメニュー。出す項目がなければnil。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func linkMenu(for url: URL, id: ItemID, groups: MenuLayout<LinkMenuItem>.Groups? = nil) -> UIMenu? {
        builtLinkMenu(for: url, id: id, groups: groups)?.menu
    }

    func builtLinkMenu(for url: URL, id: ItemID, groups: MenuLayout<LinkMenuItem>.Groups? = nil) -> BuiltMenu<LinkMenuCommand>? {
        let menu = LinkMenu(url: url, handlers: urlHandlers(id: id)) { [weak self] in self?.openProfile(resolving: url) }
        return menu.built(groups: groups ?? settings.linkMenuLayout.groups)
    }

    /// Xの投稿の囲みのような、ほかのサービスの投稿を長押ししたときに出すメニュー。出す項目がなければnil。
    /// - Parameters:
    ///   - text: コピーや翻訳に渡す本文。本文がなければnilで、本文を使う項目を出さない。
    ///   - groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func externalPostMenu(url: URL, text: String?, id: ItemID, groups: MenuLayout<ExternalPostMenuItem>.Groups? = nil) -> UIMenu? {
        builtExternalPostMenu(url: url, text: text, id: id, groups: groups)?.menu
    }

    func builtExternalPostMenu(url: URL, text: String?, id: ItemID, groups: MenuLayout<ExternalPostMenuItem>.Groups? = nil) -> BuiltMenu<ExternalPostMenuCommand>? {
        let handlers = urlHandlers(id: id)
        let tree = ExternalPostMenuTree(url: url, text: text, linkBrowser: handlers.linkBrowser)
        return tree.menu(groups: groups ?? settings.externalPostMenuLayout.groups).map { root in
            BuiltMenu(root: root, renderer: MenuRenderer { [weak self] command in
                switch command {
                case .url(let command): handlers.perform(command)
                case .copyText(let text):
                    UIPasteboard.general.string = text
                    self?.showTextCopiedNotice()
                case .translate(let text): self?.translation.present(text)
                case .customize: self?.openMenuSettings(.externalPostMenu)
                }
            })
        }
    }

    /// アイコンや人のリストの行を長押ししたときに出す、その人のユーザーのメニュー。出す項目がなければnil。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func userMenu(for user: MenuUser, id: ItemID, groups: MenuLayout<UserMenuItem>.Groups? = nil) -> UIMenu? {
        builtUserMenu(for: user, id: id, groups: groups)?.menu
    }

    func builtUserMenu(for user: MenuUser, id: ItemID, groups: MenuLayout<UserMenuItem>.Groups? = nil) -> BuiltMenu<UserMenuCommand>? {
        let built = makeUserMenu(for: user, id: id).built(groups: groups ?? settings.userMenuLayout.groups, openProfile: openProfile(of: user), avatar: .user(user)) { [weak self] avatar in
            self?.userMenuIcon(for: avatar, user: user, id: id)
        }
        // 描きながら集めた、アイコンのまだない人を読む。
        return built.map { built in
            BuiltMenu(root: built.root, renderer: built.renderer) { [weak self] in self?.loadPendingMenuIcons() }
        }
    }

    /// このタイムラインの行から出すユーザーのメニュー。共有のシートはその行から出す。
    func makeUserMenu(for user: MenuUser, id: ItemID) -> UserMenu {
        // Mastodonは通報する相手の投稿しか添えられないため、長押しした投稿をその人が書いたときだけ添える。
        let shown = status(for: id)?.displayed
        var menu = UserMenu(subject: UserMenuSubject(user), actions: userMenuActions, handlers: urlHandlers(id: id), host: self, reportableStatusID: shown?.account.id == user.id ? shown?.id : nil)
        menu.otherAccountGroups = userMenuSubmenuGroups
        return menu
    }

    /// 単独で出すユーザーのメニューのアイコン。「プロフィール」には`user`のアイコンを、「別のアカウントで」のアカウントの行にはそのアカウントのアイコンを出す。
    private func userMenuIcon(for avatar: MenuAvatar, user: MenuUser, id: ItemID?) -> UIImage? {
        if case .otherAccount(let account) = avatar {
            return otherAccountMenuIcon(for: account)
        }
        return userMenuIcon(for: user, id: id)
    }

    /// ユーザーのメニューの「プロフィール」で開く。メンションされたユーザーはアカウントの全体がないため、IDで開く。
    func openProfile(of user: MenuUser) -> @MainActor () -> Void {
        { [weak self] in
            switch user {
            case .account(let account): self?.onOpenProfile?(account)
            case .mention(let mention): self?.onOpenProfileID?(mention.id)
            }
        }
    }

    /// ユーザーのメニューのアイコンにする、その人のアイコン。読み込み済みの画像を、タイムラインと同じ形に切り抜く。
    /// メンションされたユーザーは、APIの`Mention`にアイコンのURLがないため、タイムラインの行か前に読んだアカウントから探す。
    /// まだアイコンを出せなければ記号のプレースホルダーを返し、アカウントとアイコンを読み終えたら、開いているメニューのプレースホルダーを差し替える。
    /// - Parameter id: メニューを出した行。行に描いた大きさのアイコンも探す。本文のメンションのメニューのように、行が決まらなければnil。
    func userMenuIcon(for user: MenuUser, id: ItemID?) -> UIImage {
        let account: Account? = switch user {
        case .account(let account): account
        case .mention(let mention): account(withID: mention.id) ?? userMenuActions?.accounts.account(mention.id)
        }
        if let account, let image = cachedAvatar(of: account, id: id), let icon = Self.userMenuIcon(image, shape: settings.appearance.avatarShape) {
            return icon
        }
        return pendingMenuIcon(account.map { .account($0) } ?? .mention(id: user.id))
    }

    /// 「別のアカウントで」のアカウントの行のアイコン。プロフィールをまだ読めていなければ、読み終えてから差し替える。
    func otherAccountMenuIcon(for account: OtherAccount) -> UIImage {
        guard let profile = account.profile else { return pendingMenuIcon(.otherAccount(account)) }
        return userMenuIcon(for: .account(profile), id: nil)
    }

    func menuIcon(ofOtherAccount account: OtherAccount) -> UIImage? {
        defer { loadPendingMenuIcons() }
        return otherAccountMenuIcon(for: account)
    }

    /// 記号のプレースホルダーを返し、`loadPendingMenuIcons()`で読んで差し替えるよう積む。
    private func pendingMenuIcon(_ source: PendingMenuIcon.Source) -> UIImage {
        let placeholder = contextMenuIcons.placeholder(symbolName: "person.crop.circle", side: Self.menuIconSide, traitCollection: traitCollection)
        pendingMenuIcons.append(PendingMenuIcon(source: source, placeholder: placeholder))
        return placeholder
    }

    /// 本文のメンションのメニューの「プロフィール」のアイコン。タイムラインの投稿のメンションから誰かを引き、投稿のメニューのユーザーの項目と同じアイコンを出す。
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
    func loadPendingMenuIcons() {
        let pending = pendingMenuIcons
        pendingMenuIcons = []
        guard !pending.isEmpty else { return }
        Task(.action) { [weak self, clock] in
            #if DEBUG
            if let delay = DebugFaults.slowMenuIconDelay {
                try? await clock.sleep(for: delay)
            }
            #endif
            guard let self else { return }
            var mentions: [(id: String, placeholder: UIImage)] = []
            for icon in pending {
                switch icon.source {
                case .account(let account):
                    // アカウントの分かっている人は、まとめ読みを待たずに画像を読み始める。
                    loadMenuIcon(of: account, replacing: icon.placeholder)
                case .mention(let id):
                    mentions.append((id, icon.placeholder))
                case .otherAccount(let account):
                    Task(.action) { [weak self] in
                        guard let profile = await account.loadedProfile() else { return }
                        self?.loadMenuIcon(of: profile, replacing: icon.placeholder)
                    }
                }
            }
            guard !mentions.isEmpty, let accounts = userMenuActions?.accounts else { return }
            let loaded = await accounts.load(mentions.map(\.id))
            for mention in mentions {
                if let account = loaded[mention.id] {
                    loadMenuIcon(of: account, replacing: mention.placeholder)
                }
            }
        }
    }

    /// `account`のアイコンを読み、開いているメニューの`placeholder`を差し替える。
    private func loadMenuIcon(of account: Account, replacing placeholder: UIImage) {
        guard let key = userMenuIconKey(of: account) else { return }
        Task(.action) { [weak self] in
            // 使う人が開いたメニューなので、前に読めなかったアイコンも間隔を待たずに読み直す。
            guard let self, let image = try? await avatarImages.image(for: key, retriesNow: true),
                  let icon = Self.userMenuIcon(image, shape: settings.appearance.avatarShape) else { return }
            contextMenuIcons.setIcon(icon, for: placeholder)
        }
    }

    /// アイコンを、メニューのアイコンの大きさでタイムラインと同じ形に切り抜き、元の色のまま描く。動くアイコンは先頭のコマで止める。
    private static func userMenuIcon(_ avatar: UIImage, shape: AvatarShape) -> UIImage? {
        AvatarIcon.image(avatar, side: menuIconSide, shape: shape)
    }

    /// プロフィール画面のナビゲーションバーに出す、そのユーザーのユーザーのメニュー。出す項目がなければnil。
    /// - Parameter barButtonItem: 共有のシートを出す起点。
    func profileUserMenu(for account: Account, from barButtonItem: UIBarButtonItem) -> UIMenu? {
        var menu = UserMenu(subject: UserMenuSubject(.account(account)), actions: userMenuActions, handlers: profileURLHandlers(shareFrom: barButtonItem), host: self)
        menu.otherAccountGroups = userMenuSubmenuGroups
        // ナビゲーションバーのボタンのメニューは、開いている間にアイコンを差し替える仕組み（`ContextMenuIconSwapper`）が働かない。
        // 「別のアカウントで」のアカウントのプロフィールをまだ読めていなければ記号を出し、読んだアイコンは次に開いたときに出す。
        defer { loadPendingMenuIcons() }
        return menu.profileScreenMenu(groups: settings.userMenuLayout.groups) { [weak self] avatar in
            guard case .otherAccount(let account) = avatar, let profile = account.profile else { return nil }
            return self?.userMenuIcon(for: .account(profile), id: nil)
        } didRenderDeferred: { [weak self] in
            // 「別のアカウントで」のアカウントの行は、相手を探してからあとで描くので、そのときに集めたアイコンも読む。
            self?.loadPendingMenuIcons()
        }
    }

    /// プロフィールのハンドルを押したときの、コピーのメニュー。決まりはdocs/profile.mdの「ハンドル」にある。
    func profileHandleMenu(for account: Account) -> UIMenu? {
        // コピーの項目だけを出すので、共有のシートは出さない。
        let menu = UserMenu(subject: UserMenuSubject(.account(account)), actions: userMenuActions, handlers: profileURLHandlers(shareFrom: nil), host: self)
        return menu.handleMenu()
    }

    /// プロフィールの注目のハッシュタグを長押ししたときの、ハッシュタグのメニュー。「投稿したユーザーの投稿」は、そのプロフィールの人で開く。
    /// URLの項目は、その人のそのタグの付いた投稿のページを開く。タップで開くものと同じページになるため。出す項目がなければnil。
    func profileFeaturedTagMenu(for tag: FeaturedTag, of account: Account, from view: UIView) -> UIMenu? {
        HashtagMenu(
            name: tag.name,
            url: tag.url,
            account: account,
            handlers: profileURLHandlers(shareFrom: view),
            actions: hashtagMenuActions,
            openTimeline: { [weak self] in self?.onOpenHashtag?(tag.name) },
            openAccountStatuses: { [weak self] account in self?.onOpenAccountHashtag?(tag.name, account) }
        ).built(groups: settings.hashtagMenuLayout.groups)?.menu
    }

    /// プロフィールの紹介しているユーザーのカードを長押ししたときの、その人のユーザーのメニュー。出す項目がなければnil。
    func profileEndorsedUserMenu(for account: Account, from view: UIView) -> UIMenu? {
        let user = MenuUser.account(account)
        var menu = UserMenu(subject: UserMenuSubject(user), actions: userMenuActions, handlers: profileURLHandlers(shareFrom: view), host: self)
        menu.otherAccountGroups = userMenuSubmenuGroups
        let built = menu.built(groups: settings.userMenuLayout.groups, openProfile: openProfile(of: user), avatar: .user(user)) { [weak self] avatar in
            self?.userMenuIcon(for: avatar, user: user, id: nil)
        }
        defer { loadPendingMenuIcons() }
        return built?.menu
    }

    /// プロフィール画面のユーザーのメニューの、URLの項目の動き。共有のシートは`barButtonItem`から出す。
    private func profileURLHandlers(shareFrom barButtonItem: UIBarButtonItem?) -> URLMenuHandlers {
        profileURLHandlers { [weak barButtonItem] in $0.sourceItem = barButtonItem }
    }

    /// ハッシュタグのタイムラインの右上に置く、ハッシュタグのメニューを出すボタン。決まりはdocs/tabs.mdの「フォローしているハッシュタグ」にある。
    /// そのタイムラインを開いている画面なので「すべての投稿」を出さず、投稿がないので「投稿したユーザーの投稿」も出さない。並びは開くたびに設定から読む。
    func makeHashtagMenuItem(name: String, url: URL) -> UIBarButtonItem {
        // 右上に入り切らず「さらに表示」にまとめられたときも、何のボタンか分かるよう名前を付ける。
        let item = UIBarButtonItem(title: "ハッシュタグ", image: UIImage(systemName: "ellipsis"))
        item.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak item] completion in
            guard let self, let item else { return completion([]) }
            let menu = HashtagMenu(
                name: name,
                url: url,
                account: nil,
                handlers: profileURLHandlers { [weak item] in $0.sourceItem = item },
                actions: hashtagMenuActions,
                openTimeline: {},
                openAccountStatuses: { _ in }
            )
            completion(menu.built(groups: settings.hashtagMenuLayout.groups.excluding([.timeline]))?.barMenu.children ?? [])
        }])
        return item
    }

    /// プロフィールのヘッダーの部品から出すメニューの、URLの項目の動き。共有のシートは押した部品から出す。
    private func profileURLHandlers(shareFrom view: UIView) -> URLMenuHandlers {
        profileURLHandlers { [weak view] in $0.sourceView = view }
    }

    /// - Parameter anchor: 共有のシートを出す起点を決める。
    private func profileURLHandlers(anchor: @escaping (UIPopoverPresentationController) -> Void) -> URLMenuHandlers {
        URLMenuHandlers(
            linkBrowser: settings.linkBrowser,
            copy: { [weak self] url in URLSharing.copy(url, notifying: self) },
            share: { [weak self] url in
                guard let self else { return }
                URLSharing.presentShareSheet(for: url, from: self, anchor: anchor)
            },
            open: { [weak self] url, browser in self?.openURL(url, in: browser) },
            openSettings: { [weak self] page in self?.openMenuSettings(page) }
        )
    }

    /// 共有のシートは、メニューを出した行から出す。
    func urlHandlers(id: ItemID) -> URLMenuHandlers {
        URLMenuHandlers(
            linkBrowser: settings.linkBrowser,
            copy: { [weak self] url in URLSharing.copy(url, notifying: self) },
            share: { [weak self] url in self?.presentShareSheet(for: url, from: id) },
            open: { [weak self] url, browser in self?.openURL(url, in: browser) },
            openSettings: { [weak self] page in self?.openMenuSettings(page) }
        )
    }

    /// メニューを出した行を起点にする。行が画面の外へ流れていればタイムラインを起点にする。
    private func presentShareSheet(for url: URL, from id: ItemID) {
        let source = cell(for: id) ?? collectionView
        URLSharing.presentShareSheet(for: url, from: self) { $0.sourceItem = source }
    }

}
