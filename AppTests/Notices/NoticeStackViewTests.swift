import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 知らせのチップの並べ方と、消えるまでの時計。決まりはdocs/notices.mdの「チップ」にある。
@MainActor
struct NoticeStackViewTests {
    /// - Parameter clock: 数秒で消えるチップの時計。消えるまでを確かめるテストは、手で進める。
    private func makeStack(clock: TestClock = TestClock()) -> NoticeStackView {
        let stack = NoticeStackView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        stack.animationDuration = 0
        stack.clock = clock
        return stack
    }

    private let progress = Notice(id: "download", kind: .progress, title: "ダウンロード中", value: "42%")
    private let saved = Notice(id: "saved", kind: .success, title: "写真に保存しました")

    /// 1枚だけなら、数秒で消えるチップでも上に詰める。
    @Test func singleChipSitsAtTop() throws {
        let stack = makeStack()
        stack.showTransient(saved, duration: 60)
        stack.layoutIfNeeded()

        let chip = try #require(stack.chips.first)
        #expect(chip.frame.minY == 0)
    }

    /// 高さは中身によらず、2行のチップ2枚分を取る。中身で変えると、置く側の並べ直しが動きの途中に入り、チップが上下に揺れるため。
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

    /// 1行に収まる文言は文言の幅にし、収まらない文言は列の幅いっぱいに広げて2行に折り返す。
    @Test func longTextWrapsToTwoLinesAtFullWidth() throws {
        let stack = makeStack()
        stack.showTransient(saved, duration: 60)
        stack.layoutIfNeeded()
        let oneLine = try #require(stack.chips.first).frame

        stack.showTransient(Notice(id: "long", kind: .info, title: "この投稿では「メンションされたユーザー」を使えません"), duration: 60)
        stack.layoutIfNeeded()
        let wrapped = try #require(stack.chips.first).frame

        #expect(oneLine.width < stack.bounds.width)
        #expect(wrapped.width == stack.bounds.width)
        #expect(wrapped.height > oneLine.height)
    }

    /// 2行にも収まらない文言は、3行目へ送らず2行目の末尾で切る。
    @Test func overflowingTextStaysAtTwoLines() throws {
        let stack = makeStack()
        stack.showTransient(Notice(id: "long", kind: .info, title: "この投稿では「メンションされたユーザー」を使えません"), duration: 60)
        stack.layoutIfNeeded()
        let twoLines = try #require(stack.chips.first).frame.height

        stack.showTransient(Notice(id: "long", kind: .info, title: String(repeating: "2行にも収まらないほど長い文言", count: 6)), duration: 60)
        stack.layoutIfNeeded()

        #expect(try #require(stack.chips.first).frame.height == twoLines)
    }

    /// 2行のチップを2枚並べても重ねず、取っておいた高さに収める。
    @Test func twoWrappedChipsStackWithinHeight() throws {
        let stack = makeStack()
        stack.setPersistent(Notice(id: "failed", kind: .failure, title: "代替テキストを送信できませんでした。押すと理由を確かめられます"))
        stack.showTransient(Notice(id: "long", kind: .info, title: "この投稿では「メンションされたユーザー」を使えません"), duration: 60)
        stack.layoutIfNeeded()

        let top = try #require(stack.chips.first)
        let bottom = try #require(stack.chips.last)
        #expect(bottom.frame.minY > top.frame.maxY)
        #expect(bottom.frame.maxY <= stack.intrinsicContentSize.height)
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

    /// ボタン類と一緒に隠している失敗は、同じ見た目のまま中身を替えても、押せないままにする。透明なチップがタップを受けないようにするため。
    @Test func hiddenFailureStaysUntouchableWhenRefreshed() throws {
        let stack = makeStack()
        let failure = Notice(id: "upload", kind: .failure, title: "アップロードできませんでした", action: .disclosure(hint: "", handler: {}))
        stack.setPersistent(failure)
        stack.setChromeHidden(true, animated: false)
        let chip = try #require(stack.chips.first)

        stack.setPersistent(failure)

        #expect(stack.chips.first === chip)
        #expect(chip.alpha == 0)
        #expect(!chip.isUserInteractionEnabled)
    }

    /// VoiceOverの「しまう」の操作で、スワイプしたときと同じくしまう。数秒で消えるものはそのまま消し、出たままのものは置く側に知らせる。
    @Test func dismissActionRemovesChips() throws {
        let stack = makeStack()
        var dismissed: [String] = []
        stack.onDismissPersistent = { dismissed.append($0.id) }
        stack.setPersistent(progress)
        stack.showTransient(saved, duration: 60)
        let persistent = try #require(stack.chips.first)
        let transient = try #require(stack.chips.last)

        #expect(try dismissAction(of: transient).actionHandler?(try dismissAction(of: transient)) == true)
        #expect(stack.transientNotice == nil)
        #expect(stack.persistentNotice?.id == "download")
        #expect(dismissed.isEmpty)

        #expect(try dismissAction(of: persistent).actionHandler?(try dismissAction(of: persistent)) == true)
        #expect(stack.persistentNotice == nil)
        #expect(dismissed == ["download"])
    }

    /// 上へずらしたところでしまっても、そこからさらに上へ外す。
    @Test func dismissingRaisedChipMovesItFurtherUp() throws {
        let stack = makeStack()
        stack.setPersistent(progress)
        stack.layoutIfNeeded()
        let chip = try #require(stack.chips.first)
        chip.transform = CGAffineTransform(translationX: 0, y: -80)

        #expect(try dismissAction(of: chip).actionHandler?(try dismissAction(of: chip)) == true)

        #expect(chip.transform.ty < -80)
    }

    private func dismissAction(of chip: NoticeChip) throws -> UIAccessibilityCustomAction {
        try #require(chip.accessibilityCustomActions?.first { $0.name == "しまう" })
    }

    /// 数秒で消えるチップは、新しいものが来たら同じチップで差し替え、時間が来たら消す。
    @Test func transientIsReplacedAndExpires() async throws {
        let clock = TestClock()
        let stack = makeStack(clock: clock)
        stack.showTransient(saved, duration: 60)
        let chip = try #require(stack.chips.first)

        stack.showTransient(Notice(id: "other", kind: .failure, title: "お気に入りにできませんでした"), duration: 0.1)

        #expect(stack.chips.first === chip)
        #expect(stack.transientNotice?.id == "other")
        // 入れ替えると、前のチップの時計は止め、入れ替えたチップの長さで数え直す。
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(99))
        // 進めただけでは、起きた処理はまだ走っていない。早く消さないことは、消すまでの待ちが残っていることで確かめる。
        #expect(clock.sleeperCount == 1, "長さより早く消そうとしました")
        clock.advance(by: .milliseconds(1))
        try await waitUntil { stack.transientNotice == nil }
    }

    /// 押せる数秒で消えるチップは、VoiceOverの読み上げ位置が乗っている間は消さない。
    @Test func actionableTransientWaitsWhileFocused() async throws {
        let clock = TestClock()
        let stack = makeStack(clock: clock)
        let failure = Notice(id: "favourite", kind: .failure, title: "お気に入りにできませんでした", action: .disclosure(hint: "理由を見られます。", handler: {}))
        stack.showTransient(failure, duration: 0.1)
        let chip = try #require(stack.chips.first)
        try await waitUntil { clock.sleeperCount == 1 }

        chip.accessibilityElementDidBecomeFocused()
        #expect(clock.sleeperCount == 0, "読み上げ位置が乗っても、時計を止めていません")
        clock.advance(by: .milliseconds(300))
        #expect(clock.sleeperCount == 0)
        #expect(stack.transientNotice?.id == "favourite")

        chip.accessibilityElementDidLoseFocus()
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(100))
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

    /// 押せないチップも、上へスワイプしてしまえるよう触れたものを受ける。押しても何も起きない。
    @Test func nonActionableChipReceivesTouchesForDismissing() throws {
        let stack = makeStack()
        stack.setPersistent(progress)
        stack.layoutIfNeeded()
        let chip = try #require(stack.chips.first)

        #expect(stack.hitTest(CGPoint(x: chip.frame.midX, y: chip.frame.midY), with: nil) === chip)
        #expect(!chip.accessibilityTraits.contains(.button))
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
