import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// アカウントの画面の「投稿のデフォルト」。決まりはdocs/account-screen.mdの「投稿のデフォルト」にある。
@MainActor
struct PostingDefaultsModelTests {
    private static let initial = ServerPreferences(defaultVisibility: .public, defaultSensitive: false, expandsSpoilers: false, defaultLanguage: "ja", defaultQuotePolicy: .public)

    private struct Rejected: Error {}

    /// 選んだ値は保存を終える前から出し、保存できたらサーバーが返した既定にする。
    @Test func selectionShowsBeforeSavingAndAdoptsSavedValue() async throws {
        let gate = Gate()
        let saved = Mutex<[PostingDefaultChange]>([])
        let model = PostingDefaultsModel(api: .init(load: { Self.initial }, save: { change in
            saved.withLock { $0.append(change) }
            try await gate.wait()
            var result = change.applied(to: Self.initial)
            result.expandsSpoilers = true
            return result
        }), initial: Self.initial, tasks: TaskScope())

        model.select(.quotePolicy(.followers))
        #expect(model.preferences?.defaultQuotePolicy == .followers)
        #expect(model.preferences?.expandsSpoilers == false)

        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(saved.withLock { $0 } == [.quotePolicy(.followers)])
        #expect(model.preferences?.defaultQuotePolicy == .followers)
        #expect(model.preferences?.expandsSpoilers == true)
    }

    /// 保存できなければ、元の値に戻して理由を渡す。
    @Test func failedSaveRevertsAndReports() async throws {
        let model = PostingDefaultsModel(api: .init(load: { Self.initial }, save: { _ in throw Rejected() }), initial: Self.initial, tasks: TaskScope())
        var failures = 0
        model.onFailure = { _ in failures += 1 }

        model.select(.visibility(.unlisted))
        #expect(model.preferences?.defaultVisibility == .unlisted)
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.preferences?.defaultVisibility == .public)
        #expect(failures == 1)
    }

    /// 同じ値を選んでも送らない。
    @Test func sameValueIsNotSent() {
        let saves = Mutex(0)
        let model = PostingDefaultsModel(api: .init(load: { Self.initial }, save: { _ in
            saves.withLock { $0 += 1 }
            return nil
        }), initial: Self.initial, tasks: TaskScope())

        model.select(.language("ja"))

        #expect(model.runningTaskCount == 0)
        #expect(saves.withLock { $0 } == 0)
    }

    /// 既定の公開範囲がフォロワーのみの間は、引用できる人を「自分のみ」と見せ、選べない理由を出す。選んでいた値は変えない。
    @Test func followersOnlyVisibilityFixesQuotePolicy() async throws {
        let model = PostingDefaultsModel(api: .init(load: { Self.initial }, save: { change in change.applied(to: Self.initial) }), initial: Self.initial, tasks: TaskScope())

        model.select(.visibility(.private))

        #expect(model.shownQuotePolicy == .nobody)
        #expect(model.quotePolicyFixedReason != nil)
        #expect(model.preferences?.defaultQuotePolicy == .public)
        try await waitUntil { model.runningTaskCount == 0 }
    }

    /// 読めなければ理由を出し、読み直して読めたら消す。
    @Test func loadFailureIsShownUntilLoaded() async throws {
        let fails = Mutex(true)
        let model = PostingDefaultsModel(api: .init(load: {
            if fails.withLock({ $0 }) { throw Rejected() }
            return Self.initial
        }, save: { _ in nil }), tasks: TaskScope())

        await model.reload(purpose: .action)?.value
        #expect(model.preferences == nil)
        #expect(model.loadFailure != nil)

        fails.withLock { $0 = false }
        await model.reload(purpose: .action)?.value
        #expect(model.preferences == Self.initial)
        #expect(model.loadFailure == nil)
    }

    /// 保存の前に始めた読み込みが、保存のあとに届いても、保存した値を読み込んだ古い値で上書きしない。
    @Test func staleLoadDoesNotUndoSavedValue() async throws {
        let staleResponse = Gate()
        let model = PostingDefaultsModel(api: .init(load: {
            try await staleResponse.wait()
            return Self.initial
        }, save: { change in change.applied(to: Self.initial) }), initial: Self.initial, tasks: TaskScope())

        let reload = model.reload(purpose: .action)
        try await waitUntil { staleResponse.waiterCount == 1 }
        model.select(.visibility(.private))
        try await waitUntil { model.runningTaskCount == 1 }
        staleResponse.open()
        await reload?.value

        #expect(model.preferences?.defaultVisibility == .private)
    }
}
