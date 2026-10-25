import SciaCore
import Testing
import UIKit
@testable import Scia

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
        let vc = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline, avatarImages: .offline)
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
        let vc = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline, avatarImages: .offline)
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
}
