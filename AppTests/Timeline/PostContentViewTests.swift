import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct PostContentViewTests {
    private func makeViewController() -> TimelineViewController {
        TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline)
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
    /// UILabelは伸ばされた枠の上下中央に文字を描くため、伸ばすと本文が名前の行から下にずれる。畳んだ注意書きの文字も同じ。
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

        try #require(view as? PostContentView).refreshTime(now: .now.addingTimeInterval(60 * 60 * 24 * 400))
        view.layoutIfNeeded()
        #expect(element.accessibilityFrameInContainerSpace == laidOut)
    }

    /// VoiceOverでは本文を1つの要素で読むため、リンクは要素の操作から開く。押しても何もしないハッシュタグは出さない。
    @Test func exposesLinksAsAccessibilityActions() throws {
        let content = #"<p>見て <a href="https://example.com/a"><span class="invisible">https://</span>example.com/a</a> <a href="https://example.social/tags/scia" class="mention hashtag" rel="tag">#<span>scia</span></a></p>"#
        var configuration = makeViewController().contentConfiguration(for: try status(content: content), base: .cell())
        var opened: [RichText.LinkDestination] = []
        configuration.onOpenLink = { opened.append($0) }
        let view = configuration.makeContentView()

        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        let actions = element.accessibilityCustomActions ?? []
        #expect(actions.map(\.name) == ["example.com/a"])
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

    /// 畳んでいる間は注意書きだけを出し、開くと本文の分だけ高くなる。
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

    /// 読み上げでは、畳んでいる間は本文を読まず、本文のリンクも出さない。開閉は要素の操作から行う。
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
        let actions = element.accessibilityCustomActions ?? []
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
        #expect((element.accessibilityCustomActions ?? []).map(\.name) == ["本文を隠す", "example.com/a"])
    }
}
