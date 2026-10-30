import SciaCore
import UIKit

extension UserMenu {
    /// 関係の項目。関係を覚えている相手は、覚えている関係でその場で組む。
    /// 覚えていない相手は、読む間はUIKitの読み込み中の行を出し、読んでから中身を渡す。開く途中のサブメニューで中身が替わると動きが崩れるため、
    /// メニューを開いたときに出る人の関係をまとめて読み直し（`reloadRelations`）、次からは覚えている関係で組めるようにしている。
    /// 自分には出さない。読めなかったら、`failureSlots`の項目にだけ押せない行で知らせ、ほかの項目は何も出さない。項目ごとに同じ知らせが並ばないようにするため。
    /// 通報は関係で中身が変わらないため、関係を待たずに出す。リンクのメンションのように相手を探す必要があるときは、探してから出す。
    func relationElements(_ item: UserMenuItem, actions: UserMenuActions, load: UserRelationLoad, failureSlots: RelationFailureSlots) -> [UIMenuElement] {
        let reportableStatusID = reportableStatusID
        func elements(_ relation: UserRelation) -> [UIMenuElement] {
            Self.relationElements(item, relationship: relation.relationship) { change in
                actions.changeRelation(change, relation)
            } editNote: {
                actions.editNote(relation)
            } report: {
                actions.report(relation.accountID, relation.acct, reportableStatusID)
            }
        }
        switch actions.knownRelation(subject.target) {
        case .myself:
            return []
        case .relation(let relation):
            return elements(relation)
        case nil:
            break
        }
        if item == .report {
            return reportElements(actions: actions, load: load, showsFailure: failureSlots.resolve == .report)
        }
        return [UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                do {
                    guard let relation = try await load.value else {
                        completion([])
                        return
                    }
                    completion(elements(relation))
                } catch {
                    // 相手を探せなかったのか、探せて関係だけ読めなかったのかで、知らせる場所が違う。探した結果は分け合っているので、もう一度探しはしない。
                    let resolved = (try? await load.identity) != nil
                    completion(item == (resolved ? failureSlots.relation : failureSlots.resolve) ? [Self.relationFailureAction] : [])
                }
            }
        }]
    }

    /// 関係を覚えていない相手の通報。相手のIDが分かっていればその場で出し、相手を探すときは探してから出す。自分には出さない。
    private func reportElements(actions: UserMenuActions, load: UserRelationLoad, showsFailure: Bool) -> [UIMenuElement] {
        let reportableStatusID = reportableStatusID
        func action(_ identity: UserIdentity) -> UIAction {
            UIAction(title: UserMenuItem.report.title, image: UserMenuItem.report.image) { _ in actions.report(identity.id, identity.acct, reportableStatusID) }
        }
        if case .account(let id, let acct) = subject.target {
            return [action(UserIdentity(id: id, acct: acct))]
        }
        return [UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                do {
                    let identity = try await load.identity
                    if case .myself = actions.knownRelation(.account(id: identity.id, acct: identity.acct)) {
                        completion([])
                    } else {
                        completion([action(identity)])
                    }
                } catch {
                    completion(showsFailure ? [Self.relationFailureAction] : [])
                }
            }
        }]
    }

    /// 関係を読めなかった知らせ。押せない行で出す。
    private static var relationFailureAction: UIAction {
        UIAction(title: "関係を読み込めませんでした", image: UIImage(systemName: "exclamationmark.triangle"), attributes: .disabled) { _ in }
    }

    /// メニューを1回開く間、同じユーザーの項目で分け合う、相手の探し方と関係の読み方。
    static func relationLoad(for target: UserMenuTarget, actions: UserMenuActions) -> UserRelationLoad {
        UserRelationLoad {
            try await actions.resolveTarget(target)
        } load: { identity in
            try await actions.loadRelation(target, identity)
        }
    }

    /// 関係に合わせた項目。出さないときは空。
    /// ブロックしているか、されているときは、フォローもフォローの設定もできないため出さない。フォローの設定は、フォロー中かリクエスト中の相手にだけ出す。
    static func relationElements(
        _ item: UserMenuItem,
        relationship: Relationship,
        perform: @escaping @MainActor (UserRelationChange) -> Void,
        editNote: @escaping @MainActor () -> Void,
        report: @escaping @MainActor () -> Void
    ) -> [UIMenuElement] {
        func action(_ title: String, _ symbolName: String?, attributes: UIMenuElement.Attributes = [], state: UIMenuElement.State = .off, _ change: UserRelationChange) -> UIAction {
            UIAction(title: title, image: symbolName.flatMap { UIImage(systemName: $0) }, attributes: attributes, state: state) { _ in perform(change) }
        }
        let blocked = relationship.blocking || relationship.blockedBy
        let followsOrRequests = relationship.following || relationship.requested
        switch item {
        case .follow:
            guard !blocked else { return [] }
            if relationship.following { return [action("フォローを外す", "person.badge.minus", .unfollow)] }
            if relationship.requested { return [action("フォローのリクエストを取り消す", "person.badge.clock", .cancelFollowRequest)] }
            return [action(item.title, "person.badge.plus", .follow)]
        case .showReblogs:
            guard !blocked, followsOrRequests else { return [] }
            return [action(item.title, "arrow.2.squarepath", state: relationship.showingReblogs ? .on : .off, .showReblogs(!relationship.showingReblogs))]
        case .notify:
            guard !blocked, followsOrRequests else { return [] }
            return [action(item.title, "bell", state: relationship.notifying ? .on : .off, .notify(!relationship.notifying))]
        case .note:
            // ブロックしていてもメモは書ける。
            return [UIAction(title: relationship.note.isEmpty ? item.title : "メモを編集", image: item.image) { _ in editNote() }]
        case .mute:
            if relationship.muting { return [action("ミュートを解除", "speaker.wave.2", .unmute)] }
            return [UIMenu(title: item.title, image: item.image, children: UserRelationChange.muteDurations.map { choice in
                action(choice.title, nil, .mute(choice.duration))
            })]
        case .block:
            if relationship.blocking { return [action("ブロックを解除", "hand.raised.slash", .unblock)] }
            return [action(item.title, "hand.raised", attributes: .destructive, .block)]
        case .report:
            return [UIAction(title: item.title, image: item.image) { _ in report() }]
        case .profile, .mention, .copyHandle, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            return []
        }
    }
}
