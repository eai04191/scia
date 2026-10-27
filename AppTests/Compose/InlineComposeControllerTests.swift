import PhotosUI
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄を実際のウィンドウに載せ、開閉や返信先の付け替えで行が崩れないことを確かめる。
@MainActor
@Suite(.scratch, .serialized)
struct InlineComposeControllerTests {
    private let window: UIWindow
    private let composer: InlineComposeController
    private let settings: AppSettings
    private let tuning = TuningStore(defaults: nil)
    /// ウィンドウの中の動きの時間。実際の時間では進まず、テストが進めた分だけ進む。
    private let clock: LayerClock

    init() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "テストのホストアプリにウィンドウシーンがありません"
        )
        let tabBarController = UITabBarController(tabs: [UITab(title: "ホーム", image: nil, identifier: "home") { _ in UIViewController() }])
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = tabBarController
        window.makeKeyAndVisible()
        let defaults = TestScratch.defaults("InlineComposeControllerTests")
        settings = AppSettings(defaults: defaults)
        // 動きの終わりを待つだけのテストが、実際の長さの動きを待たずに済むよう、形を変える動きを短くする。
        // 動きの途中で状態を見るテストや次の操作を送るテストは、間合いをアプリの既定の長さに合わせて決めているので、useDefaultAnimationDurations()で戻す。
        tuning.setValue(0.05, for: TuningCatalog.composeMorphDuration)
        tuning.setValue(0.05, for: TuningCatalog.composeExpandDuration)
        composer = InlineComposeController(model: ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }, tuning: tuning, settings: settings)
        composer.install(in: tabBarController)
        window.layoutIfNeeded()
        clock = LayerClock(freezing: window.layer)
    }

    private func status(id: String) throws -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "",
            spoilerText: "",
            url: nil
        )
    }

    /// 開閉のアニメーションの途中で、返信先の変更が反映されても、返信先のラベルの行と入力欄が重ならない。
    @Test func replyRowKeepsItsSpaceAcrossRepeatedReplies() async throws {
        defer { window.isHidden = true }
        for round in 0..<4 {
            composer.reply(to: try status(id: "\(10 + round)"))
            try await waitUntilSettled()
            window.layoutIfNeeded()
            #expect(composer.overlappingRows.isEmpty, "\(round)回目に返信を始めたとき、行が重なりました\n\(composer.stateDump())")

            composer.endEditing()
            try await waitUntilSettled()
            window.layoutIfNeeded()
            #expect(composer.overlappingRows.isEmpty, "\(round)回目に閉じたとき、行が重なりました\n\(composer.stateDump())")
        }
    }

    /// 書いている途中で別の投稿へ返信し直したり、閉じる途中やラベルを外した直後に返信を始めたりしても、行が重ならない。
    /// 待ち時間を変えて、アニメーションのいろいろな途中に次の操作を送る。
    @Test(arguments: [0, 30, 120, 250])
    func replyRowKeepsItsSpaceWhenInterrupted(waitMilliseconds: Int) async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        let wait = TimeInterval(waitMilliseconds) / 1000
        composer.reply(to: try status(id: "10"))
        try await clock.advance(by: wait)
        composer.reply(to: try status(id: "11"))
        try await clock.advance(by: wait)
        composer.endEditing()
        try await clock.advance(by: wait)
        composer.reply(to: try status(id: "12"))
        try await clock.advance(by: wait)
        composer.model.setReplyTarget(nil)
        try await clock.advance(by: wait)
        composer.reply(to: try status(id: "13"))
        try await waitUntilSettled()
        window.layoutIfNeeded()

        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// 投稿へ返信したあと、同じ投稿のブーストを返信に選び直しても、ラベルが縮まず宛先の文字を収める。
    @Test func replyChipKeepsWidthWhenReselectingBoostOfSameStatus() async throws {
        defer { window.isHidden = true }
        let original = try status(id: "10")
        let booster = Account(id: "3", username: "carol", acct: "carol", displayName: "Carol", avatar: URL(string: "https://example.social/c.png"))
        let boost = Status(id: "20", createdAt: Date(timeIntervalSince1970: 0), account: booster, content: "", spoilerText: "", url: nil, reblog: original)

        composer.reply(to: original)
        try await waitUntilSettled()
        composer.reply(to: boost)
        try await waitUntilSettled()
        window.layoutIfNeeded()

        let button = try #require(buttons(in: window).first { $0.configuration?.title?.hasSuffix("への返信") == true })
        #expect(button.configuration?.title == "@bobへの返信")
        expectChipFitsTitle(button)
    }

    /// ラベルを外すと、行は薄くなりながら縮み、外し終えたら隠れる。消えていく途中もラベルの文字は残る。
    @Test func clearingReplyFadesOutRow() async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        composer.reply(to: try status(id: "10"))
        try await waitUntilSettled()
        let button = try #require(buttons(in: window).first { $0.configuration?.title?.hasSuffix("への返信") == true })

        composer.model.setReplyTarget(nil)
        try await clock.advance(by: 0.08)
        let presentation = try #require(button.superview?.layer.presentation())
        #expect(presentation.opacity > 0 && presentation.opacity < 1, "ラベルがパッと消えました: opacity=\(presentation.opacity)")
        #expect(button.configuration?.title?.hasSuffix("への返信") == true, "消えていく途中でラベルの文字が消えました")

        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(button.superview?.isHidden == true)
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// ラベルが消えていく途中に別の投稿の返信を選んでも、ラベルは出たままで崩れない。
    @Test func replyingWhileReplyRowFadesOut() async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        composer.reply(to: try status(id: "10"))
        try await waitUntilSettled()

        composer.model.setReplyTarget(nil)
        try await clock.advance(by: 0.10)
        composer.reply(to: try status(id: "11"))
        try await waitUntilSettled()
        window.layoutIfNeeded()

        let button = try #require(buttons(in: window).first { $0.configuration?.title?.hasSuffix("への返信") == true })
        let row = try #require(button.superview)
        #expect(!row.isHidden && row.alpha == 1, "ラベルが出ていません: hidden=\(row.isHidden) alpha=\(row.alpha)")
        expectChipFitsTitle(button)
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// ラベルの文字が省略も切り取りもされずに収まっている。UILabelが本来の幅を確保し、ボタンがその文字を囲んでいる。
    /// 添付の長押しでメニューを出すと、iOSがソフトウェアキーボードを隠す。その間もバーを今の位置に留め、キーボードが戻ったら外す。
    @Test func contextMenuHoldsBarUntilKeyboardReturns() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        postKeyboardFrame(height: 336)

        showContextMenu()
        #expect(composer.isBarHeld, "メニューを出しても、バーを留めていません\n\(composer.stateDump())")
        postKeyboardFrame(height: 0)
        endContextMenu()
        #expect(composer.isBarHeld, "キーボードが戻る前に、バーを外しました\n\(composer.stateDump())")
        postKeyboardFrame(height: 336)
        #expect(!composer.isBarHeld, "キーボードが戻っても、バーを留めたままです\n\(composer.stateDump())")
    }

    /// メディアを選ぶシートを閉じたあとは、メニューを出すとすぐ、iOSが高さの変わらないキーボードの枠を知らせてくる。
    /// それをキーボードが戻ったと受け取ると、メニューを出したとたんにバーを外し、隠れるキーボードについて下げてしまう。
    @Test func contextMenuKeepsBarHeldWhenKeyboardFrameRepeats() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        postKeyboardFrame(height: 336)

        showContextMenu()
        postKeyboardFrame(height: 336)
        #expect(composer.isBarHeld, "キーボードが隠れる前に、バーを外しました\n\(composer.stateDump())")
    }

    /// メニューの間にキーボードが隠れても、知らせが届かないことがある。閉じ始めたときにキーボードがまだ隠れていれば、バーを外さない。
    /// 外すと、バーがキーボードに沿う枠について一度下がり、押した画像が上から下りてくるように戻る。
    @Test func contextMenuKeepsBarHeldWhenKeyboardHidWithoutNotification() async throws {
        defer { window.isHidden = true }
        var guideHeight: CGFloat = 336
        composer.measureKeyboardGuideHeight = { _ in guideHeight }
        composer.beginEditing()
        try await waitUntilSettled()
        postKeyboardFrame(height: 336)

        showContextMenu()
        guideHeight = 34
        endContextMenu()
        #expect(composer.isBarHeld, "キーボードが隠れたまま、バーを外しました\n\(composer.stateDump())")
        guideHeight = 336
        postKeyboardFrame(height: 336)
        #expect(!composer.isBarHeld, "キーボードが戻っても、バーを留めたままです\n\(composer.stateDump())")
    }

    /// ハードウェアキーボードのようにキーボードが隠れなければ、メニューを閉じた時点でバーを外す。
    @Test func contextMenuReleasesBarWhenKeyboardStayed() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        postKeyboardFrame(height: 336)

        showContextMenu()
        endContextMenu()
        #expect(!composer.isBarHeld, "メニューを閉じても、バーを留めたままです\n\(composer.stateDump())")
    }

    /// 大きさのないキーボードの枠が届いても、画面の上端までキーボードが上がったとは受け取らない。
    /// 受け取ると、メディアを選ぶシートを画面の高さで出し、バーを画面の外に留めてしまう。
    @Test func emptyKeyboardFrameIsNotRememberedAsKeyboardHeight() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect.zero])
        #expect(composer.stateDump().contains("lastKeyboardHeight: nil"), "大きさのない枠を、キーボードの高さとして覚えました\n\(composer.stateDump())")
    }

    /// ハードウェアキーボードではキーボードが上がらず、上がりきった知らせも来ない。メディアを選ぶシートを閉じて入力欄に戻ったら、
    /// その時点でバーをシートの上端から外し、入力欄に付ける。
    @Test func closingMediaPickerWithoutSoftwareKeyboardReleasesBar() async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        composer.model.apply(configuration: InstanceConfiguration(streamingURL: try #require(URL(string: "wss://example.social")), maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown), defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        postKeyboardFrame(height: 0)
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let mediaButton = try #require(buttons(in: window).first { $0.accessibilityLabel == ComposeToolItem.media.title })

        mediaButton.sendActions(for: .primaryActionTriggered)
        try await clock.advance { window.rootViewController?.presentedViewController is PHPickerViewController }
        #expect(window.rootViewController?.presentedViewController is PHPickerViewController, "シートが表示されませんでした: \(String(describing: window.rootViewController?.presentedViewController))")
        #expect(composer.stateDump().contains("mediaPicker: shown"), "シートが開きませんでした\n\(composer.stateDump())")
        #expect(composer.isBarHeld, "シートを開いても、バーを留めていません\n\(composer.stateDump())")

        mediaButton.sendActions(for: .primaryActionTriggered)
        try await clock.advance { composer.stateDump().contains("mediaPicker: nil") }
        #expect(composer.stateDump().contains("mediaPicker: nil"), "シートが閉じませんでした\n\(composer.stateDump())")
        #expect(composer.stateDump().contains("editing: true"), "シートを閉じると書き終えたことになりました\n\(composer.stateDump())")
        #expect(!composer.isBarHeld, "キーボードが上がらないのに、バーをシートの上端に留めたままです\n\(composer.stateDump())")
    }

    /// 入力欄の中でスクロールするほど書いてから行を消して収まる長さに戻すと、入力欄は書いた行の高さまで縮み、潰れない。
    @Test(arguments: [5, 6])
    func textViewKeepsHeightWhenShrinkingBelowScrollLimit(lines: Int) async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        composer.model.text = (1...lines).map { "\($0)" }.joined(separator: "\n")
        try await waitUntilSettled()
        window.layoutIfNeeded()

        composer.model.text = (1...4).map { "\($0)" }.joined(separator: "\n")
        try await waitUntilSettled()
        window.layoutIfNeeded()

        let textView = try #require(textViews(in: window).first)
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        #expect(textView.bounds.height >= fitting - 0.5, "入力欄が4行の高さより縮みました: \(textView.bounds.height) / \(fitting)\n\(composer.stateDump())")
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// 注意書きの欄を出す途中で外したり、外す途中で出し直したりしても、行が重ならず、最後の状態で止まる。
    /// 待ち時間を変えて、アニメーションのいろいろな途中に次の操作を送る。
    @Test(arguments: [0, 30, 120, 250])
    func spoilerRowKeepsItsSpaceWhenToggledDuringAnimation(waitMilliseconds: Int) async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        let wait = TimeInterval(waitMilliseconds) / 1000
        composer.beginEditing()
        try await waitUntilSettled()
        for shows in [true, false, true, false, true] {
            composer.model.showsSpoiler = shows
            try await clock.advance(by: wait)
        }
        try await waitUntilSettled()
        window.layoutIfNeeded()

        let row = try #require(textFields(in: window).first?.superview?.superview)
        #expect(!row.isHidden && row.alpha == 1, "注意書きの欄が出ていません: hidden=\(row.isHidden) alpha=\(row.alpha)")
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// 本文と注意書きの間でキーボードを移しても、書き終えたことにならず、欄はカプセルに戻らない。
    @Test func movingFocusBetweenSpoilerAndTextKeepsEditing() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        composer.model.showsSpoiler = true
        try await waitUntilSettled()
        let field = try #require(textFields(in: window).first)
        let textView = try #require(textViews(in: window).first)
        #expect(textView.isFirstResponder)

        field.becomeFirstResponder()
        try await waitUntilSettled()
        #expect(field.isFirstResponder)
        #expect(composer.stateDump().contains("editing: true"), "注意書きへ移ると、書き終えたことになりました\n\(composer.stateDump())")

        textView.becomeFirstResponder()
        try await waitUntilSettled()
        #expect(textView.isFirstResponder)
        #expect(composer.stateDump().contains("editing: true"), "本文へ戻ると、書き終えたことになりました\n\(composer.stateDump())")

        composer.endEditing()
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("editing: false"), "閉じても書いている状態のままです\n\(composer.stateDump())")
    }

    /// 書いている途中にコントロールセンターを開くなどで、iOSが入力欄のフォーカスを外してから戻しても、投稿欄は広げたままにする。
    /// フォーカスが戻ったのに細いカプセルのままだと、隠れた入力欄に文字が入り続ける。
    @Test func focusRestoredBySystemResumesEditing() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        #expect(textView.isFirstResponder)

        textView.resignFirstResponder()
        try await clock.advance(by: 0.10)
        textView.becomeFirstResponder()
        try await waitUntilSettled()
        window.layoutIfNeeded()

        #expect(textView.isFirstResponder)
        #expect(composer.stateDump().contains("editing: true"), "フォーカスが戻ったのに、投稿欄が閉じたままです\n\(composer.stateDump())")
        #expect(!textView.isHidden, "フォーカスが戻ったのに、入力欄が隠れたままです")
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// 注意書き付きの投稿への返信で、引き継いだ注意書きの欄にキーボードを出したまま返信をやめると、欄が隠れ、キーボードは本文に移る。
    /// 隠れた欄にキーボードが残ると、打った文字が投稿されない注意書きに入ってしまう。
    @Test func clearingReplyWithInheritedSpoilerMovesFocusToText() async throws {
        defer { window.isHidden = true }
        let target = Status(
            id: "10",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "",
            spoilerText: "ネタバレ",
            url: nil
        )
        composer.reply(to: target)
        try await waitUntilSettled()
        let field = try #require(textFields(in: window).first)
        let textView = try #require(textViews(in: window).first)
        #expect(field.text == "ネタバレ")
        field.becomeFirstResponder()
        try await waitUntilSettled()

        composer.model.setReplyTarget(nil)
        try await waitUntilSettled()
        #expect(!composer.model.showsSpoiler)
        #expect(!field.isFirstResponder, "隠れた注意書きの欄にキーボードが残っています\n\(composer.stateDump())")
        #expect(textView.isFirstResponder)
        #expect(composer.stateDump().contains("editing: true"), "返信をやめると書き終えたことになりました\n\(composer.stateDump())")
    }

    /// 書いている間に設定で並びを変えると、すぐにボタンの行と＋が並びに合う。行の中のボタンが重ならない。
    @Test func toolButtonsFollowLayoutChangedWhileEditing() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        let add = try #require(buttons(in: window).first { $0.accessibilityLabel == "追加" })
        let media = try #require(buttons(in: window).first { $0.accessibilityLabel == "メディアを添付" })
        let spoiler = try #require(buttons(in: window).first { $0.accessibilityLabel == "注意書き" })
        expectShown([add, media], hidden: [spoiler])

        // カスタマイズ、リンクにタイトルを付ける、予約、言語、メンション、ハッシュタグは、並びに書かなければ既定どおり差し込まれるので、隠して＋を空にする。
        settings.composeToolLayout = MenuLayout(elements: [.item(.customize, isVisible: false), .item(.linkTitle, isVisible: false), .item(.schedule, isVisible: false), .item(.language, isVisible: false), .item(.mention, isVisible: false), .item(.hashtag, isVisible: false), .more, .item(.visibility, isVisible: true), .item(.media, isVisible: true), .item(.expand, isVisible: true), .item(.spoiler, isVisible: true)])
        try await waitUntilSettled()
        window.layoutIfNeeded()
        expectShown([media, spoiler], hidden: [add])

        settings.composeToolLayout = ComposeToolItem.defaultLayout
        try await waitUntilSettled()
        window.layoutIfNeeded()
        expectShown([add, media], hidden: [spoiler])
    }

    /// 公開範囲と展開も、＋の中に入れれば行から隠れる。
    @Test func visibilityAndExpandMoveIntoMenu() async throws {
        defer { window.isHidden = true }
        settings.composeToolLayout = MenuLayout(elements: [.item(.visibility, isVisible: true), .item(.expand, isVisible: true), .item(.spoiler, isVisible: true), .more, .item(.media, isVisible: true)])
        composer.beginEditing()
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let add = try #require(buttons(in: window).first { $0.accessibilityLabel == "追加" })
        let media = try #require(buttons(in: window).first { $0.accessibilityLabel == "メディアを添付" })
        let visibility = try #require(buttons(in: window).first { $0.accessibilityLabel == "公開範囲" })
        let expand = try #require(buttons(in: window).first { $0.accessibilityLabel == "広げて書く" })
        expectShown([add, media], hidden: [visibility, expand])
    }

    /// すべての項目を非表示にして書き始めると、項目のボタンも＋も出さない。
    @Test func hidesEverythingWhenAllItemsHidden() async throws {
        defer { window.isHidden = true }
        settings.composeToolLayout = MenuLayout(elements: ComposeToolItem.allCases.map { .item($0, isVisible: false) } + [.more])
        composer.beginEditing()
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let labels = ["追加", "公開範囲", "メディアを添付", "広げて書く", "注意書き"]
        let hidden = try labels.map { label in try #require(buttons(in: window).first { $0.accessibilityLabel == label }) }
        expectShown([], hidden: hidden)
    }

    /// 書いている途中にカスタマイズを開いても書いている状態のままで、閉じたらキーボードが本文に戻る。
    @Test func customizeKeepsEditingAndReturnsKeyboard() async throws {
        defer { window.isHidden = true }
        settings.composeToolLayout = MenuLayout(elements: [.more, .item(.customize, isVisible: true)])
        composer.beginEditing()
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let customize = try #require(buttons(in: window).first { $0.accessibilityLabel == "カスタマイズ" })
        customize.sendActions(for: .primaryActionTriggered)
        try await waitUntilSettled()
        let sheet = try #require(window.rootViewController?.presentedViewController as? ComposeToolLayoutSheet)
        #expect(composer.stateDump().contains("editing: true"), "開くと書き終えたことになりました\n\(composer.stateDump())")

        sheet.dismiss(animated: true)
        let textView = try #require(textViews(in: window).first)
        try await clock.advance { textView.isFirstResponder }
        #expect(textView.isFirstResponder, "閉じてもキーボードが戻りません\n\(composer.stateDump())")
    }

    /// ほかの画面が閉じていく途中にカスタマイズを押すと、その瞬間は画面を重ねられないので何もしない。
    /// 開いた扱いだけが残ると、以後キーボードを閉じても欄がカプセルに戻らなくなる。
    @Test func customizeWhileAnotherSheetClosingDoesNothing() async throws {
        defer { window.isHidden = true }
        settings.composeToolLayout = MenuLayout(elements: [.more, .item(.customize, isVisible: true)])
        composer.beginEditing()
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let host = try #require(window.rootViewController)
        try await host.presentForTesting(UIViewController(), advancing: clock)
        host.dismiss(animated: true)

        let customize = try #require(buttons(in: window).first { $0.accessibilityLabel == "カスタマイズ" })
        customize.sendActions(for: .primaryActionTriggered)
        try await waitUntilSettled()
        #expect(!(host.presentedViewController is ComposeToolLayoutSheet))

        composer.endEditing()
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("editing: false"), "キーボードを閉じても書いている状態のままです\n\(composer.stateDump())")
    }

    private func expectShown(_ shown: [UIButton], hidden: [UIButton], sourceLocation: SourceLocation = #_sourceLocation) {
        for button in shown {
            let row = (button.superview as? UIStackView)?.arrangedSubviews.map { "\(type(of: $0)) \($0.accessibilityLabel ?? "") hidden=\($0.isHidden) frame=\($0.frame) constraints=\($0.constraints.map(\.description))" }.joined(separator: "\n") ?? ""
            #expect(!button.isHidden && button.bounds.width > 0, "\(button.accessibilityLabel ?? "")のボタンが出ていません: frame=\(button.frame)\n\(row)", sourceLocation: sourceLocation)
        }
        for button in hidden {
            #expect(button.isHidden, "\(button.accessibilityLabel ?? "")のボタンが隠れていません\n\(composer.stateDump())", sourceLocation: sourceLocation)
        }
        let frames = shown.map(\.frame).sorted { $0.minX < $1.minX }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(left.maxX <= right.minX + 0.5, "ボタンが重なっています: \(left) / \(right)", sourceLocation: sourceLocation)
        }
    }

    /// 本文から送っても注意書きから送っても、送っている間はキーボードと書いている状態を保ち、打った文字は受け付けない。
    /// 成功したら、いまどおり書き終えてカプセルに戻る。
    @Test(arguments: [false, true])
    func postingKeepsEditingUntilPosted(fromSpoiler: Bool) async throws {
        defer { window.isHidden = true }
        let gate = PostGate()
        let composer = try installComposer { _ in await gate.wait() }
        composer.model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        composer.model.showsSpoiler = true
        try await waitUntilSettled()
        let field = try #require(textFields(in: window).first)
        let textView = try #require(textViews(in: window).first)
        let input: UIResponder = fromSpoiler ? field : textView
        input.becomeFirstResponder()
        composer.model.text = "本文"
        composer.model.spoilerText = "注意書き"
        try await waitUntilSettled()

        let posting = Task { await composer.model.submit() }
        try await waitUntilSettled()
        #expect(composer.model.isPosting)
        #expect(input.isFirstResponder, "送っている間にキーボードが外れました\n\(composer.stateDump())")
        #expect(composer.stateDump().contains("editing: true"), "送っている間に書き終えたことになりました\n\(composer.stateDump())")
        #expect(textView.delegate?.textView?(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "あ") == false)
        #expect(field.delegate?.textField?(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "あ") == false)

        gate.open()
        await posting.value
        try await waitUntilSettled()
        #expect(!input.isFirstResponder)
        #expect(composer.stateDump().contains("editing: false"), "投稿したのに書いている状態のままです\n\(composer.stateDump())")
    }

    /// 送信に失敗して知らせを出している間も、書き終えたことにせず、バーをキーボードの高さに留めて広げた欄を保つ。
    /// 知らせを閉じたあとにキーボードが戻ることは、知らせのボタンを押せないためシミュレーターで確かめる。
    @Test func failedPostKeepsEditingWhileShowingError() async throws {
        defer { window.isHidden = true }
        struct Failure: Error {}
        // 書き始めたときに届く端末の本物のキーボードの知らせは、負荷が高いと送った知らせより後に届き、ソフトウェアキーボードが上がっていないことになるので、送った知らせだけを受けさせる。
        let keyboard = NotificationCenter()
        let composer = try installComposer(keyboardNotifications: keyboard) { _ in throw Failure() }
        composer.model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        composer.model.text = "本文"
        postKeyboardFrame(height: 300, to: keyboard)

        await composer.model.submit()
        // ウィンドウ全体の動きが止まるのを待つと、アラートの中の多数の部品の動きとバーの動きの合計を待つことになり、負荷が高いと時間切れになる。
        // 確かめる状態は知らせを出し終えるまでに決まるので、出し終えるのを待つ。
        try await clock.advance {
            guard let alert = window.rootViewController?.presentedViewController as? UIAlertController else { return false }
            return !alert.isBeingPresented
        }
        // 知らせが最初の応答者になり、ソフトウェアキーボードが下がった知らせ。
        postKeyboardFrame(height: 0, to: keyboard)
        #expect(composer.stateDump().contains("editing: true"), "失敗の知らせを出すと書き終えたことになりました\n\(composer.stateDump())")
        #expect(composer.isBarHeld, "失敗の知らせを出すとバーがキーボードの高さから外れました\n\(composer.stateDump())")
        window.rootViewController?.dismiss(animated: false)
    }

    /// 送っている間に添付のビューアを開いたまま投稿できたら、ビューアを閉じるのを待たずに書き終え、空になった本文にキーボードを戻さない。
    @Test func postingWhileViewerIsOpenEndsEditing() async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        let gate = PostGate()
        let media = ComposeMediaService(
            upload: { upload in MediaAttachment(id: "m-\(upload.filename)", type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            waitUntilProcessed: { id in MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            updateDescription: { id, _ in MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            makeThumbnail: { _ in nil },
            unprocessableImageTypes: { [] },
            recordUnprocessableImageType: { _ in },
            preparation: { .keepsOriginal }
        )
        let composer = try installComposer(media: media) { _ in await gate.wait() }
        composer.model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        composer.model.applyPickerSelection([try pickedImage()])
        composer.model.text = "本文"
        try await waitUntil { composer.model.canPost }
        try await waitUntilSettled()
        let id = try #require(composer.model.attachments.first?.id)
        let strip = try #require(attachmentStrips(in: window).first)

        let posting = Task { await composer.model.submit() }
        try await waitUntilSettled()
        strip.onSelect(id)
        try await waitUntilSettled()
        #expect(window.rootViewController?.presentedViewController != nil, "添付のビューアが開きませんでした")

        gate.open()
        await posting.value
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("editing: false"), "ビューアを開いたまま投稿すると、書いている状態のままです\n\(composer.stateDump())")
        #expect(!composer.isBarHeld, "ビューアを開いたまま投稿すると、バーがキーボードの高さに留まったままです\n\(composer.stateDump())")
    }

    /// ソフトウェアキーボードで開いたビューアを閉じるまでにハードウェアキーボードに替わると、キーボードは上がらず、上がりきった知らせも来ない。
    /// 閉じて入力欄に戻したあとに届いたキーボードの高さがソフトウェアキーボードのものでなければ、その時点でバーをキーボードの高さから外す。
    /// ソフトウェアキーボードが上がってくるなら、上がりきるまで留めたままにする。知らせが届く前に別の添付を開き直したら、開き直したビューアの間は留めたままにする。
    @Test(arguments: [ViewerCloseFollowUp.softwareKeyboard, .hardwareKeyboard, .reopenBeforeKeyboard])
    func closingViewerReleasesBarOnlyWithoutSoftwareKeyboard(followUp: ViewerCloseFollowUp) async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        let media = ComposeMediaService(
            upload: { upload in MediaAttachment(id: "m-\(upload.filename)", type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            waitUntilProcessed: { id in MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            updateDescription: { id, _ in MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            makeThumbnail: { _ in nil },
            unprocessableImageTypes: { [] },
            recordUnprocessableImageType: { _ in },
            preparation: { .keepsOriginal }
        )
        // 入力欄に戻したときに届く端末の本物のキーボードの知らせが混ざると、どちらの場合かが端末の設定と間合いで変わるので、送った知らせだけを受けさせる。
        let keyboard = NotificationCenter()
        let composer = try installComposer(media: media, keyboardNotifications: keyboard) { _ in }
        composer.model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        composer.model.applyPickerSelection([try pickedImage()])
        try await waitUntilSettled()
        postKeyboardFrame(height: 300, to: keyboard)
        let id = try #require(composer.model.attachments.first?.id)
        let strip = try #require(attachmentStrips(in: window).first)

        strip.onSelect(id)
        try await waitUntilSettled()
        let viewer = try #require(window.rootViewController?.presentedViewController as? MediaViewerController, "添付のビューアが開きませんでした")
        #expect(composer.isBarHeld, "ビューアを開いても、バーをキーボードの高さに留めていません\n\(composer.stateDump())")
        postKeyboardFrame(height: 0, to: keyboard)

        viewer.close()
        try await clock.advance { composer.stateDump().contains("mediaViewer: nil") }
        #expect(composer.stateDump().contains("mediaViewer: nil"), "ビューアが閉じませんでした\n\(composer.stateDump())")
        #expect(composer.stateDump().contains("editing: true"), "ビューアを閉じると書き終えたことになりました\n\(composer.stateDump())")
        #expect(composer.isBarHeld, "キーボードの知らせが届く前に、バーを外しました\n\(composer.stateDump())")

        // 入力欄に戻したあとに、どちらのキーボードかが分かる高さの知らせが届く。
        switch followUp {
        case .softwareKeyboard:
            postKeyboardFrame(height: 300, to: keyboard)
            #expect(composer.isBarHeld, "ソフトウェアキーボードが上がりきる前に、バーを外しました\n\(composer.stateDump())")
        case .hardwareKeyboard:
            postKeyboardFrame(height: 0, to: keyboard)
            #expect(!composer.isBarHeld, "キーボードが上がらないのに、バーをキーボードの高さに留めたままです\n\(composer.stateDump())")
        case .reopenBeforeKeyboard:
            strip.onSelect(id)
            try await waitUntilSettled()
            #expect(window.rootViewController?.presentedViewController is MediaViewerController, "添付のビューアを開き直せませんでした")
            // 開き直すときに入力欄を閉じた知らせ。
            postKeyboardFrame(height: 0, to: keyboard)
            #expect(composer.isBarHeld, "開き直したビューアを出している間に、バーを外しました\n\(composer.stateDump())")
        }
    }

    enum ViewerCloseFollowUp: CustomTestStringConvertible {
        /// ソフトウェアキーボードが上がってくる。
        case softwareKeyboard
        /// 開いている間にハードウェアキーボードに替わり、キーボードが上がらない。
        case hardwareKeyboard
        /// キーボードの知らせが届く前に、別の添付を開き直す。
        case reopenBeforeKeyboard

        var testDescription: String {
            switch self {
            case .softwareKeyboard: "ソフトウェアキーボードが上がる"
            case .hardwareKeyboard: "ハードウェアキーボードに替わった"
            case .reopenBeforeKeyboard: "知らせの前に開き直す"
            }
        }
    }

    /// 送信を待たせるComposeModelで投稿欄を置き直す。
    private func installComposer(media: ComposeMediaService = .unavailable, keyboardNotifications: NotificationCenter = .default, post: @escaping (StatusDraft) async throws -> Void) throws -> InlineComposeController {
        let tabBarController = UITabBarController(tabs: [UITab(title: "ホーム", image: nil, identifier: "home") { _ in UIViewController() }])
        window.rootViewController = tabBarController
        let composer = InlineComposeController(model: ComposeModel(tasks: TaskScope(), myAccountID: "1", media: media, post: post), tuning: tuning, settings: settings, keyboardNotifications: keyboardNotifications)
        composer.install(in: tabBarController)
        window.layoutIfNeeded()
        return composer
    }

    private func pickedImage() throws -> PickedMedia {
        let folder = TestScratch.url("InlineComposeControllerTests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "a.jpg")
        // 送る前に大きさを読むので、読める画像にする。
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        } as Data?).write(to: url)
        return PickedMedia(assetIdentifier: "a") { _ in LocalMediaFile(url: url, mimeType: "image/jpeg", kind: .image) }
    }

    private func attachmentStrips(in view: UIView) -> [ComposeAttachmentStrip] {
        (view as? ComposeAttachmentStrip).map { [$0] } ?? view.subviews.flatMap(attachmentStrips(in:))
    }

    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(textFields(in:))
    }

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    private func showContextMenu() {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        composer.attachmentStrip.collectionView(collectionView, willDisplayContextMenu: UIContextMenuConfiguration(), animator: nil)
    }

    private func endContextMenu() {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        composer.attachmentStrip.collectionView(collectionView, willEndContextMenuInteraction: UIContextMenuConfiguration(), animator: nil)
    }

    /// 画面の下端から`height`だけキーボードが上がった、という知らせを送る。0なら隠れた。
    private func postKeyboardFrame(height: CGFloat, to center: NotificationCenter = .default) {
        let frame = CGRect(x: 0, y: window.bounds.maxY - height, width: window.bounds.width, height: height)
        center.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
    }

    private func expectChipFitsTitle(_ button: UIButton, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let label = button.titleLabel else {
            Issue.record("ラベルのボタンにUILabelがありません", sourceLocation: sourceLocation)
            return
        }
        #expect(label.bounds.width >= label.intrinsicContentSize.width - 0.5, "ラベルの文字が縮んでいます: \(label.bounds.width) / \(label.intrinsicContentSize.width)\n\(composer.stateDump())", sourceLocation: sourceLocation)
        #expect(button.bounds.width >= label.frame.maxX, "ラベルが文字より狭くなりました\n\(composer.stateDump())", sourceLocation: sourceLocation)
    }

    /// 設定で隠すと、空の投稿欄は書いていない間だけ隠れ、一覧の下の余白にも数えない。書き始めると出て、空のまま閉じるとまた隠れる。
    @Test func hidesEmptyBarOnlyWhileNotEditing() async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        var obscured: CGFloat = -1
        composer.onObscuredHeightChange = { obscured = $0 }
        settings.hidesEmptyComposeBar = true
        try await clock.advance(by: 0.10)
        #expect(composer.isBarHidden, "設定で隠しても、空の投稿欄が隠れません\n\(composer.stateDump())")
        #expect(obscured == 0, "隠しているのに、一覧の下の余白に数えています: \(obscured)")

        composer.beginEditing()
        try await clock.advance(by: 0.10)
        #expect(!composer.isBarHidden, "書き始めても、投稿欄が隠れたままです\n\(composer.stateDump())")
        #expect(obscured > 0)

        composer.endEditing()
        try await clock.advance(by: 0.08)
        #expect(composer.isBarHidden, "空のまま閉じても、投稿欄が隠れません\n\(composer.stateDump())")
        let bar = try composerBar()
        let moving = try #require(bar.layer.presentation()).frame
        #expect(moving.minY < window.bounds.maxY, "投稿欄が下がらずに消えました: \(moving)")
        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(bar.frame.minY >= window.bounds.maxY, "隠したのに、投稿欄が画面の外に出ていません: \(bar.frame)")
        #expect(bar.frame.height >= 30, "画面の外に出すときに、投稿欄が縮められました: \(bar.frame)")

        settings.hidesEmptyComposeBar = false
        try await clock.advance(by: 0.10)
        #expect(!composer.isBarHidden, "設定を戻しても、投稿欄が隠れたままです\n\(composer.stateDump())")
    }

    /// 書きかけの本文や返信先があるときは、閉じても隠さない。残っていることに気づけるようにする。
    @Test func keepsBarShownWhileDraftRemains() async throws {
        defer { window.isHidden = true }
        settings.hidesEmptyComposeBar = true
        composer.beginEditing()
        composer.model.text = "書きかけ"
        composer.endEditing()
        try await clock.advance(by: 0.10)
        #expect(!composer.isBarHidden, "書きかけの本文があるのに、投稿欄を隠しました\n\(composer.stateDump())")

        composer.model.text = ""
        try await clock.advance(by: 0.10)
        #expect(composer.isBarHidden, "本文を消しても、投稿欄が隠れません\n\(composer.stateDump())")

        composer.reply(to: try status(id: "10"))
        composer.endEditing()
        try await clock.advance(by: 0.10)
        #expect(!composer.isBarHidden, "返信先があるのに、投稿欄を隠しました\n\(composer.stateDump())")
    }

    /// 書いている間に下書きが変わったあと、閉じてから下書きが空になっても（送っている間に閉じ、送り終えて空に戻したときなど）、隠す。
    @Test func hidesBarWhenDraftEmptiesAfterEndingEditing() async throws {
        defer { window.isHidden = true }
        settings.hidesEmptyComposeBar = true
        composer.beginEditing()
        try await clock.advance(by: 0.05)
        composer.model.text = "書きかけ"
        try await clock.advance(by: 0.05)
        composer.endEditing()
        try await clock.advance(by: 0.05)
        #expect(!composer.isBarHidden)

        composer.model.text = ""
        try await clock.advance(by: 0.10)
        #expect(composer.isBarHidden, "閉じたあとに下書きが空になっても、投稿欄が隠れません\n\(composer.stateDump())")
    }

    /// 隠す設定で、書いている間にキーボードが下がり始めたら、書き終えるのを待たずにバーも画面の外へ下げる。
    /// キーボードが戻ったら、バーもキーボードの上に戻す。
    @Test func sinksWithKeyboardBeforeEndingEditing() async throws {
        defer { window.isHidden = true }
        settings.hidesEmptyComposeBar = true
        composer.beginEditing()
        try await clock.advance(by: 0.10)
        postKeyboardFrame(height: 336)
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let bar = try composerBar()
        // テストで送るキーボードの知らせでは`keyboardLayoutGuide`が動かないので、キーボードの上にあるかではなく、画面の中にあるかを見る。
        #expect(bar.frame.maxY <= window.bounds.maxY, "書き始めても、投稿欄が画面の中にありません: \(bar.frame)")

        postKeyboardFrame(height: 0)
        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(composer.stateDump().contains("editing: true"))
        #expect(bar.frame.minY >= window.bounds.maxY, "キーボードが下がっても、投稿欄が画面の外に出ていません: \(bar.frame)")

        postKeyboardFrame(height: 336)
        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(bar.frame.maxY <= window.bounds.maxY, "キーボードが戻っても、投稿欄が画面の中に戻りません: \(bar.frame)")
    }

    /// 出てくる途中で閉じても、出す動きの終わりで、下がっている途中のバーを書いていないときの形に変えない。画面の外に出てから変える。
    @Test func interruptedShowKeepsEditingShapeWhileSlidingOut() async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        tuning.setValue(1.0, for: TuningCatalog.composeMorphDuration)
        settings.hidesEmptyComposeBar = true
        try await waitUntilSettled()
        composer.beginEditing()
        try await clock.advance(by: 0.30)
        composer.endEditing()
        // 下がっている間、何度か見て、書いていないときの形になっていれば、もう画面の外で止まっていることを確かめる。
        let bar = try composerBar()
        for _ in 0..<30 {
            try await clock.advance(by: 0.05)
            guard composer.stateDump().contains("rest hidden=false") else { continue }
            let moving = (bar.layer.animationKeys() ?? []).filter { $0.hasPrefix("position") }
            #expect(moving.isEmpty && bar.frame.minY >= window.bounds.maxY, "下がっている途中で、書いていないときの形に変えました: \(moving) \(bar.frame)\n\(composer.stateDump())")
            break
        }
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("rest hidden=false"), "画面の外に出ても、書いていないときの形に戻していません\n\(composer.stateDump())")
    }

    /// 広げたまま閉じても、画面の外に出るまでは広げた形のまま下げる。
    @Test func expandedBarKeepsHeightWhileSlidingOut() async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        settings.hidesEmptyComposeBar = true
        composer.beginEditing()
        try await waitUntilSettled()
        let expand = try #require(buttons(in: window).first { $0.accessibilityLabel == "広げて書く" })
        expand.sendActions(for: .primaryActionTriggered)
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let bar = try composerBar()
        let expandedHeight = bar.bounds.height

        composer.endEditing()
        try await clock.advance(by: 0.05)
        window.layoutIfNeeded()
        #expect(abs(bar.bounds.height - expandedHeight) < 1, "下げ始めたときに、広げた高さを保っていません: \(bar.bounds.height) / \(expandedHeight)")
        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(bar.frame.minY >= window.bounds.maxY)
        #expect(bar.bounds.height < expandedHeight, "画面の外に出ても、広げる前の形に戻していません\n\(composer.stateDump())")
    }

    /// 形を変える動きと広げる動きを、アプリの既定の長さに戻す。
    private func useDefaultAnimationDurations() {
        tuning.reset(.number(TuningCatalog.composeMorphDuration))
        tuning.reset(.number(TuningCatalog.composeExpandDuration))
    }

    /// ウィンドウの中の動きがなくなるまで、動きの時間を進める。
    private func waitUntilSettled(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await clock.runUntilIdle(sourceLocation: sourceLocation)
    }

    private func composerBar() throws -> UIView {
        try #require(window.rootViewController?.view.subviews.first { String(describing: type(of: $0)) == "ComposeBarView" })
    }

    private func buttons(in view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
    }
}

/// 開けるまで投稿の送信を待たせる。
@MainActor
private final class PostGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}
