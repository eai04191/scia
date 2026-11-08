import PhotosUI
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄を実際のウィンドウに載せ、開閉や返信先の付け替えで行が崩れないことを確かめる。
@MainActor
@Suite(.scratch, .serialized)
final class InlineComposeControllerTests {
    private let window: UIWindow
    private let composer: InlineComposeController
    private let settings: AppSettings
    private let tuning = TuningStore(defaults: nil)
    /// ウィンドウの中の動きの時間。実際の時間では進まず、テストが進めた分だけ進む。
    private let clock: LayerClock

    /// Swift Testingは、テストを終えたスイートの値をメインスレッドの外で手放す。持っているウィンドウやビューもそこで手放され、UIKitの解放がメインスレッドの外で走ると、
    /// 続くテストの描画と競って、解放中のウィンドウへのweak参照や解放済みのビューを触って落ちる。メインスレッドで手放させる。
    isolated deinit {}

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
        composer = InlineComposeController(model: ComposeModel<UIImage>(tasks: TaskScope(), myAccountID: "1", backgroundTime: { _ in {} }) { _ in }, tuning: tuning, settings: settings)
        composer.install(in: tabBarController)
        window.layoutIfNeeded()
        clock = LayerClock(freezing: window.layer)
        hideSoftwareKeyboard()
    }

    /// 実物のキーボードを出さない。シミュレーターのハードウェアキーボードが外れていても、結果が変わらないようにする。キーボードの動きは、テストが通知で送る。
    private func hideSoftwareKeyboard() {
        for textView in textViews(in: window) { textView.inputView = UIView(frame: .zero) }
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
        composer.model.apply(configuration: InstanceConfiguration(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown), defaultVisibility: .public, defaultSensitive: nil)
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

    /// メディアを選ぶシートを出したまま投稿ボタンを押したら、添付の準備を待つ前にシートを閉じる。待つ間にシートで選び直せないようにするため。
    @Test func submittingWhileMediaPickerIsShownClosesIt() async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        let uploading = Gate()
        let media = ComposeMediaService<UIImage>(
            upload: { upload in
                try await uploading.wait()
                return MediaAttachment(id: "m-\(upload.filename)", type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil)
            },
            waitUntilProcessed: { id in MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            updateDescription: { id, _ in MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            makeThumbnail: { _ in nil },
            unprocessableImageTypes: { [] },
            recordUnprocessableImageType: { _ in },
            preparation: { .keepsOriginal }
        )
        var sent: [StatusDraft] = []
        let composer = try installComposer(media: media) { sent.append($0) }
        composer.model.apply(configuration: InstanceConfiguration(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown), defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        try await waitUntilSettled()
        let mediaButton = try #require(buttons(in: window).first { $0.accessibilityLabel == ComposeToolItem.media.title })
        mediaButton.sendActions(for: .primaryActionTriggered)
        try await clock.advance { window.rootViewController?.presentedViewController is PHPickerViewController }
        composer.model.applyPickerSelection([try pickedImage()])
        try await waitUntil { uploading.waiterCount == 1 }

        let send = try #require(buttons(in: window).first { $0.accessibilityLabel == "投稿" })
        send.sendActions(for: .primaryActionTriggered)
        try await waitUntil { composer.model.isWaitingForMedia }
        try await clock.advance { composer.stateDump().contains("mediaPicker: nil") }
        #expect(composer.stateDump().contains("mediaPicker: nil"), "シートが閉じませんでした\n\(composer.stateDump())")
        #expect(sent.isEmpty)

        uploading.open()
        try await waitUntil { !composer.model.isPosting }
        #expect(sent.map(\.mediaIDs) == [["m-a.jpg"]])
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

    /// 英字の後ろに記号をペーストしても、本文と注意書きの欄が間に空白を足さない。UIKitのスマート挿入は、「abc」の後ろに「─」を貼ると「abc ─」にしていた。
    @Test func pasteKeepsTextAsCopied() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        composer.model.showsSpoiler = true
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText("abc")
        textView.paste(itemProviders: [NSItemProvider(object: "─" as NSString)])
        try await waitUntil { textView.text != "abc" }
        #expect(textView.text == "abc─")

        let spoilerField = try #require(textFields(in: window).first { $0.placeholder?.hasPrefix("注意書き") == true })
        spoilerField.becomeFirstResponder()
        spoilerField.insertText("abc")
        spoilerField.paste(itemProviders: [NSItemProvider(object: "─" as NSString)])
        try await waitUntil { spoilerField.text != "abc" }
        #expect(spoilerField.text == "abc─")
    }

    /// 投票の欄を出して本文を書いているとき、欄を全部出すと本文に最低の行数も残らないなら、選択肢の欄を1行に折りたたむ。
    /// 1行を押すと開いて選択肢に書き始め、本文に戻るとまた折りたたむ。場所が足りていれば、本文を書いていても開いたままにする。
    @Test func pollFoldsWhileWritingTextOnlyWhenItDoesNotFit() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        composer.model.addPoll()
        for (index, option) in ["a", "b", "c", "d"].enumerated() {
            composer.model.setPollOption(option, at: index)
        }
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        postKeyboardFrame(height: 0)
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("folded=false"), "場所が足りているのに折りたたみました\n\(composer.stateDump())")

        // 画面の高さの半分以上をキーボードが占め、投票の欄を全部出すと本文の場所が残らない。
        postKeyboardFrame(height: 500)
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("folded=true"), "場所が足りないのに折りたたんでいません\n\(composer.stateDump())")

        let summary = try #require(buttons(in: window).first { $0.accessibilityLabel == "投票の選択肢" })
        summary.sendActions(for: .primaryActionTriggered)
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("firstResponder: poll"), "1行を押しても、選択肢に書き始めていません\n\(composer.stateDump())")
        #expect(composer.stateDump().contains("folded=false"), "選択肢を書いているのに折りたたんだままです\n\(composer.stateDump())")

        textView.becomeFirstResponder()
        try await waitUntilSettled()
        // キーボードの枠の知らせが続いても、開き直さない。
        postKeyboardFrame(height: 500)
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("folded=true"), "本文に戻っても折りたたんでいません\n\(composer.stateDump())")
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// 本文を書いたまま文字を大きくすると、キーボードの知らせが来なくても、折りたたむかを決め直す。
    @Test func pollFoldingFollowsContentSizeChange() async throws {
        defer {
            window.traitOverrides.preferredContentSizeCategory = .large
            window.isHidden = true
        }
        composer.beginEditing()
        composer.model.addPoll()
        for (index, option) in ["a", "b", "c", "d"].enumerated() {
            composer.model.setPollOption(option, at: index)
        }
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        postKeyboardFrame(height: 300)
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("folded=false"), "場所が足りているのに折りたたみました\n\(composer.stateDump())")

        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("folded=true"), "文字を大きくして場所が足りなくなったのに折りたたんでいません\n\(composer.stateDump())")
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

    /// 書いている間に設定で並びを変えると、すぐにツールバーと＋が並びに合う。行の中のボタンが重ならない。
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

    /// 予約の日時、言語、ボタンの並びのシートを、出した側の画面から`dismissPresentedScreens`でまとめて閉じても（デバッグのリセットなど）、閉じたことになり、キーボードを閉じれば書き終える。
    /// シート自身の`dismiss`を通らない閉じ方なので、閉じた扱いにならないと、以後キーボードを閉じても欄がカプセルに戻らない。
    @Test(arguments: [ComposeToolItem.schedule, .language, .customize])
    func sheetClosedByPresenterEndsShowing(item: ComposeToolItem) async throws {
        defer { window.isHidden = true }
        settings.composeToolLayout = MenuLayout(elements: [.more, .item(item, isVisible: true)])
        composer.beginEditing()
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let tool = try #require(buttons(in: window).first { $0.accessibilityLabel == item.title })
        tool.sendActions(for: .primaryActionTriggered)
        try await waitUntilSettled()
        if item == .schedule {
            window.layoutIfNeeded()
            let date = try #require(buttons(in: window).first { $0.accessibilityLabel == "予約の日時" })
            date.sendActions(for: .primaryActionTriggered)
            try await waitUntilSettled()
        }
        let host = try #require(window.rootViewController)
        let sheet = try #require(host.presentedViewController)
        #expect(sheet is ScheduleDateSheet || sheet is PostingLanguageSheet || sheet is ComposeToolLayoutSheet)

        host.dismissPresentedScreens(animated: true)
        try await clock.advance { host.presentedViewController == nil }
        try await waitUntilSettled()
        composer.endEditing()
        try await waitUntilSettled()

        #expect(composer.stateDump().contains("editing: false"), "閉じたシートを出したままの扱いです\n\(composer.stateDump())")
    }

    /// 共有で投稿欄に入るときに、メディアを選ぶシートと絵文字のパレットをまとめて閉じても、閉じたことになり、バーをシートの上端から外して書き終える。
    /// 閉じた扱いにならないと、バーがシートのあった高さに留まったままになり、ボタンで閉じ直すこともできない。
    @Test(arguments: [ComposeToolItem.media, .customEmoji])
    func bottomSheetClosedByPresenterReleasesBar(item: ComposeToolItem) async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        settings.composeToolLayout = MenuLayout(elements: [.more, .item(item, isVisible: true)])
        composer.model.apply(configuration: InstanceConfiguration(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown), defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let tool = try #require(buttons(in: window).first { $0.accessibilityLabel == item.title })
        tool.sendActions(for: .primaryActionTriggered)
        let host = try #require(window.rootViewController)
        try await clock.advance { host.presentedViewController != nil && host.presentedViewController?.isBeingPresented == false }
        #expect(composer.isBarHeld, "シートを開いても、バーを留めていません\n\(composer.stateDump())")

        var closed = false
        host.closeScreensForSharedContent { closed = true }
        try await clock.advance { closed }
        try await waitUntilSettled()

        #expect(!composer.isBarHeld, "閉じたシートの上端にバーを留めたままです\n\(composer.stateDump())")
        #expect(composer.stateDump().contains("mediaPicker: nil"), "閉じたシートを出したままの扱いです\n\(composer.stateDump())")
        #expect(composer.stateDump().contains("editing: false"), "閉じたシートを出したままの扱いです\n\(composer.stateDump())")
    }

    /// 予約の日時を「決定」で閉じると、日時を知らせてから閉じたことを知らせる。投稿欄が日時を反映してからキーボードを戻すため。
    @Test func scheduleSheetConfirmsBeforeClosing() async throws {
        defer { window.isHidden = true }
        var events: [String] = []
        let sheet = ScheduleDateSheet(title: "予約の日時", date: Date(timeIntervalSince1970: 1_800_000_000), minimumDate: Date(timeIntervalSince1970: 1_700_000_000), confirmTitle: "完了") { _ in
            events.append("confirm")
        } onClose: {
            events.append("close")
        }
        let host = try #require(window.rootViewController)
        try await host.presentForTesting(sheet, advancing: clock)

        let confirm = try #require(sheet.topViewController?.navigationItem.rightBarButtonItem?.primaryAction)
        confirm.performWithSender(nil, target: nil)
        try await clock.advance { events.count == 2 }

        #expect(events == ["confirm", "close"])
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

    /// 変換中の文字を残したまま送っても、送り終えたら本文を空に戻す。
    /// 書き終えてキーボードを閉じると、入力欄は変換中の文字を確定するか取り消して本文が変わったと知らせる。
    /// 空にした本文をまだ入力欄に入れていないと、そのとき入力欄に残っていた本文が下書きに戻るため。
    @Test func postingWithMarkedTextClearsDraft() async throws {
        defer { window.isHidden = true }
        let composer = try installComposer { _ in }
        composer.model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText("本文")
        textView.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0))
        try await waitUntilSettled()
        #expect(composer.model.text == "本文へんかん")
        // ハードウェアキーボードの日本語入力は、キーボードを閉じると変換中の文字を取り消して、本文が変わったと知らせる。
        // テストの入力欄はキーボードを閉じても変換中の文字を扱わないので、閉じたときに知らせを送って同じ順にする。
        let observer = NotificationCenter.default.addObserver(forName: UITextView.textDidEndEditingNotification, object: textView, queue: nil) { _ in
            MainActor.assumeIsolated {
                textView.delegate?.textViewDidChange?(textView)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await composer.model.submit()
        try await waitUntilSettled()
        #expect(composer.model.text.isEmpty, "送り終えたのに本文が残りました: \(composer.model.text)")
        #expect(textView.text.isEmpty, "送り終えたのに入力欄に本文が残りました: \(textView.text ?? "")")
    }

    /// 注意書きの欄で変換中の文字を残したまま送っても、送り終えたら注意書きを空に戻し、フォーカスを本文へ移さずに書き終える。
    @Test func postingWithMarkedSpoilerClearsDraft() async throws {
        defer { window.isHidden = true }
        let composer = try installComposer { _ in }
        composer.model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        composer.model.showsSpoiler = true
        composer.model.text = "本文"
        try await waitUntilSettled()
        let field = try #require(textFields(in: window).first)
        let textView = try #require(textViews(in: window).first)
        field.becomeFirstResponder()
        field.insertText("注意")
        // テストの注意書きの欄は、変換中の文字を置いても文字として返さない。閉じたときに残っていた文字が書き戻されないことを確かめる。
        field.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0))
        try await waitUntilSettled()
        #expect(composer.model.spoilerText.hasPrefix("注意"))
        // `postingWithMarkedTextClearsDraft`と同じく、閉じたときに本文が変わった知らせを送って、日本語入力と同じ順にする。
        let observer = NotificationCenter.default.addObserver(forName: UITextField.textDidEndEditingNotification, object: field, queue: nil) { _ in
            MainActor.assumeIsolated {
                field.sendActions(for: .editingChanged)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var textViewBeganEditing = false
        let began = NotificationCenter.default.addObserver(forName: UITextView.textDidBeginEditingNotification, object: textView, queue: nil) { _ in
            MainActor.assumeIsolated { textViewBeganEditing = true }
        }
        defer { NotificationCenter.default.removeObserver(began) }

        await composer.model.submit()
        try await waitUntilSettled()
        #expect(composer.model.spoilerText.isEmpty, "送り終えたのに注意書きが残りました: \(composer.model.spoilerText)")
        #expect(composer.model.text.isEmpty)
        #expect(!textViewBeganEditing, "送り終えるときにフォーカスが本文へ移りました")
        #expect(composer.stateDump().contains("editing: false"), "投稿したのに書いている状態のままです\n\(composer.stateDump())")
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
        // 注意書きの欄の×でも外さない。外すと、押した時点で付いていた閲覧注意が外れて送られるため。
        let clear = try #require(buttons(in: window).first { $0.accessibilityLabel == "注意書きを外す" })
        clear.sendActions(for: .primaryActionTriggered)
        #expect(composer.model.showsSpoiler)

        gate.open()
        await posting.value
        try await waitUntilSettled()
        #expect(!input.isFirstResponder)
        #expect(composer.stateDump().contains("editing: false"), "投稿したのに書いている状態のままです\n\(composer.stateDump())")
    }

    /// 投稿して畳むときは、空にした下書きの「いまどうしてる？」のカプセルへ戻す。送った本文をカプセルの行に描いて、そこへ畳まない。
    @Test func postingCollapsesToEmptyCapsule() async throws {
        defer { window.isHidden = true }
        let composer = try installComposer { _ in }
        composer.model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText("送った本文")
        try await waitUntilSettled()
        useDefaultAnimationDurations()

        await composer.model.submit()
        let rest = try #require(restContents(in: window).first)
        let drawsPosted = { self.textLines(in: self.window).contains { $0.attributedText.string.contains("送った本文") } }
        #expect(!drawsPosted(), "畳み始めに、送った本文を描いています")
        #expect(rest.label.attributedText.string == "いまどうしてる？")
        try await clock.advance(by: 0.1)
        #expect(!drawsPosted(), "畳む途中に、送った本文を描いています")
        try await waitUntilSettled()
        #expect(!drawsPosted(), "畳んだあとに、送った本文を描いています")
        #expect(rest.label.concealedRanges.isEmpty, "畳んだあとも、カプセルの文字を隠しています")
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
        let media = ComposeMediaService<UIImage>(
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

    /// 投稿欄の外の画面（タイムラインのビューアなど）を出している間に投稿に失敗したら、閉じるのを待たずに、その画面の上に知らせる。
    @Test func failedPostWhileOtherScreenIsShownShowsErrorAboveIt() async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        struct Failure: Error {}
        let gate = PostGate()
        let composer = try installComposer { _ in
            await gate.wait()
            throw Failure()
        }
        composer.model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        composer.model.text = "本文"
        let posting = Task { await composer.model.submit() }
        try await waitUntilSettled()
        let other = UIViewController()
        other.modalPresentationStyle = .overFullScreen
        try await #require(window.rootViewController).presentForTesting(other, advancing: clock)

        gate.open()
        await posting.value
        try await clock.advance {
            guard let alert = other.presentedViewController as? UIAlertController else { return false }
            return !alert.isBeingPresented
        }
        #expect(other.presentedViewController is UIAlertController, "外の画面を出している間に、投稿の失敗を知らせません\n\(composer.stateDump())")
    }

    /// 送っている間に添付のビューアを開いたまま投稿に失敗したら、閉じるのを待たずに、ビューアの上に知らせる。
    @Test func failedPostWhileViewerIsOpenShowsErrorAboveIt() async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        struct Failure: Error {}
        let gate = PostGate()
        let media = ComposeMediaService<UIImage>(
            upload: { upload in MediaAttachment(id: "m-\(upload.filename)", type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            waitUntilProcessed: { id in MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            updateDescription: { id, _ in MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/m.jpg"), previewUrl: nil, description: nil) },
            makeThumbnail: { _ in nil },
            unprocessableImageTypes: { [] },
            recordUnprocessableImageType: { _ in },
            preparation: { .keepsOriginal }
        )
        let composer = try installComposer(media: media) { _ in
            await gate.wait()
            throw Failure()
        }
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
        let viewer = try #require(window.rootViewController?.presentedViewController as? MediaViewerController, "添付のビューアが開きませんでした")

        gate.open()
        await posting.value
        try await clock.advance {
            guard let alert = viewer.presentedViewController as? UIAlertController else { return false }
            return !alert.isBeingPresented
        }
        #expect(viewer.presentedViewController is UIAlertController, "ビューアを開いている間に、投稿の失敗を知らせません\n\(composer.stateDump())")
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
        let media = ComposeMediaService<UIImage>(
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

    /// 絵文字のシートが閉じた知らせなしに消えても、投稿欄はシートを閉じたものとして扱い、写真のボタンでメディアを選ぶシートを開ける。
    /// 閉じた知らせを待つだけだと、シートを出しているつもりのまま、写真のボタンは絵文字のシートが閉じ終わるのを待ち続けた（実機で起きた）。
    @Test func emojiSheetDisappearingWithoutCallbackLetsMediaPickerOpen() async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        // 端末の本物のキーボードの知らせが混ざらないよう、送った知らせだけを受けさせる。
        let keyboard = NotificationCenter()
        let composer = try installComposer(keyboardNotifications: keyboard) { _ in }
        composer.model.apply(configuration: InstanceConfiguration(maxCharacters: 500, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown), defaultVisibility: .public, defaultSensitive: nil)
        composer.beginEditing()
        try await waitUntilSettled()
        postKeyboardFrame(height: 300, to: keyboard)
        window.layoutIfNeeded()
        let emojiButton = try #require(buttons(in: window).first { $0.accessibilityLabel == ComposeToolItem.customEmoji.title })
        let mediaButton = try #require(buttons(in: window).first { $0.accessibilityLabel == ComposeToolItem.media.title })
        emojiButton.sendActions(for: .primaryActionTriggered)
        try await clock.advance { window.rootViewController?.presentedViewController?.isBeingPresented == false }
        let emojiSheet = try #require(window.rootViewController?.presentedViewController)

        // プログラムから閉じると、UIKitは閉じた知らせを出さない。知らせなしに消える場合を、これで作る。
        emojiSheet.dismiss(animated: false)
        try await clock.advance { window.rootViewController?.presentedViewController == nil }
        try await waitUntilSettled()

        mediaButton.sendActions(for: .primaryActionTriggered)
        try await clock.advance { window.rootViewController?.presentedViewController is PHPickerViewController }
        #expect(window.rootViewController?.presentedViewController is PHPickerViewController, "メディアを選ぶシートが開きませんでした\n\(composer.stateDump())")
        #expect(composer.isBarHeld, "メディアを選ぶシートを出しても、バーを留めていません\n\(composer.stateDump())")
    }

    /// 絵文字のシートが閉じた知らせなしに消えると、入力欄にキーボードを戻した直後に閉じ終わるので、まだどちらのキーボードかの知らせが届いていない。
    /// 届く前にハードウェアキーボードとみなしてバーを外さず、届いた高さで決める。外すと、ソフトウェアキーボードが上がってくるまでの間、バーが下へ落ちてから上がり直す。
    @Test func emojiSheetDisappearingWithoutCallbackWaitsForKeyboard() async throws {
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        // 端末の本物のキーボードの知らせが混ざらないよう、送った知らせだけを受けさせる。
        let keyboard = NotificationCenter()
        let composer = try installComposer(keyboardNotifications: keyboard) { _ in }
        composer.beginEditing()
        try await waitUntilSettled()
        postKeyboardFrame(height: 300, to: keyboard)
        window.layoutIfNeeded()
        let emojiButton = try #require(buttons(in: window).first { $0.accessibilityLabel == ComposeToolItem.customEmoji.title })
        emojiButton.sendActions(for: .primaryActionTriggered)
        try await clock.advance { window.rootViewController?.presentedViewController?.isBeingPresented == false }
        let emojiSheet = try #require(window.rootViewController?.presentedViewController)
        // シートを出すときに入力欄を閉じた知らせ。
        postKeyboardFrame(height: 0, to: keyboard)

        // プログラムから閉じると、UIKitは閉じた知らせを出さない。知らせなしに消える場合を、これで作る。
        emojiSheet.dismiss(animated: false)
        try await clock.advance { window.rootViewController?.presentedViewController == nil }
        try await waitUntilSettled()
        #expect(composer.stateDump().contains("firstResponder: text"), "入力欄にキーボードを戻していません\n\(composer.stateDump())")
        #expect(composer.isBarHeld, "キーボードの知らせが届く前に、バーを外しました\n\(composer.stateDump())")

        postKeyboardFrame(height: 300, to: keyboard)
        #expect(composer.isBarHeld, "ソフトウェアキーボードが上がりきる前に、バーを外しました\n\(composer.stateDump())")
        keyboard.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        #expect(!composer.isBarHeld, "キーボードが上がりきっても、バーを外していません\n\(composer.stateDump())")
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

    /// GIFの付いた投稿の編集を始めたら、投稿欄が広がる間に動かすサムネイルの複製にも、GIFのバッジを載せる。
    /// 載せないと、広がり終えて本物のサムネイルに替わったコマで、バッジが付く。
    @Test func editingStatusCarriesMediaBadgeWhileExpanding() async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        let gif = MediaAttachment(id: "100", type: .gifv, url: URL(string: "https://example.social/m.mp4"), previewUrl: URL(string: "https://example.social/m.png"))
        let base = try status(id: "10")
        let status = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: "<p>本文</p>", spoilerText: "", url: nil, mediaAttachments: [gif])
        #expect(composer.edit(status, source: StatusSource(id: "10", text: "本文", spoilerText: "")))
        try await clock.advance(by: 0.02)

        let strip = try #require(attachmentStrips(in: window).first)
        let badge = try #require(badges(in: strip).first, "添付のサムネイルにバッジがありません")
        #expect(!badge.isHidden)
        // 複製に載せたバッジは、本物のバッジを描いた画像で、本物と同じ大きさになる。
        let carried = imageViews(in: window).filter { !$0.isDescendant(of: strip) && $0.bounds.size == badge.bounds.size }
        #expect(!carried.isEmpty, "広がる間に動かす複製に、バッジを載せていません")
    }

    private func badges(in view: UIView) -> [MediaBadgeView] {
        (view as? MediaBadgeView).map { [$0] } ?? view.subviews.flatMap(badges(in:))
    }

    private func imageViews(in view: UIView) -> [UIImageView] {
        ((view as? UIImageView).map { [$0] } ?? []) + view.subviews.flatMap(imageViews(in:))
    }

    /// 送信を待たせるComposeModelで投稿欄を置き直す。
    private func installComposer(media: ComposeMediaService<UIImage> = .unavailable, keyboardNotifications: NotificationCenter = .default, post: @escaping (StatusDraft) async throws -> Void) throws -> InlineComposeController {
        let tabBarController = UITabBarController(tabs: [UITab(title: "ホーム", image: nil, identifier: "home") { _ in UIViewController() }])
        window.rootViewController = tabBarController
        let composer = InlineComposeController(model: ComposeModel<UIImage>(tasks: TaskScope(), myAccountID: "1", media: media, backgroundTime: { _ in {} }, post: post), tuning: tuning, settings: settings, keyboardNotifications: keyboardNotifications)
        composer.install(in: tabBarController)
        window.layoutIfNeeded()
        hideSoftwareKeyboard()
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

    /// ラベルの文字が省略も切り取りもされずに収まっている。UILabelが本来の幅を確保し、ボタンがその文字を囲んでいる。
    private func expectChipFitsTitle(_ button: UIButton, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let label = button.titleLabel else {
            Issue.record("ラベルのボタンにUILabelがありません", sourceLocation: sourceLocation)
            return
        }
        #expect(label.bounds.width >= label.intrinsicContentSize.width - 0.5, "ラベルの文字が縮んでいます: \(label.bounds.width) / \(label.intrinsicContentSize.width)\n\(composer.stateDump())", sourceLocation: sourceLocation)
        #expect(button.bounds.width >= label.frame.maxX, "ラベルが文字より狭くなりました\n\(composer.stateDump())", sourceLocation: sourceLocation)
    }

    /// 設定で隠すと、空の投稿欄は書いていない間だけ隠れ、タイムラインの下の余白にも数えない。書き始めると出て、空のまま閉じるとまた隠れる。
    @Test func hidesEmptyBarOnlyWhileNotEditing() async throws {
        defer { window.isHidden = true }
        useDefaultAnimationDurations()
        var obscured: CGFloat = -1
        composer.onObscuredHeightChange = { obscured = $0 }
        settings.hidesEmptyComposeBar = true
        try await clock.advance(by: 0.10)
        #expect(composer.isBarHidden, "設定で隠しても、空の投稿欄が隠れません\n\(composer.stateDump())")
        #expect(obscured == 0, "隠しているのに、タイムラインの下の余白に数えています: \(obscured)")

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

    /// 畳まない設定では、書いていないときも入力欄とツールバーを出しておき、書き始めても書き終えても、ボタンの位置を動かさない。
    /// 押した投稿欄が広がると、押した位置にボタンが来て、続けて押したときにボタンを押してしまうため。
    @Test func keepsBarOpenWhileNotEditing() async throws {
        defer { window.isHidden = true }
        settings.keepsComposeBarOpen = true
        try await waitUntilSettled()
        window.layoutIfNeeded()
        let textView = try #require(textViews(in: window).first)
        #expect(!textView.isHidden, "畳まない設定なのに、書いていないときに入力欄が隠れています\n\(composer.stateDump())")
        #expect(composer.stateDump().contains("editing: false open: true"), "畳まない設定なのに、カプセルに畳んでいます\n\(composer.stateDump())")
        let bar = try composerBar()
        let resting = bar.frame

        composer.beginEditing()
        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(bar.frame == resting, "書き始めると、投稿欄の形が変わりました: \(resting) → \(bar.frame)")

        composer.endEditing()
        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(composer.stateDump().contains("editing: false open: true"), "書き終えると、カプセルに畳みました\n\(composer.stateDump())")
        #expect(bar.frame == resting, "書き終えると、投稿欄の形が変わりました: \(resting) → \(bar.frame)")
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")

        settings.keepsComposeBarOpen = false
        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(composer.stateDump().contains("open: false"), "設定を戻しても、カプセルに畳みません\n\(composer.stateDump())")
        #expect(bar.frame.height < resting.height, "設定を戻しても、投稿欄が細くなりません: \(bar.frame)")
    }

    /// 畳まない設定をオンにしたら、書き始める前から押せるボタン（メディアの添付など）のために、既定の値を読ませる。
    @Test func loadsDefaultsWhenOpeningWithoutEditing() async throws {
        defer { window.isHidden = true }
        var loads = 0
        composer.onOpenWithoutEditing = { loads += 1 }
        settings.keepsComposeBarOpen = true
        try await waitUntilSettled()
        #expect(loads == 1, "畳まない設定にしても、既定の値を読ませていません")
    }

    /// 空の投稿欄を隠している間に畳まない設定をオンにしても、隠すのをやめて出したときは、カプセルではなく書いているときの形で出す。
    @Test func showsOpenBarAfterKeepingOpenWhileHidden() async throws {
        defer { window.isHidden = true }
        settings.hidesEmptyComposeBar = true
        try await waitUntilSettled()
        #expect(composer.isBarHidden)

        settings.keepsComposeBarOpen = true
        try await waitUntilSettled()
        settings.hidesEmptyComposeBar = false
        try await waitUntilSettled()
        window.layoutIfNeeded()
        #expect(!composer.isBarHidden)
        #expect(composer.stateDump().contains("editing: false open: true"), "隠している間に畳まない設定にしたのに、カプセルで出しました\n\(composer.stateDump())")
        let textView = try #require(textViews(in: window).first)
        #expect(!textView.isHidden, "隠している間に畳まない設定にしたのに、入力欄を出していません")
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

    /// 開閉で本文の文字を動かすかたまりは、動き始めと着地で、本物の文字と同じ画素に同じ字形と色で描く。
    /// 動き始めは本物を隠したコマ、着地は本物に替えたコマなので、ずれると文字が1コマで跳んだり、太さや色が1コマで替わったりする。
    /// 返信では、入力欄の同じ行に宛先が並び、本文は行の途中（画素の境目から端数のずれた位置）から始まる。
    @Test(arguments: [true, false], [false, true])
    func textMorphMatchesRealTextAtBothEnds(opening: Bool, replying: Bool) async throws {
        defer { window.isHidden = true }
        let body = "きょうはいい天気"
        if replying {
            composer.reply(to: try status(id: "10"))
        } else {
            composer.beginEditing()
        }
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText(body)
        try await waitUntilSettled()
        let typedStart = (textView.text as NSString).length - (body as NSString).length
        if opening {
            composer.endEditing()
            try await waitUntilSettled()
        }
        useDefaultAnimationDurations()
        let label = try #require(restContents(in: window).first?.label)
        // 位置はバーの中の座標で比べる。開閉ではバーごと動き、かたまりも本物もバーと一緒に動くため。
        let bar = try composerBar()
        // 本物とかたまりは、それぞれを描いた頭の文字のインクの重心で比べる。描いた画素で比べないと、画素の境目に揃えて描くことによるずれが分からないため。
        let capsule = { try self.ink(of: label, glyphs: self.firstGlyph(of: label), in: bar) }
        let field = {
            let start = try #require(textView.position(from: textView.beginningOfDocument, offset: typedStart))
            let range = try #require(textView.textRange(from: start, to: textView.position(from: start, offset: 1) ?? start))
            return try self.ink(of: textView, glyphs: textView.firstRect(for: range).insetBy(dx: 0, dy: -8), in: bar)
        }
        // 本物は、動かす前と動き終えたあとに描く。動いている途中は、行を入れ替えて並べ直しているため。
        let source = try opening ? capsule() : field()
        let chunks = { self.textLines(in: self.window).filter { $0.overhang > 0 && $0.attributedText.string == body } }
        // 見えているかたまり。動かすかたまりは、両方の端に合わせて描いた2つの行を重ねて運び、途中で入れ替える。
        let shown = { chunks().max { ($0.layer.presentation()?.opacity ?? 0) < ($1.layer.presentation()?.opacity ?? 0) } }

        if opening {
            composer.beginEditing()
        } else {
            composer.endEditing()
        }
        try await clock.advance(by: 0)
        let first = try #require(shown(), "本文を動かすかたまりがありません\n\(composer.stateDump())")
        #expect(first.layer.presentation()?.opacity == 1)
        #expect(chunks().filter { $0 !== first }.allSatisfy { ($0.layer.presentation()?.opacity ?? 0) == 0 }, "動き始めのコマで、行き先の端に合わせた行も見えています")
        expectSameLook(first.attributedText, label.attributedText)
        expectSameLook(first.attributedText, textView.textStorage)
        expectClose(try glyphInk(of: first, in: bar), source, "動き始めのかたまりが、本物の文字と同じ画素にありません")

        // かたまりを外す直前のコマの、見えている行の位置。
        var landing: (line: TextLineView, ink: CGPoint)?
        while let line = shown() {
            #expect(clock.now < 5, "動き終えても、かたまりが残っています")
            guard clock.now < 5 else { break }
            landing = (line, try glyphInk(of: line, in: bar))
            try await clock.advance(by: LayerClock.frame)
        }
        try await waitUntilSettled()
        let last = try #require(landing)
        #expect(last.line.layer.presentation()?.opacity ?? last.line.layer.opacity == 1)
        expectClose(last.ink, try opening ? field() : capsule(), "着地のコマのかたまりが、本物の文字と同じ画素にありません")
        #expect(label.concealedRanges.isEmpty, "動き終えても、カプセルの文字を隠しています")
        #expect(textView.layer.mask == nil, "動き終えても、入力欄の文字を隠しています")
    }

    /// 返信の宛先だけを書いた下書きを開くと、宛先は入力欄の本物の文字と同じ位置で浮かび上がる。
    /// カプセルでは隠している入力欄の枠の高さが0なので、その場で出し入れするかたまりの入れ物は高さ0から伸びる。入れ物の中身をその大きさに合わせて伸び縮みさせていたため、
    /// 動いている途中に向かい直すと中身の高さがずれ、宛先が欄の高さの分だけ下（ツールバーの上）に描かれ、動き終えてから本文の行へ飛んだ。
    @Test func openingReplyDraftShowsMentionOnTextLine() async throws {
        defer { window.isHidden = true }
        composer.reply(to: try status(id: "10"))
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        let mention = textView.text ?? ""
        try #require(mention.hasPrefix("@"), "返信の宛先が入っていません: \(mention)")
        composer.endEditing()
        try await waitUntilSettled()
        useDefaultAnimationDurations()
        let bar = try composerBar()
        let chunk = { self.textLines(in: self.window).first { $0.overhang > 0 && mention.hasPrefix($0.attributedText.string) && !$0.attributedText.string.isEmpty } }

        composer.beginEditing()
        try await clock.advance(by: 0)
        var landing: CGPoint?
        while let line = chunk() {
            #expect(clock.now < 5, "動き終えても、かたまりが残っています")
            guard clock.now < 5 else { break }
            if (line.layer.presentation()?.opacity ?? 0) > 0.5 {
                landing = try glyphInk(of: line, in: bar)
            }
            try await clock.advance(by: LayerClock.frame)
        }
        try await waitUntilSettled()
        let last = try #require(landing, "宛先を浮かび上がらせるかたまりがありません\n\(composer.stateDump())")
        let range = try #require(textView.textRange(from: textView.beginningOfDocument, to: textView.position(from: textView.beginningOfDocument, offset: 1) ?? textView.beginningOfDocument))
        expectClose(last, try ink(of: textView, glyphs: textView.firstRect(for: range).insetBy(dx: 0, dy: -8), in: bar), "着地のコマの宛先が、入力欄の本物の文字と同じ位置にありません")
    }

    /// 開閉で本文を動かす間、かたまりの文字は本物と同じ大きさのまま描く。
    /// かたまりの文字を描くビューの枠が、開閉のアニメーションの中で初めて決まると、0の大きさから育つ動きになり、描いた文字がその枠に合わせて縮んで見えた。
    /// 開き始めは枠がほぼ0なので、カプセルの文字が消えたように見えた。
    @Test(arguments: [true, false])
    func textMorphKeepsGlyphSizeWhileMoving(opening: Bool) async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText((1...8).map { "\($0)行目" }.joined(separator: "\n"))
        try await waitUntilSettled()
        if opening {
            composer.endEditing()
            try await waitUntilSettled()
        }
        useDefaultAnimationDurations()

        if opening {
            composer.beginEditing()
        } else {
            composer.endEditing()
        }
        try await clock.advance(by: 0)
        var checked = 0
        while case let chunks = textLines(in: window).filter({ $0.overhang > 0 }), !chunks.isEmpty, clock.now < 5 {
            for chunk in chunks {
                // 文字を描くビュー（行のビューの中の1枚）の枠を、開閉の動きで動かしていないか。描いた中身は枠に合わせて伸び縮みするため。
                let canvas = try #require(chunk.subviews.first)
                let moving = (canvas.layer.animationKeys() ?? []).filter { $0.contains("bounds") || $0.contains("position") }
                #expect(moving.isEmpty, "文字を描くビューの枠が動いています: \(moving) \(chunk.attributedText.string)")
                checked += 1
            }
            try await clock.advance(by: LayerClock.frame)
        }
        #expect(checked > 0, "本文を動かすかたまりがありません")
    }

    /// 行が増えて欄を伸ばす動きの途中に、上限の行数を超えて中でスクロールするようになっても、動き終えたあと本文を枠で切る。
    /// 動き終えたときに切り抜きを外していたので、スクロールしているのに枠の外の行が見え、下のツールバーに重なった。
    @Test func growingPastLimitWhileGrowingKeepsTextClipped() async throws {
        defer { window.isHidden = true }
        // 動きの終わりの処理は、止めた窓では呼ばれるかが前に走ったテストで変わるので、変える分だけ並べ直し、終わりの処理はあとでまとめて呼ぶ。
        var completions: [@MainActor () -> Void] = []
        // 終わりの処理は投稿欄を持ち、投稿欄は差し替えたクロージャーを通してこの配列を持つので、テストの終わりに空にして持ち合いを切る。
        defer { completions = [] }
        composer.animateTextHeight = { _, changes, completion in
            changes()
            completions.append(completion)
        }
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText("1行目\n2行目\n3行目")
        for completion in completions { completion() }
        completions = []
        try await waitUntilSettled()

        textView.insertText("\n4行目")
        #expect(completions.count == 1, "4行目に改行しても、欄の高さを変える動きが始まりません")
        textView.insertText("\n5行目\n6行目\n7行目")
        for completion in completions { completion() }
        try await waitUntilSettled()

        #expect(textView.isScrollEnabled && textView.clipsToBounds, "スクロールしているのに、本文を枠で切っていません\n\(composer.stateDump())")
    }

    /// 上限の5行ちょうどの本文は、中でスクロールさせずに全部見せる。
    /// 日本語の字形では、TextKitが行を書体の`lineHeight`より高く並べる。上限を`lineHeight`の5倍で決めていたため、5行目でスクロールに切り替わり、1行目の上が欄の外に隠れた。
    @Test func fiveLinesFitWithoutScrolling() async throws {
        defer { window.isHidden = true }
        settings.appearance.glyphLanguage = .japanese
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText((1...5).map { "\($0)行目" }.joined(separator: "\n"))
        try await waitUntilSettled()

        #expect(!textView.isScrollEnabled && textView.contentOffset.y == 0, "5行の本文が欄に収まっていません\n\(composer.stateDump())")
    }

    /// 共有で入れた本文が5行に収まれば、広げずに書き始める。
    /// 共有した本文は最後に改行を付けるので、4行の本文とカーソルの行で5行になる。上限を低く見積もっていたため、収まるのに広げ、開く動きと広げる動きが重なって行が重なった。
    @Test func sharedTextFittingFiveLinesDoesNotExpand() async throws {
        defer { window.isHidden = true }
        settings.appearance.glyphLanguage = .japanese
        composer.beginEditing(appendingShared: (1...4).map { "\($0)行目" }.joined(separator: "\n") + "\n")
        try await waitUntilSettled()

        #expect(buttons(in: window).contains { $0.accessibilityLabel == "広げて書く" }, "5行に収まる共有の本文で広げています\n\(composer.stateDump())")
    }

    /// 5行に収まらない本文を共有で入れると、広げた形で開き、本文の文字を動かすかたまりは、広げた欄の本物の文字の位置に着地する。
    /// 開き始めてから広げていたので、下書きを捨てて書き始めると、このテストでは広げないまま終わり、シミュレーターではかたまりが広げる前の欄の行に着地して、動き終えるまで本物と別の位置に行が重なって描かれた。
    @Test func sharedTextPastFiveLinesOpensExpanded() async throws {
        defer { window.isHidden = true }
        settings.appearance.glyphLanguage = .japanese
        useDefaultAnimationDurations()
        let bar = try composerBar()
        let lines = (1...8).map { "\($0)行目" }
        let firstLine = lines[0]
        let shown = {
            self.textLines(in: self.window)
                .filter { $0.overhang > 0 && $0.attributedText.string.hasPrefix(firstLine) }
                .max { ($0.layer.presentation()?.opacity ?? 0) < ($1.layer.presentation()?.opacity ?? 0) }
        }

        // 共有で、書きかけの下書きを捨てて新しく書くときと同じく、カプセルに下書きを出してから捨てる。
        composer.model.text = "下書き"
        try await waitUntilSettled()
        composer.discardDraft()
        composer.beginEditing(appendingShared: lines.joined(separator: "\n") + "\n")
        try await clock.advance(by: 0)
        // かたまりを外す直前のコマの、最初の行の位置。
        var landing: CGPoint?
        while let line = shown() {
            #expect(clock.now < 5, "動き終えても、かたまりが残っています")
            guard clock.now < 5 else { break }
            landing = try glyphInk(of: line, in: bar)
            try await clock.advance(by: LayerClock.frame)
        }
        try await waitUntilSettled()

        // 広げていなければ、最初の行は欄の外にあって測れないので、ここで止める。
        try #require(buttons(in: window).contains { $0.accessibilityLabel == "元の大きさに戻す" }, "5行に収まらない共有の本文で広げていません\n\(composer.stateDump())")
        let textView = try #require(textViews(in: window).first)
        let range = try #require(textView.textRange(from: textView.beginningOfDocument, to: textView.position(from: textView.beginningOfDocument, offset: 1) ?? textView.beginningOfDocument))
        let field = try ink(of: textView, glyphs: textView.firstRect(for: range), in: bar)
        expectClose(try #require(landing, "最初の行を動かすかたまりがありません"), field, "着地のコマのかたまりが、広げた欄の本物の文字と同じ画素にありません")
    }

    /// 広げた投稿欄を閉じる途中に、5行に収まらない本文を共有で入れても、本文の文字を動かすかたまりは、広げた欄の本物の文字の位置に着地する。
    /// 開く動きの中で広げるときに、戻す途中の印を消していなかったため、開く間は本文の高さを5行の上限のまま決め、かたまりはその欄の行に着地した。
    @Test func sharedTextPastFiveLinesWhileCollapsingLandsOnExpandedField() async throws {
        defer { window.isHidden = true }
        settings.appearance.glyphLanguage = .japanese
        composer.beginEditing()
        try await waitUntilSettled()
        let expand = try #require(buttons(in: window).first { $0.accessibilityLabel == "広げて書く" })
        expand.sendActions(for: .primaryActionTriggered)
        try await waitUntilSettled()
        useDefaultAnimationDurations()
        let bar = try composerBar()
        let lines = (1...8).map { "\($0)行目" }
        let firstLine = lines[0]
        let shown = {
            self.textLines(in: self.window)
                .filter { $0.overhang > 0 && $0.attributedText.string.hasPrefix(firstLine) }
                .max { ($0.layer.presentation()?.opacity ?? 0) < ($1.layer.presentation()?.opacity ?? 0) }
        }

        composer.endEditing()
        try await clock.advance(by: LayerClock.frame * 3)
        composer.beginEditing(appendingShared: lines.joined(separator: "\n") + "\n")
        try await clock.advance(by: 0)
        // かたまりを外す直前のコマの、最初の行の位置。
        var landing: CGPoint?
        while let line = shown() {
            #expect(clock.now < 5, "動き終えても、かたまりが残っています")
            guard clock.now < 5 else { break }
            landing = try glyphInk(of: line, in: bar)
            try await clock.advance(by: LayerClock.frame)
        }
        try await waitUntilSettled()

        let textView = try #require(textViews(in: window).first)
        try #require(textView.bounds.height >= textView.contentSize.height - 1, "広げた欄に本文が収まっていません\n\(composer.stateDump())")
        let range = try #require(textView.textRange(from: textView.beginningOfDocument, to: textView.position(from: textView.beginningOfDocument, offset: 1) ?? textView.beginningOfDocument))
        let field = try ink(of: textView, glyphs: textView.firstRect(for: range), in: bar)
        expectClose(try #require(landing, "最初の行を動かすかたまりがありません"), field, "着地のコマのかたまりが、広げた欄の本物の文字と同じ画素にありません")
    }

    /// 入力欄の中でスクロールするほど書き、末尾にカーソルを置いたまま閉じて開き直すと、本文の文字を動かすかたまりは、カーソルの行までスクロールした本物の文字の位置に着地する。
    /// かたまりの着地点を、カーソルの行へスクロールする前の位置（先頭）で測っていたため、動き終えてから本文が1コマで飛んだ。
    @Test func reopeningLandsTextMorphOnCaretLine() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        let lines = (1...8).map { "\($0)行目" }
        let lastLine = lines[lines.count - 1]
        textView.insertText(lines.joined(separator: "\n"))
        try await waitUntilSettled()
        composer.endEditing()
        try await waitUntilSettled()
        useDefaultAnimationDurations()
        let bar = try composerBar()
        let shown = {
            self.textLines(in: self.window)
                .filter { $0.overhang > 0 && $0.attributedText.string == lastLine }
                .max { ($0.layer.presentation()?.opacity ?? 0) < ($1.layer.presentation()?.opacity ?? 0) }
        }

        composer.beginEditing()
        try await clock.advance(by: 0)
        // かたまりを外す直前のコマの、最後の行の位置。
        var landing: CGPoint?
        while let line = shown() {
            #expect(clock.now < 5, "動き終えても、かたまりが残っています")
            guard clock.now < 5 else { break }
            landing = try glyphInk(of: line, in: bar)
            try await clock.advance(by: LayerClock.frame)
        }
        try await waitUntilSettled()

        #expect(textView.isScrollEnabled && textView.contentOffset.y > 0, "本文がカーソルの行までスクロールしていません\n\(composer.stateDump())")
        let start = try #require(textView.position(from: textView.endOfDocument, offset: -(lastLine as NSString).length))
        let range = try #require(textView.textRange(from: start, to: textView.position(from: start, offset: 1) ?? start))
        // 上下に広げて測ると、上の行の文字のインクまで拾うので、行の枠のまま測る。
        let field = try ink(of: textView, glyphs: textView.firstRect(for: range), in: bar)
        expectClose(try #require(landing, "最後の行を動かすかたまりがありません"), field, "着地のコマのかたまりが、スクロールした本物の文字と同じ画素にありません")
    }

    /// 開く途中に末尾へ打ち足したら、本文は動かし続け、打ち足した文字とカーソルを隠さない。行の途中に打ったら、かたまりを外して本物を見せる。
    /// 本物は動き始めに測った行の位置で隠すので、行の途中に打つと、打った文字が隠れ、かたまりは打つ前の文字のまま残っていた。
    @Test func typingWhileOpeningShowsTypedText() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText("きょうはいい天気")
        try await waitUntilSettled()
        composer.endEditing()
        try await waitUntilSettled()
        useDefaultAnimationDurations()
        let isMorphing = { self.textLines(in: self.window).contains { $0.overhang > 0 } }

        composer.beginEditing()
        try await clock.advance(by: 0.05)
        #expect(isMorphing())
        let caret = { textView.caretRect(for: textView.selectedTextRange?.start ?? textView.endOfDocument) }
        #expect(isCaretShown(caret(), in: textView), "開く途中に、カーソルを隠しています")

        textView.insertText("だ")
        let lastStart = try #require(textView.position(from: textView.endOfDocument, offset: -1))
        let typed = try #require(textView.textRange(from: lastStart, to: textView.endOfDocument))
        let typedRect = textView.firstRect(for: typed)
        #expect(isMorphing(), "末尾に打ち足しただけで、本文を動かすのをやめました")
        #expect(isShown(CGPoint(x: typedRect.midX, y: typedRect.midY), in: textView), "打ち足した文字を隠しています")
        #expect(isCaretShown(caret(), in: textView), "打ち足したあとのカーソルを隠しています")

        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.insertText("う")
        #expect(!isMorphing(), "行の途中に打っても、かたまりで打つ前の文字を描き続けています")
        #expect(textView.layer.mask == nil, "行の途中に打っても、入力欄の文字を隠しています")
        try await waitUntilSettled()
    }

    /// 本物の文字を隠す穴は、隣り合う行のあいだも隠す。穴は上下に広げてあり、隣の行の穴と重なるので、重なったところを描き戻すと、
    /// 動いている間、行の境目に本物の文字の端が見えた。
    @Test func concealsBetweenAdjacentLines() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await waitUntilSettled()
        let textView = try #require(textViews(in: window).first)
        textView.becomeFirstResponder()
        textView.insertText(String(repeating: "あいうえおかきくけこ", count: 4))
        try await waitUntilSettled()
        composer.endEditing()
        try await waitUntilSettled()
        useDefaultAnimationDurations()

        composer.beginEditing()
        try await clock.advance(by: 0.05)
        let lines = try #require(textView.textLayoutManager).textLayoutFragments(in: textView)
        #expect(lines.count >= 2, "本文が2行に折り返していません")
        // 2行目の頭の文字の上端の、すぐ上とすぐ下。
        let start = try #require(textView.position(from: textView.beginningOfDocument, offset: lines[1]))
        let rect = textView.firstRect(for: try #require(textView.textRange(from: start, to: textView.position(from: start, offset: 1) ?? start)))
        #expect(!isShown(CGPoint(x: rect.midX, y: rect.minY - 1), in: textView), "行の境目の上を隠していません")
        #expect(!isShown(CGPoint(x: rect.midX, y: rect.minY + 1), in: textView), "行の境目の下を隠していません")
        try await waitUntilSettled()
    }

    /// カーソルの左端から右端まで、隠れていないか。行末のカーソルは、最後の文字の穴に半分かかることがある。
    private func isCaretShown(_ caret: CGRect, in textView: UITextView) -> Bool {
        [caret.minX + 0.25, caret.midX, caret.maxX - 0.25].allSatisfy { isShown(CGPoint(x: $0, y: caret.midY), in: textView) }
    }

    /// 入力欄の`point`（入力欄の中の座標）が、本物を隠すマスクで隠れていないか。
    private func isShown(_ point: CGPoint, in textView: UITextView) -> Bool {
        guard let mask = textView.layer.mask as? CAShapeLayer, let path = mask.path else { return true }
        return path.contains(CGPoint(x: point.x - mask.frame.minX, y: point.y - mask.frame.minY))
    }

    private func restContents(in view: UIView) -> [ComposeRestContent] {
        (view as? ComposeRestContent).map { [$0] } ?? view.subviews.flatMap(restContents(in:))
    }

    private func textLines(in view: UIView) -> [TextLineView] {
        ((view as? TextLineView).map { [$0] } ?? []) + view.subviews.flatMap(textLines(in:))
    }

    /// かたまりの頭の文字のインクの重心。かたまりと入れ物が動いている途中の、見えている位置で、`view`の中の座標。
    private func glyphInk(of chunk: TextLineView, in view: UIView) throws -> CGPoint {
        let local = try ink(of: chunk, glyphs: firstGlyph(of: chunk), in: chunk)
        guard let layer = chunk.layer.presentation(), let target = view.layer.presentation() else {
            return chunk.convert(local, to: view)
        }
        return layer.convert(local, to: target)
    }

    /// `view`の頭の文字の範囲。`view`の中の座標。
    private func firstGlyph(of view: TextLineView) -> CGRect {
        let boundaries = view.boundaries
        return CGRect(x: view.baselineOrigin.x, y: view.bounds.minY, width: boundaries.count > 1 ? boundaries[1] : view.bounds.width, height: view.bounds.height)
    }

    /// `view`を画面と同じ倍率で描き、`glyphs`（`view`の中の座標）の中のインクの重心を、`target`の中の座標で返す。
    private func ink(of view: UIView, glyphs: CGRect, in target: UIView, sourceLocation: SourceLocation = #_sourceLocation) throws -> CGPoint {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = false
        // かたまりは、濃さを変えている途中でもモデルの濃さ（行き先の値）で描かれないよう、中身を直接描く。
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            if let line = view as? TextLineView {
                line.drawText(in: context.cgContext)
            } else {
                view.layer.render(in: context.cgContext)
            }
        }
        let cgImage = try #require(image.cgImage, sourceLocation: sourceLocation)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let scale = format.scale
        let area = glyphs.offsetBy(dx: -view.bounds.minX, dy: -view.bounds.minY)
        var sum = (x: 0.0, y: 0.0, weight: 0.0)
        for y in max(Int(area.minY * scale), 0) ..< min(Int(area.maxY * scale), height) {
            for x in max(Int(area.minX * scale), 0) ..< min(Int(area.maxX * scale), width) {
                let alpha = Double(pixels[(y * width + x) * 4 + 3])
                sum = (sum.x + (Double(x) + 0.5) * alpha, sum.y + (Double(y) + 0.5) * alpha, sum.weight + alpha)
            }
        }
        #expect(sum.weight > 0, "文字のインクが見つかりません", sourceLocation: sourceLocation)
        let point = CGPoint(x: sum.x / max(sum.weight, 1) / scale + view.bounds.minX, y: sum.y / max(sum.weight, 1) / scale + view.bounds.minY)
        return view.convert(point, to: target)
    }

    /// 画素の大きさ（1/3pt）より十分小さい違いだけを許す。
    private func expectClose(_ actual: CGPoint, _ expected: CGPoint, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let tolerance: CGFloat = 0.05
        #expect(abs(actual.x - expected.x) <= tolerance && abs(actual.y - expected.y) <= tolerance, "\(message): \(actual) / \(expected)", sourceLocation: sourceLocation)
    }

    /// 頭の文字の字形と色が同じか。
    private func expectSameLook(_ actual: NSAttributedString, _ expected: NSAttributedString, sourceLocation: SourceLocation = #_sourceLocation) {
        let font = { (text: NSAttributedString) in text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont }
        let color = { (text: NSAttributedString) in (text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?.resolvedColor(with: self.window.traitCollection) }
        #expect(font(actual) == font(expected), "字形が違います: \(String(describing: font(actual))) / \(String(describing: font(expected)))", sourceLocation: sourceLocation)
        #expect(color(actual) == color(expected), "色が違います: \(String(describing: color(actual))) / \(String(describing: color(expected)))", sourceLocation: sourceLocation)
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

private extension NSTextLayoutManager {
    /// 入力欄の行の頭の文字の位置（UTF-16）。
    @MainActor
    func textLayoutFragments(in textView: UITextView) -> [Int] {
        guard let content = textContentManager else { return [] }
        var starts: [Int] = []
        enumerateTextLayoutFragments(from: documentRange.location, options: [.ensuresLayout]) { fragment in
            let paragraph = content.offset(from: self.documentRange.location, to: fragment.rangeInElement.location)
            starts += fragment.textLineFragments.map { paragraph + $0.characterRange.location }
            return true
        }
        return starts
    }
}
