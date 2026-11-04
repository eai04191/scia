import Testing
import UIKit
@testable import Scia

/// 1行の文字を入力欄と同じTextKit 2で描くビューの、縦の置き方。
@MainActor
struct TextLineViewTests {
    /// カプセルのように上下の真ん中に置いたとき、UILabelを同じように置いたときと同じ高さにベースラインが来る。
    /// TextKit 2の行の高さには、フォントの行間がベースラインの下に足されている。行の高さで真ん中に置くと、その分だけ文字が上に寄る。
    @Test(arguments: ["いまどうしてる？", "abc"])
    func centeredBaselineMatchesLabel(text: String) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        let attributed = NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
        let line = TextLineView()
        line.attributedText = attributed
        let label = UILabel()
        label.attributedText = attributed
        for (view, x) in [(line as UIView, 20.0), (label, 200.0)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: x),
                view.centerYAnchor.constraint(equalTo: window.topAnchor, constant: 61),
            ])
        }
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let lineBaseline = line.convert(line.baselineOrigin, to: window).y
        // UILabelは、文字の大きさに合わせた高さの上端からフォントのアセンダーの位置にベースラインを置く。
        let labelBaseline = label.frame.minY + UIFont.preferredFont(forTextStyle: .body).ascender
        #expect(abs(lineBaseline - labelBaseline) < 0.01, "TextLineViewは\(lineBaseline)、UILabelは\(labelBaseline)")
    }

    /// 本文のフォントで描く文字では、UILabelと同じ高さになる。
    @Test(arguments: ["いまどうしてる？", "abc"])
    func heightMatchesLabel(text: String) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let attributed = NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
        let line = TextLineView()
        line.attributedText = attributed
        let label = UILabel()
        label.attributedText = attributed
        window.addSubview(line)
        window.addSubview(label)

        #expect(abs(line.intrinsicContentSize.height - label.intrinsicContentSize.height) < 0.01, "TextLineViewは\(line.intrinsicContentSize.height)、UILabelは\(label.intrinsicContentSize.height)")
    }

    /// 行の下の行間に掛かる字形（タイ文字の下に付く母音など）も、ビューの中に収まり、描いたときに欠けない。
    /// 上端は確かめない。ミャンマー文字は字形がTextKit 2の行の上端を約0.9pt越え、行の高さで描く範囲を決めていたときから欠けている。
    /// 直すには描く範囲を行の外へ広げる仕組みが要り、カプセルの文字の高さを揃えるこの変更の範囲から外している。
    @Test(arguments: ["မြန်မာ", "ฉันกำลังทำอะไรอยู่"])
    func glyphsBelowBaselineFitInBounds(text: String) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let attributed = NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
        let line = TextLineView()
        line.attributedText = attributed
        window.addSubview(line)
        line.frame = line.frame(forAlignmentRect: CGRect(origin: CGPoint(x: 20, y: 40), size: line.intrinsicContentSize))

        // 字形の枠は、ベースラインを原点に上向きを正とする。
        let ink = CTLineGetImageBounds(CTLineCreateWithAttributedString(attributed), nil)
        let baseline = line.baselineOrigin.y
        #expect(baseline - ink.minY <= line.bounds.height, "字形の下端が\(baseline - ink.minY)pt、ビューの高さは\(line.bounds.height)pt")
    }

    /// 入力欄の「いまどうしてる？」のように上端で置いたとき、入力欄の1行目と同じく、上端からフォントのアセンダーの位置にベースラインが来る。
    @Test func topAlignedBaselineMatchesTextView() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        let font = UIFont.preferredFont(forTextStyle: .body)
        let line = TextLineView()
        line.attributedText = NSAttributedString(string: "いまどうしてる？", attributes: [.font: font])
        window.addSubview(line)
        window.isHidden = false
        defer { window.isHidden = true }
        line.frame = line.frame(forAlignmentRect: CGRect(origin: CGPoint(x: 20, y: 40), size: line.intrinsicContentSize))

        #expect(abs(line.baselineOrigin.y - font.ascender) < 0.01, "ベースラインは\(line.baselineOrigin.y)")
    }
}
