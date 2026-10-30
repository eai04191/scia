import SciaCore
import UIKit

/// メニューにプレースホルダーのアイコンを出し、アイコンを読んでから差し替える人。
struct PendingMenuIcon {
    let user: MenuUser
    /// 分かっているアカウント。メンションされた人で、一覧にも読み込み済みのものにもいなければnil。
    let account: Account?
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
        case .gap, .unreadable, .account: nil
        }
    }

    /// 長押しのメニュー。出す項目がなければnil。
    /// - Parameter id: メニューを出した要素。共有のシートを、その行から出す。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func contextMenu(for entry: TimelineEntry, id: ItemID, groups: MenuLayout<StatusMenuItem>.Groups? = nil) -> UIMenu? {
        statusMenu(for: entry, id: id, groups: groups)?.menu
    }

    /// 長押しのメニューの木と描き方。並びは設定の投稿のメニューに従い、関係するユーザーはユーザーのメニューのサブメニューにする。決まりはdocs/menus.mdにある。
    /// 項目の出し分けはSciaCoreの`StatusMenuTree`が決め、ここでは画面の状態（スレッドを開けるか、ぼかしているか、本文を選べるか）を渡し、押された操作を行う。
    /// 出す項目がなければnil。
    /// - Parameter id: メニューを出した要素。共有のシートを、その行から出す。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func statusMenu(for entry: TimelineEntry, id: ItemID, groups: MenuLayout<StatusMenuItem>.Groups? = nil) -> BuiltMenu<StatusMenuCommand>? {
        let status = Self.status(of: entry)
        let notification: MastodonNotification? = if case .notification(let notification) = entry { notification } else { nil }
        let subject = status.map { OperationStatus.Subject($0.displayed) }
        let emojis = CustomEmojiMenus(timeline: self, subject: subject)
        let body = status.flatMap { selectableBody(for: id, statusID: $0.displayed.id) }
        let renderer = statusMenuRenderer(status: status, notification: notification, id: id, selectableBody: body, emojis: emojis)
        // 人の一覧の行では、その人へのユーザーのメニューを、そのまま出す。
        if case .account(let account) = entry {
            defer { reloadRelations([account.id]) }
            let user = MenuUser.account(account)
            let tree = UserMenuTree(subject: UserMenuSubject(user), actions: userMenuActions, linkBrowser: settings.linkBrowser)
            guard let node = tree.submenu(groups: settings.userMenuLayout.groups, avatar: .user(user)) else { return nil }
            return BuiltMenu(root: .submenu("", [node.map { .user(user, $0) }]), renderer: renderer) { [weak self] in self?.loadPendingMenuIcons() }
        }
        var tree = StatusMenuTree(status: status, notification: notification, now: now(), linkBrowser: settings.linkBrowser)
        tree.rowStatus = self.status(for: id)
        tree.myAccountID = myAccountID
        tree.canOpenThread = status.map(canOpenThread(of:)) ?? false
        tree.mediaIsCovered = status.map { mediaCover(for: $0) != nil } ?? false
        tree.canSelectText = body != nil
        tree.userMenu = settings.userMenuLayout.groups
        tree.userActions = userMenuActions
        tree.hashtagMenu = settings.hashtagMenuLayout.groups
        tree.hashtagMute = hashtagMuteActions
        tree.customEmoji = { emojis.node(for: $0) }
        let built = tree.menu(groups: groups ?? settings.statusMenuLayout.groups, includesFollowRequest: groups == nil)
        reloadRelations(built.shownUserIDs)
        // 描きながら集めた、アイコンのまだない人をまとめて読む。
        return built.root.map { BuiltMenu(root: $0, renderer: renderer) { [weak self] in self?.loadPendingMenuIcons() } }
    }

    /// メニューに出る人の関係を、まとめて1回で読み直す。組んだメニューは覚えていた関係のまま出し、読み直した関係は次に開いたときから使う。
    /// 覚えていなかった人の関係の項目は、この読み直しを待って中身を渡す。関係で中身が変わる項目を出していなければ読まない。
    private func reloadRelations(_ ids: [String]) {
        guard !ids.isEmpty, settings.userMenuLayout.groups.needsRelationship else { return }
        userMenuActions?.reloadRelations(ids)
    }

    /// 投稿のメニューの描き方と、押された操作の行い方。
    /// - Parameter selectableBody: 「テキストを選択」で選ぶ本文。メニューを組んだときの行のものを使う。
    private func statusMenuRenderer(status: Status?, notification: MastodonNotification?, id: ItemID, selectableBody: PostBodyView?, emojis: CustomEmojiMenus) -> MenuRenderer<StatusMenuCommand> {
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
            case .selectText:
                guard let self, let selectableBody, let status else { return }
                beginTextSelection(in: selectableBody, statusID: status.displayed.id)
            case .url(let command):
                self?.urlHandlers(id: id).perform(command)
            case .followRequest(let decision):
                guard let notification else { return }
                self?.onFollowRequestDecision?(decision, notification)
            case .user(let user, let command):
                guard let self else { return }
                makeUserMenu(for: user, id: id).perform(command, openProfile: openProfile(of: user))
            case .hashtag(let tag, let command):
                guard let status else { return }
                self?.hashtagMenu(for: tag, of: status.displayed, id: id).perform(command)
            case .customEmoji(let emoji, let command):
                emojis.perform(command, on: emoji)
            }
        } customIcon: { [weak self] icon in
            switch icon {
            case .avatar(.user(let user), _): self?.userMenuIcon(for: user, id: id)
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
            muteActions: hashtagMuteActions,
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


    /// アイコンや人の一覧の行を長押ししたときに出す、その人のユーザーのメニュー。出す項目がなければnil。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func userMenu(for user: MenuUser, id: ItemID, groups: MenuLayout<UserMenuItem>.Groups? = nil) -> UIMenu? {
        defer { loadPendingMenuIcons() }
        return makeUserMenu(for: user, id: id).menu(groups: groups ?? settings.userMenuLayout.groups, openProfile: openProfile(of: user), avatar: .user(user)) { _ in
            self.userMenuIcon(for: user, id: id)
        }
    }

    /// この一覧の行から出すユーザーのメニュー。共有のシートはその行から出す。
    func makeUserMenu(for user: MenuUser, id: ItemID) -> UserMenu {
        // Mastodonは通報する相手の投稿しか添えられないため、長押しした投稿をその人が書いたときだけ添える。
        let shown = status(for: id)?.displayed
        return UserMenu(subject: UserMenuSubject(user), actions: userMenuActions, handlers: urlHandlers(id: id), host: self, reportableStatusID: shown?.account.id == user.id ? shown?.id : nil)
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

    /// ユーザーのメニューのアイコンにする、その人のアイコン。読み込み済みの画像を、一覧と同じ形に切り抜く。
    /// メンションされたユーザーは、APIの`Mention`にアイコンのURLがないため、一覧の行か前に読んだアカウントから探す。
    /// まだアイコンを出せなければ記号のプレースホルダーを返し、アカウントとアイコンを読み終えたら、開いているメニューのプレースホルダーを差し替える。
    /// - Parameter id: メニューを出した行。行に描いた大きさのアイコンも探す。本文のメンションのメニューのように、行が決まらなければnil。
    func userMenuIcon(for user: MenuUser, id: ItemID?) -> UIImage {
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
    func loadPendingMenuIcons() {
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
    func urlHandlers(id: ItemID) -> URLMenuHandlers {
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

}
