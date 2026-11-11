import Testing
import UIKit
@testable import Scia

/// UIKitのラベルの上にSwiftUIで描く、数字を入れ替える文字。
@MainActor
@Suite(.failureState)
struct NumericTextOverlayTests {
    /// 文字が短くなって数字を入れ替える間は、入れ替わる前の文字の幅を保つ。下のラベルは先に新しい幅になるので、
    /// そのままでは、入れ替わる途中の前の文字（「残り10秒」の「10」）が切り詰められるため。
    @Test func keepsOldWidthWhileShrinkingTextChanges() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        window.isHidden = false
        defer { window.isHidden = true }
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        ])
        let overlay = NumericTextOverlay(alignment: .leading)
        overlay.overlay(on: label)
        label.text = "10人・残り10秒"
        overlay.setText("10人・残り10秒", value: 10, animation: nil)
        container.layoutIfNeeded()
        let oldWidth = overlay.bounds.width

        label.text = "10人・残り9秒"
        overlay.setText("10人・残り9秒", value: 10, animation: (0.5, 0))
        container.layoutIfNeeded()
        overlay.startPendingTransition()
        container.layoutIfNeeded()

        #expect(label.bounds.width < oldWidth)
        #expect(overlay.bounds.width >= oldWidth, "入れ替わる途中で、前の文字の幅より狭めました")

        overlay.cancelTransition()
        container.layoutIfNeeded()
        #expect(overlay.bounds.width < oldWidth, "入れ替わりをやめたあとも、前の文字の幅のままです")
    }

    /// ふだんはラベルが文字を描き、数字を入れ替えている間だけ、ラベルの文字を透明にして重ねた文字に描かせる。
    /// スクロールで行の中身を当て直すたびにSwiftUIを描き直さないため。
    @Test func drawsWithLabelExceptWhileChanging() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let label = UILabel()
        container.addSubview(label)
        let overlay = NumericTextOverlay(alignment: .leading)
        overlay.overlay(on: label)
        overlay.setStyle(font: .preferredFont(forTextStyle: .footnote), color: .secondaryLabel)

        overlay.setText("3票", value: 3, animation: nil)
        #expect(!overlay.isTransitioning)
        #expect(label.text == "3票")
        #expect(label.textColor == .secondaryLabel)

        overlay.setText("4票", value: 4, animation: (0.5, 0))
        #expect(overlay.isTransitioning)
        #expect(label.text == "4票")
        #expect(label.textColor == .clear, "入れ替える間も、ラベルが新しい文字を描いています")

        overlay.cancelTransition()
        #expect(!overlay.isTransitioning)
        #expect(label.textColor == .secondaryLabel)
    }
}
