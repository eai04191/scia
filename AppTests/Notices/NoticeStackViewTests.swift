import Testing
import UIKit
@testable import Scia

/// 知らせのチップの並べ方と、消えるまでの時計。決まりはdocs/notices.mdの「チップ」にある。
@MainActor
struct NoticeStackViewTests {
    private func makeStack() -> NoticeStackView {
        let stack = NoticeStackView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        stack.animationDuration = 0
        return stack
    }

    private let progress = Notice(id: "download", kind: .progress, title: "ダウンロード中", value: "42%")
    private let saved = Notice(id: "saved", kind: .success, title: "写真に保存しました")

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("条件を満たさないまま時間切れになりました")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 1枚だけなら、数秒で消えるチップでも上に詰める。
    @Test func singleChipSitsAtTop() throws {
        let stack = makeStack()
        stack.showTransient(saved, duration: 60)
        stack.layoutIfNeeded()

        let chip = try #require(stack.chips.first)
        #expect(chip.frame.minY == 0)
    }

    /// 高さは中身によらず2枚分を取る。中身で変えると、置く側の並べ直しが動きの途中に入り、チップが上下に揺れるため。
    @Test func heightStaysForTwoChips() throws {
        let stack = makeStack()
        let empty = stack.intrinsicContentSize.height

        stack.setPersistent(progress)
        stack.showTransient(saved, duration: 60)
        stack.layoutIfNeeded()

        let bottom = try #require(stack.chips.last)
        #expect(stack.intrinsicContentSize.height == empty)
        #expect(bottom.frame.maxY <= empty)
    }

    /// 出たままのチップを上、数秒で消えるチップをその下に並べ、出たままのものが消えたら上に詰める。
    @Test func persistentAboveTransientAndCollapsesWhenRemoved() throws {
        let stack = makeStack()
        stack.setPersistent(progress)
        stack.showTransient(saved, duration: 60)
        stack.layoutIfNeeded()

        let top = try #require(stack.chips.first)
        let bottom = try #require(stack.chips.last)
        #expect(top.notice?.id == "download")
        #expect(bottom.notice?.id == "saved")
        #expect(top.frame.minY == 0)
        #expect(bottom.frame.minY > top.frame.maxY)

        stack.setPersistent(nil)
        stack.layoutIfNeeded()
        #expect(stack.chips.count == 1)
        #expect(bottom.frame.minY == 0)
    }

    /// 出たままのチップから数秒で消えるチップへは、同じチップのまま同じ場所で入れ替える。
    @Test func transientReplacesPersistentInPlace() throws {
        let stack = makeStack()
        stack.setPersistent(progress)
        stack.layoutIfNeeded()
        let chip = try #require(stack.chips.first)

        stack.showTransient(saved, duration: 60, replacingPersistent: "download")
        stack.layoutIfNeeded()

        #expect(stack.persistentNotice == nil)
        #expect(stack.chips.count == 1)
        #expect(stack.chips.first === chip)
        #expect(chip.notice?.text == "写真に保存しました")
        #expect(chip.frame.minY == 0)
    }

    /// 入れ替える出たままの知らせが別のものに替わっていれば、入れ替えずに下へ出す。
    @Test func replacingIgnoresOtherPersistentNotice() {
        let stack = makeStack()
        stack.setPersistent(progress)

        stack.showTransient(saved, duration: 60, replacingPersistent: "other")

        #expect(stack.persistentNotice?.id == "download")
        #expect(stack.transientNotice?.id == "saved")
    }

    /// ボタン類を隠したら、出たままの失敗だけを、場所を空けたまま薄くし、押せなくする。処理の途中と数秒で消えるものは残す。
    @Test func hidingChromeDimsOnlyPersistentFailure() throws {
        let stack = makeStack()
        let failure = Notice(id: "upload", kind: .failure, title: "アップロードできませんでした", action: .disclosure(hint: "", handler: {}))
        stack.setPersistent(failure)
        stack.showTransient(saved, duration: 60)
        stack.layoutIfNeeded()
        let top = try #require(stack.chips.first)
        let bottom = try #require(stack.chips.last)
        let bottomFrame = bottom.frame

        stack.setChromeHidden(true, animated: false)
        stack.layoutIfNeeded()
        #expect(top.alpha == 0)
        #expect(!top.isUserInteractionEnabled)
        #expect(bottom.alpha == 1)
        #expect(bottom.frame == bottomFrame)

        stack.setPersistent(progress)
        #expect(top.alpha == 1)

        stack.setChromeHidden(false, animated: false)
        stack.setPersistent(failure)
        #expect(top.alpha == 1)
        #expect(top.isUserInteractionEnabled)
    }

    /// 数秒で消えるチップは、新しいものが来たら同じチップで差し替え、時間が来たら消す。
    @Test func transientIsReplacedAndExpires() async throws {
        let stack = makeStack()
        stack.showTransient(saved, duration: 60)
        let chip = try #require(stack.chips.first)

        stack.showTransient(Notice(id: "other", kind: .failure, title: "お気に入りにできませんでした"), duration: 0.1)

        #expect(stack.chips.first === chip)
        #expect(stack.transientNotice?.id == "other")
        try await waitUntil { stack.transientNotice == nil }
    }

    /// 押せる数秒で消えるチップは、VoiceOverの読み上げ位置が乗っている間は消さない。
    @Test func actionableTransientWaitsWhileFocused() async throws {
        let stack = makeStack()
        let failure = Notice(id: "favourite", kind: .failure, title: "お気に入りにできませんでした", action: .disclosure(hint: "理由を見られます。", handler: {}))
        stack.showTransient(failure, duration: 0.1)
        let chip = try #require(stack.chips.first)

        chip.accessibilityElementDidBecomeFocused()
        try await Task.sleep(for: .milliseconds(300))
        #expect(stack.transientNotice?.id == "favourite")

        chip.accessibilityElementDidLoseFocus()
        try await waitUntil { stack.transientNotice == nil }
    }

    /// 押そうとしているチップは動かさず、その間に来たチップは重ならない場所に置く。離したら決まりの並びに戻す。
    @Test func newChipAvoidsHeldChip() throws {
        let stack = makeStack()
        let failure = Notice(id: "favourite", kind: .failure, title: "お気に入りにできませんでした", action: .disclosure(hint: "", handler: {}))
        stack.showTransient(failure, duration: 60)
        stack.layoutIfNeeded()
        let held = try #require(stack.chips.first)
        let heldFrame = held.frame
        held.accessibilityElementDidBecomeFocused()

        stack.setPersistent(progress)
        stack.layoutIfNeeded()

        let persistent = try #require(stack.chips.first)
        #expect(persistent !== held)
        #expect(held.frame == heldFrame)
        #expect(!persistent.frame.intersects(held.frame))

        held.accessibilityElementDidLoseFocus()
        stack.layoutIfNeeded()
        #expect(persistent.frame.minY == 0)
        #expect(held.frame.minY > persistent.frame.maxY)
    }

    /// 押せるチップは、見た目が44ptに満たなくても44pt四方まで押せ、チップのない所は下の画面へ通す。
    @Test func actionableChipHasMinimumHitArea() throws {
        let stack = makeStack()
        stack.setPersistent(Notice(id: "download", kind: .progress, title: "ダウンロード中", action: .disclosure(hint: "", handler: {})))
        stack.layoutIfNeeded()
        let chip = try #require(stack.chips.first)
        #expect(chip.bounds.height < NoticeChip.minimumHitSize)

        let justAbove = CGPoint(x: chip.frame.midX, y: chip.frame.minY - 1)
        #expect(stack.hitTest(justAbove, with: nil) === chip)
        #expect(stack.hitTest(CGPoint(x: 2, y: 150), with: nil) == nil)
    }

    /// 押せないチップは触れても下の画面へ通す。
    @Test func nonActionableChipPassesTouchesThrough() throws {
        let stack = makeStack()
        stack.setPersistent(progress)
        stack.layoutIfNeeded()
        let chip = try #require(stack.chips.first)

        #expect(stack.hitTest(CGPoint(x: chip.frame.midX, y: chip.frame.midY), with: nil) == nil)
    }

    /// VoiceOverでは「›」を読ませず、件数と、押すと何が起きるかを伝える。
    @Test func accessibilityDescribesCountAndAction() throws {
        let stack = makeStack()
        var notice = Notice(id: "download", kind: .progress, title: "ダウンロード中", value: "42%", action: .disclosure(hint: "ダウンロードを止めるか選べます。", handler: {}))
        notice.additionalCount = 1
        stack.setPersistent(notice)
        let chip = try #require(stack.chips.first)

        #expect(chip.accessibilityLabel == "ダウンロード中、ほかに1件")
        #expect(chip.accessibilityValue == "42%")
        #expect(chip.accessibilityHint == "ダウンロードを止めるか選べます。")
        #expect(chip.accessibilityTraits.contains(.button))
    }
}
