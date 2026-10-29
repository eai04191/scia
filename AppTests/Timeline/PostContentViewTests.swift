import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

@Suite(.scratch)
@MainActor
struct PostContentViewTests {
    private func makeViewController() -> TimelineViewController {
        TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: .isolated())
    }

    /// 一覧のセルと同じく、大きな高さを目安に、高さを譲れる優先度で測る。
    private func fittingHeight(of configuration: PostContentConfiguration) -> CGFloat {
        configuration.makeContentView().systemLayoutSizeFitting(
            CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private func status(content: String, reblogOf original: Status? = nil) throws -> Status {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        return Status(id: base.id, createdAt: base.createdAt, account: base.account, content: content, spoilerText: "", url: nil, reblog: original)
    }

    /// 名前の行をベースラインで揃えたスタックは高さが決まらず、目安の高さまで伸びて、セルが落ちたことがある。
    @Test func heightFitsContentWhenMeasuredAgainstHugeTarget() throws {
        let short = makeViewController().contentConfiguration(for: try status(content: "<p>短い</p>"), base: .cell())
        let long = makeViewController().contentConfiguration(for: try status(content: "<p>" + String(repeating: "長い本文。", count: 40) + "</p>"), base: .cell())

        #expect(fittingHeight(of: short) < 200)
        #expect(fittingHeight(of: long) > fittingHeight(of: short))
    }

    /// 本文が1行でも、アイコンの下に余白を残す。
    @Test func shortBodyKeepsMarginBelowAvatar() throws {
        let configuration = makeViewController().contentConfiguration(for: try status(content: "<p>短い</p>"), base: .cell())
        let metrics = configuration.metrics

        #expect(fittingHeight(of: configuration) >= metrics.margins.top + metrics.avatarSize + metrics.margins.bottom)
    }

    /// 本文が1行でアイコンの方が下まで届くときも、本文の文字を引き伸ばさず、余りは行の下の余白に回す。
    /// UILabelは伸ばされた枠の上下中央に文字を描くため、伸ばすと本文が名前の行から下にずれる。折りたたんだ注意書きの文字も同じ。
    @Test(arguments: [false, true])
    func shortBodyIsNotStretchedToAvatarHeight(spoiler: Bool) throws {
        let base = try status(content: "<p>短い本文。Body text</p>")
        let post = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: spoiler ? "ネタバレ" : "", url: nil)
        var configuration = makeViewController().contentConfiguration(for: post, base: .cell())
        // 既定の大きさでは、1行の本文とアイコンの下端がほぼ揃う。確実にアイコンの方が下まで届くよう、アイコンを大きくする。
        configuration.metrics.avatarSize = 80
        let view = configuration.makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 360, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let body = try #require(postBodyView(in: view))
        let labels = visibleLabels(in: body)
        let metrics = configuration.metrics

        #expect(size.height >= metrics.margins.top + metrics.avatarSize + metrics.margins.bottom)
        #expect(!labels.isEmpty)
        for label in labels {
            #expect(abs(label.bounds.height - label.intrinsicContentSize.height) < 0.5, "\(label.text ?? "") label=\(label.bounds) intrinsic=\(label.intrinsicContentSize)")
        }
    }

    enum ShortRowShape: String, CaseIterable {
        case plain, boost, media, spoiler
    }

    /// 一覧は行の高さを画素に丸めるため、行が求める高さより1画素未満だけ低くなることがある。
    /// 足りない分を文字のラベルから削ると、UILabelは収まらない行を描かず、本文の最後の行が消える。
    /// 足りない分は本文の下の余白で吸い、どの形でも文字のラベルは求める高さを保つ。
    @Test(arguments: ShortRowShape.allCases)
    func labelsKeepTheirHeightWhenRowIsSlightlyShort(shape: ShortRowShape) throws {
        let base = try status(content: "<p>急に全部のアプリが死んで何と思ったらclaudeにultrakillされてた</p>")
        let media = MediaAttachment(
            id: "1",
            type: .image,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: URL(string: "https://files.example.social/small/1.png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_475, height: 665))
        )
        let post = switch shape {
        case .plain: base
        case .boost: Status(id: "200", createdAt: base.createdAt, account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: base.account.avatar), content: "", spoilerText: "", url: nil, reblog: base)
        case .media: Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil, mediaAttachments: [media])
        case .spoiler: Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "急に全部のアプリが死んで何と思ったらclaudeにultrakillされてた", url: nil)
        }
        let view = makeViewController().contentConfiguration(for: post, base: .cell()).makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height - 0.3)
        view.layoutIfNeeded()
        let labels = visibleLabels(in: view).filter { $0.intrinsicContentSize.height > 0 }

        #expect(labels.count >= 2)
        for label in labels {
            #expect(label.bounds.height >= label.intrinsicContentSize.height - 0.01, "\(label.text ?? "") label=\(label.bounds) intrinsic=\(label.intrinsicContentSize)")
        }
    }

    private func postBodyView(in view: UIView) -> PostBodyView? {
        for subview in view.subviews {
            if let body = subview as? PostBodyView ?? postBodyView(in: subview) { return body }
        }
        return nil
    }

    private func visibleLabels(in view: UIView) -> [UILabel] {
        view.subviews.filter { !$0.isHidden }.flatMap { subview in
            (subview as? UILabel).map { [$0] } ?? visibleLabels(in: subview)
        }
    }

    @Test func boostAddsRowAboveName() throws {
        let original = try status(content: "<p>短い</p>")
        let booster = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: original.account.avatar)
        let boost = Status(id: "200", createdAt: original.createdAt, account: booster, content: "", spoilerText: "", url: nil, reblog: original)
        let controller = makeViewController()

        #expect(fittingHeight(of: controller.contentConfiguration(for: boost, base: .cell())) > fittingHeight(of: controller.contentConfiguration(for: original, base: .cell())))
    }
    /// 公開以外の投稿は、時刻の前に公開範囲の記号を描き、読み上げでは言葉にする。公開の投稿には何も付けない。
    @Test(arguments: [(Status.Visibility.public, nil), (.unlisted, "ひかえめな公開"), (.private, "フォロワーのみ"), (.direct, "メンションした相手のみ")] as [(Status.Visibility, String?)])
    func visibilityIsShownBeforeTime(visibility: Status.Visibility, spokenTitle: String?) throws {
        let base = try status(content: "<p>短い</p>")
        let status = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil, visibility: visibility, editedAt: base.createdAt)
        let configuration = makeViewController().contentConfiguration(for: status, base: .cell())
        let view = configuration.makeContentView()

        let timeText = try #require(visibleLabels(in: view).compactMap(\.attributedText).first { $0.string.contains("*") })
        let attachmentRange = timeText.length > 0 ? timeText.attribute(.attachment, at: 0, effectiveRange: nil) : nil
        #expect((attachmentRange != nil) == (spokenTitle != nil))
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        let label = try #require(element.accessibilityLabel)
        if let spokenTitle {
            #expect(label.contains("\(spokenTitle)、編集済み、"))
        } else {
            #expect(!label.contains("公開"))
        }
    }

    /// 絵文字の画像が届いたときや時刻の表記が変わったときは、大きさの変わらない描き直しで並べ直しが起きない。
    /// そのあとも、読み上げの要素は画面上の文字の位置を指したままにする。枠が空になると、VoiceOverで指でなぞってもその投稿に止まらない。
    @Test func accessibilityFrameSurvivesRedrawWithoutLayout() throws {
        let configuration = makeViewController().contentConfiguration(for: try status(content: "<p>短い</p>"), base: .cell())
        let view = configuration.makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 360, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        let laidOut = element.accessibilityFrameInContainerSpace
        #expect(!laidOut.isEmpty)

        view.configuration = configuration
        view.layoutIfNeeded()
        #expect(element.accessibilityFrameInContainerSpace == laidOut)

        try #require(view as? PostContentView).refreshTime(now: try status(content: "<p>短い</p>").createdAt.addingTimeInterval(60 * 60 * 24 * 400))
        view.layoutIfNeeded()
        #expect(element.accessibilityFrameInContainerSpace == laidOut)
    }

    /// VoiceOverでは本文を1つの要素で読むため、リンクは要素の操作から開く。ハッシュタグも、タップと同じくタイムラインを開く操作として出す。
    @Test func exposesLinksAsAccessibilityActions() throws {
        let content = #"<p>見て <a href="https://example.com/a"><span class="invisible">https://</span>example.com/a</a> <a href="https://example.social/tags/scia" class="mention hashtag" rel="tag">#<span>scia</span></a></p>"#
        var configuration = makeViewController().contentConfiguration(for: try status(content: content), base: .cell())
        var opened: [RichText.LinkDestination] = []
        configuration.onOpenLink = { opened.append($0) }
        let view = configuration.makeContentView()

        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        // プロフィールを開く操作は、本文の操作のあとに並ぶ。
        let actions = (element.accessibilityCustomActions ?? []).filter { !$0.name.hasSuffix("のプロフィール") }
        #expect(actions.map(\.name) == ["example.com/a", "#scia"])
        _ = actions.first?.actionHandler?(try #require(actions.first))
        #expect(opened == [.url(try #require(URL(string: "https://example.com/a")))])
    }
    /// 空行の多い本文の末尾のリンクも押せる。判定の位置を、ラベルが実際に描いた位置と比べる。
    /// TextKit 1で並べ直すと、空行のたびに行の位置がUILabelの描画からずれ、末尾のリンクを外したことがある。
    @Test func linkAfterManyBlankLinesIsTappableWhereDrawn() throws {
        let content = #"<blockquote>これ系のセキュリティ系のお漏らしや脆弱性を見つけることは割とするんだけど、<br><br>純粋に煙たがられますね<br><br>普通の経営者って労働者を時間いっぱい働かすことに合理性があって、労働者はパンパンの状態で働く。その中で、セキュリティの指摘をするやつは、<br><br>経営者から見れば、経営不安にさせる指摘をする奴<br>労働者から見れば、余計な仕事を増やす奴<br><br>なので、いいことないですよ。<br>で、基本的には自分の個人情報ではなく、自分以外の顧客情報が洩れることになるので、経営者・労働者、双方にノーダメだったりする。そうすると<br><br>いかにセキュリティの脆弱性を見つけても、指摘したやつが問題や余計な仕事を増やす嫌な奴<br><br>になる。<br>だから煙たがられる。</blockquote><a href="https://x.com/kotauchisunsun/status/2111061896434782560" rel="nofollow noopener" target="_blank">https://x.com/kotauchisunsun/status/2111061896434782560</a>"#
        let configuration = makeViewController().contentConfiguration(for: try status(content: content), base: .cell())
        let view = configuration.makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let label = try #require(linkLabel(in: view))
        let drawn = try #require(lowestLinkColoredPoint(in: label))

        let url = try #require(URL(string: "https://x.com/kotauchisunsun/status/2111061896434782560"))
        #expect(label.link(at: drawn) == .url(url), "label=\(label.bounds) drawn=\(drawn)")
    }

    /// 本文のラベル。本文は投稿の中身の部品の中にあるため、子孫のビューから探す。
    private func linkLabel(in view: UIView) -> LinkLabel? {
        for subview in view.subviews {
            if let label = subview as? LinkLabel ?? linkLabel(in: subview) { return label }
        }
        return nil
    }

    /// 右から左へ書く文字のリンクも、描いた位置で押せる。文字の端の位置は書く向きで左右が入れ替わる。
    @Test func rightToLeftLinkIsTappableWhereDrawn() throws {
        let content = #"<p>אאאא <a href="https://example.com/rtl">בבבבבבבב</a> גגגג</p>"#
        let configuration = makeViewController().contentConfiguration(for: try status(content: content), base: .cell())
        let view = configuration.makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let label = try #require(linkLabel(in: view))
        let drawn = try #require(lowestLinkColoredPoint(in: label))

        let url = try #require(URL(string: "https://example.com/rtl"))
        #expect(label.link(at: drawn) == .url(url), "label=\(label.bounds) drawn=\(drawn)")
    }

    /// ラベルを画像に描き、リンクの色（tintColor）で描かれた画素のうち、いちばん下の行の中ほどの点を返す。
    private func lowestLinkColoredPoint(in label: UILabel) -> CGPoint? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: label.bounds, format: format).image { context in
            label.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        // 青が強く、赤が弱い画素をリンクの文字とみなす。
        func isLink(_ x: Int, _ y: Int) -> Bool {
            let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
            let blue = Int(bytes[offset]), red = Int(bytes[offset + 2]), alpha = Int(bytes[offset + 3])
            return alpha > 100 && blue > 150 && red < 100
        }
        var rows: [Int] = []
        var columns: [Int] = []
        for y in 0..<cgImage.height {
            let hits = (0..<cgImage.width).filter { isLink($0, y) }
            if !hits.isEmpty {
                rows.append(y)
                columns += hits
            }
        }
        guard let bottom = rows.last else { return nil }
        // いちばん下の行のまとまりの、上下の中ほど。
        var top = bottom
        while rows.contains(top - 1) || rows.contains(top - 2) { top -= 1 }
        let lineColumns = (top...bottom).flatMap { y in (0..<cgImage.width).filter { isLink($0, y) } }
        guard let minX = lineColumns.min(), let maxX = lineColumns.max() else { return nil }
        return CGPoint(x: CGFloat(minX + maxX) / 2, y: CGFloat(top + bottom) / 2)
    }

    private func spoilerStatus() throws -> Status {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let content = #"<p>注意書きの下の本文。<a href="https://example.com/a">example.com/a</a></p>"#
        return Status(id: base.id, createdAt: base.createdAt, account: base.account, content: content, spoilerText: "ネタバレ", url: nil)
    }

    /// 折りたたんでいる間は注意書きだけを出し、開くと本文の分だけ高くなる。
    @Test func collapsedSpoilerHidesBody() throws {
        let controller = makeViewController()
        let status = try spoilerStatus()
        let collapsed = controller.contentConfiguration(for: status, base: .cell())
        controller.toggleSpoiler(of: status)
        let expanded = controller.contentConfiguration(for: status, base: .cell())

        #expect(collapsed.spoiler?.isCollapsed == true)
        #expect(expanded.spoiler?.isCollapsed == false)
        #expect(fittingHeight(of: expanded) > fittingHeight(of: collapsed))
    }

    /// 読み上げでは、折りたたんでいる間は本文を読まず、本文のリンクも出さない。開閉は要素の操作から行う。
    @Test func collapsedSpoilerReadsOnlyWarning() throws {
        let controller = makeViewController()
        let status = try spoilerStatus()
        var configuration = controller.contentConfiguration(for: status, base: .cell())
        var toggled = 0
        configuration.onToggleSpoiler = { toggled += 1 }
        let view = configuration.makeContentView()

        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        let label = try #require(element.accessibilityLabel)
        #expect(label.contains("注意書き、ネタバレ"))
        #expect(!label.contains("本文"))
        let actions = (element.accessibilityCustomActions ?? []).filter { !$0.name.hasSuffix("のプロフィール") }
        #expect(actions.map(\.name) == ["本文を表示"])
        _ = actions.first?.actionHandler?(try #require(actions.first))
        #expect(toggled == 1)
    }

    @Test func expandedSpoilerReadsBodyAndLinks() throws {
        let controller = makeViewController()
        let status = try spoilerStatus()
        controller.toggleSpoiler(of: status)
        let view = controller.contentConfiguration(for: status, base: .cell()).makeContentView()

        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        #expect(element.accessibilityLabel?.contains("注意書きの下の本文") == true)
        #expect((element.accessibilityCustomActions ?? []).filter { !$0.name.hasSuffix("のプロフィール") }.map(\.name) == ["本文を隠す", "example.com/a"])
    }

    /// 押した場所の押下を受けるビュー。押したビューから上へたどり、タップのジェスチャーを持つ最初のビューを返す。なければ行全体の押下に渡る。
    private func tapTarget(in view: UIView, at point: CGPoint) -> UIView? {
        var target = view.hitTest(point, with: nil)
        while let current = target, current !== view {
            if (current.gestureRecognizers ?? []).contains(where: { $0 is UITapGestureRecognizer }) { return current }
            target = current.superview
        }
        return nil
    }

    private func subviews<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview in [subview as? T].compactMap(\.self) + subviews(of: type, in: subview) }
    }

    /// 名前の行は押下を受けず、行全体の押下に渡す。投稿した人はアイコンで、ブーストした人は上の行のアイコンと名前で開く。
    @Test func nameRowPassesTapToRow() throws {
        let original = try status(content: "<p>短い</p>")
        let booster = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: original.account.avatar)
        let boost = Status(id: "200", createdAt: original.createdAt, account: booster, content: "", spoilerText: "", url: nil, reblog: original)
        let configuration = makeViewController().contentConfiguration(for: boost, base: .cell())
        let view = configuration.makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let metrics = configuration.metrics
        let avatar = try #require(subviews(of: AvatarView.self, in: view).first { $0.frame.width == metrics.avatarSize })
        let contextLabel = try #require(subviews(of: FadingLabel.self, in: view).first { !$0.isHidden })

        // 名前の行はアイコンの上端から始まる。左の名前と右端の時刻のどちらも受けない。
        let nameY = avatar.frame.minY + 5
        #expect(tapTarget(in: view, at: CGPoint(x: avatar.frame.maxX + 20, y: nameY)) == nil)
        #expect(tapTarget(in: view, at: CGPoint(x: view.bounds.maxX - metrics.margins.trailing - 4, y: nameY)) == nil)
        #expect(tapTarget(in: view, at: CGPoint(x: avatar.frame.midX, y: avatar.frame.midY)) === avatar)
        let contextPoint = contextLabel.convert(CGPoint(x: contextLabel.bounds.midX, y: contextLabel.bounds.midY), to: view)
        #expect(tapTarget(in: view, at: contextPoint) === contextLabel)
    }
}

extension PostContentViewTests {
    /// アイコンと名前の上の行のタップで開くプロフィールは、VoiceOverでは投稿の要素の操作で開く。
    @Test func profilesOpenFromVoiceOverActions() throws {
        let original = try status(content: "<p>元の投稿</p>")
        let base = try status(content: "")
        let bob = Account(id: "booster", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)
        let boost = Status(id: base.id, createdAt: base.createdAt, account: bob, content: "", spoilerText: "", url: nil, reblog: original)
        var configuration = makeViewController().contentConfiguration(for: boost, base: .cell())
        var opened: [String] = []
        configuration.onOpenAccount = { opened.append("author") }
        configuration.onOpenContextAccount = { opened.append("booster") }
        let view = configuration.makeContentView()
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        let actions = element.accessibilityCustomActions ?? []

        let author = try #require(actions.first { $0.name == "\(original.account.displayNameOrUsername)のプロフィール" })
        let booster = try #require(actions.first { $0.name == "\(boost.account.displayNameOrUsername)のプロフィール" })
        _ = author.actionHandler?(author)
        _ = booster.actionHandler?(booster)

        #expect(opened == ["author", "booster"])
    }

    /// 返信のラベルのように押せない名前の上の行には、プロフィールを開く操作を付けない。
    @Test func contextWithoutAccountHasNoProfileAction() throws {
        var configuration = makeViewController().contentConfiguration(for: try status(content: "<p>短い</p>"), base: .cell())
        configuration.onOpenAccount = {}
        configuration.onOpenContextAccount = {}
        let view = configuration.makeContentView()
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)

        #expect((element.accessibilityCustomActions ?? []).filter { $0.name.hasSuffix("のプロフィール") }.count == 1)
    }
}

extension PostContentViewTests {
    private func emojiPNG() throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }.pngData())
    }

    /// 名前と本文の両方にカスタム絵文字のある投稿を、絵文字の画像が届いた状態で並べ、部品の枠を返す。
    private func emojiPostFrames(nameScale: Double, bodyScale: Double, nameUnicodeScale: Double = 1, bodyUnicodeScale: Double = 1) async throws -> AppearancePreviewFrames {
        let url = try #require(URL(string: "https://example.social/emoji/blobcat.png"))
        let blobcat = CustomEmoji(shortcode: "blobcat", url: url, staticUrl: url)
        let png = try emojiPNG()
        let store = EmojiImageStore { _ in png }
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        let settings = AppSettings.isolated()
        settings.setValue(nameScale, for: AppearanceCatalog.nameCustomEmojiScale)
        settings.setValue(bodyScale, for: AppearanceCatalog.customEmojiScale)
        settings.setValue(nameUnicodeScale, for: AppearanceCatalog.nameUnicodeEmojiScale)
        settings.setValue(bodyUnicodeScale, for: AppearanceCatalog.unicodeEmojiScale)
        let base = try status(content: "")
        let author = Account(id: "3", username: "carol", acct: "carol", displayName: "名前 :blobcat: 😀", avatar: nil, emojis: [blobcat])
        let post = Status(id: base.id, createdAt: base.createdAt, account: author, content: "<p>本文 :blobcat: の絵文字 😀</p><p>最後の段落 :blobcat: 😀</p>", spoilerText: "", url: nil, emojis: [blobcat])
        let controller = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: store, avatarImages: .offline, settings: settings)
        let view = try #require(controller.contentConfiguration(for: post, base: .cell()).makeContentView() as? PostContentView)
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view.previewFrames()
    }

    /// 本文のカスタム絵文字を大きくしても、1行目の絵文字が上へ伸びて名前の行に重ならない。
    @Test(arguments: [1.0, 2.0, 4.0])
    func largeBodyEmojiStaysBelowNameRow(scale: Double) async throws {
        let frames = try await emojiPostFrames(nameScale: 1, bodyScale: scale, bodyUnicodeScale: scale)
        let name = try #require(frames[.nameGlyphs]?.first)
        let emojis = (frames[.customEmojis] ?? []) + (frames[.unicodeEmojis] ?? [])

        #expect(!emojis.isEmpty)
        for emoji in emojis {
            #expect(emoji.minY >= name.maxY, "絵文字=\(emoji) 名前の字面=\(name)")
        }
    }

    /// 名前の絵文字を大きくしても、字面の中心より下へ伸びた分で、本文の1行目に重ならない。
    @Test(arguments: [1.0, 4.0])
    func largeNameEmojiStaysAboveBody(scale: Double) async throws {
        let frames = try await emojiPostFrames(nameScale: scale, bodyScale: 1, nameUnicodeScale: scale)
        let body = try #require(frames[.bodyGlyphs]?.first)
        let name = try #require(frames[.nameGlyphs]?.first)
        let emojis = (frames[.nameCustomEmojis] ?? []) + (frames[.nameUnicodeEmojis] ?? [])

        #expect(name.maxY <= body.minY + 0.01)
        for emoji in emojis {
            #expect(emoji.maxY <= body.minY + 0.01, "絵文字=\(emoji) 本文の字面=\(body)")
        }
    }

    /// 本文の絵文字を大きくしても、最初と最後の段落の絵文字が伸びた分を本文の字面に含め、上と下の部品とのあいだをそこから測る。
    /// 等倍の絵文字も、上下が書体のascenderとdescenderまであり、em枠の字面から少し出る。大きくしても、出る長さはそれと同じにする。
    @Test func largeBodyEmojiIsInsideBodyGlyphs() async throws {
        let frames = try await emojiPostFrames(nameScale: 1, bodyScale: 4, bodyUnicodeScale: 4)
        let body = try #require(frames[.bodyGlyphs]?.first)
        let emojis = (frames[.customEmojis] ?? []) + (frames[.unicodeEmojis] ?? [])
        let font = PostTypography(settings: .isolated()).font(.body)
        let above = font.ascender - font.pointSize * PostBodyView.emBoxAscent
        let below = -font.descender - font.pointSize * PostBodyView.emBoxDescent

        #expect(emojis.count >= 4)
        for emoji in emojis {
            #expect(emoji.minY >= body.minY - above - 0.5 && emoji.maxY <= body.maxY + below + 0.5, "絵文字=\(emoji) 本文の字面=\(body)")
        }
    }

    /// 行数で切って描く本文（通知の再掲など）は、最後に見える行の段落が分からないため、最後の段落でなくても大きい絵文字の分を下の余白に含める。
    @Test func truncatedBodyReservesEmojiBelowFromAnyParagraph() {
        let font = UIFont.preferredFont(forTextStyle: .body)
        var renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja")
        renderer.unicodeEmojiScale = 4
        let text = renderer.render(RichText(blocks: [
            RichText.Block(inlines: [.text("文😀", [])]),
            RichText.Block(inlines: [.text("切れて見えない最後の段落", [])]),
        ]))
        let below = RichTextRenderer.emojiExtent(in: text, range: NSRange(location: 0, length: text.length)).below

        #expect(PostBodyView.textBottomInset(of: text, isTruncated: true) >= below - 0.01 + font.pointSize * PostBodyView.emBoxDescent + font.descender)
        #expect(PostBodyView.textBottomInset(of: text, isTruncated: true) > PostBodyView.textBottomInset(of: text))
    }

    /// 普通の絵文字が既定の1倍でも、名前と本文の普通の絵文字の枠を返す。返さないと、「投稿の見た目」で既定値に戻したとき、
    /// 示す範囲が絵文字から名前の行や本文の全体に替わる。枠は、大きくしたときと同じく、描く絵の枠にする。
    @Test func unscaledUnicodeEmojisHaveFrames() async throws {
        let frames = try await emojiPostFrames(nameScale: 1, bodyScale: 1)
        let name = try #require(frames[.nameUnicodeEmojis])
        let body = try #require(frames[.unicodeEmojis])
        let font = PostTypography(settings: .isolated()).font(.body)

        #expect(name.count == 1)
        #expect(body.count == 2)
        for emoji in body {
            #expect(abs(emoji.height - EmojiFont.glyphHeight(of: font)) < 0.5, "絵文字=\(emoji)")
        }
    }

    /// 名前と本文のカスタム絵文字は、それぞれの設定の割合で大きさを変える。
    @Test func nameAndBodyEmojiScaleIndependently() async throws {
        let plain = try await emojiPostFrames(nameScale: 1, bodyScale: 1)
        let scaled = try await emojiPostFrames(nameScale: 2, bodyScale: 3)
        let plainName = try #require(plain[.nameCustomEmojis]?.first)
        let plainBody = try #require(plain[.customEmojis]?.first)
        let scaledName = try #require(scaled[.nameCustomEmojis]?.first)
        let scaledBody = try #require(scaled[.customEmojis]?.first)

        #expect(abs(scaledName.height - plainName.height * 2) < 1, "名前: \(plainName.height) → \(scaledName.height)")
        #expect(abs(scaledBody.height - plainBody.height * 3) < 1, "本文: \(plainBody.height) → \(scaledBody.height)")
    }
}
