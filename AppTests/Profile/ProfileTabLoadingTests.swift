import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

/// タブに置いたプロフィールの、アカウントを読むまでの画面。並びに出たときにアカウントを読み、開くまで画面を差し替えない。
/// 決まりはdocs/tabs.mdの「プロフィール」にある。
@MainActor
struct ProfileTabLoadingTests {
    private static let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)

    /// 読み込みの結果を、呼ばれた順に返す。読んだ回数と、通信の目的を記録する。
    private final class Fetcher: Sendable {
        private let state: Mutex<(results: [Result<Account, URLError>], purposes: [RequestPurpose?])>

        init(_ results: [Result<Account, URLError>]) {
            state = Mutex((results, []))
        }

        var purposes: [RequestPurpose?] { state.withLock { $0.purposes } }

        func fetch() throws -> Account {
            let purpose = RequestPurpose.current
            return try state.withLock { state in
                state.purposes.append(purpose)
                return try state.results.removeFirst().get()
            }
        }
    }

    @MainActor
    private final class Opened {
        let loading: ProfileTabLoadingViewController
        let tasks = TaskScope()
        var accounts: [Account] = []
        var loaded: [Account] = []
        /// 読めなかった回数。
        var failures = 0
        private var window: UIWindow?

        init(fetcher: Fetcher) {
            loading = ProfileTabLoadingViewController(title: "@bob", tasks: tasks) { try fetcher.fetch() }
            loading.onAccount = { [weak self] in self?.accounts.append($0) }
            loading.onLoad = { [weak self] in self?.loaded.append($0) }
            loading.describe = { [weak self] error in
                self?.failures += 1
                return ErrorPresentation(error)
            }
        }

        func show() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = UINavigationController(rootViewController: loading)
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            self.window = window
        }

        func close() {
            tasks.close()
            window?.isHidden = true
            window?.rootViewController = nil
        }
    }

    /// 開く前に読んだアカウントは、アイコンのためにすぐ渡し、画面の差し替えは開いたときにする。読み直さない。
    @Test func loadsBeforeOpeningAndReplacesWhenOpened() async throws {
        let fetcher = Fetcher([.success(Self.account)])
        let opened = Opened(fetcher: fetcher)
        defer { opened.close() }

        opened.loading.loadAccount()
        try await waitUntil { opened.accounts.map(\.id) == ["2"] }
        #expect(opened.loaded.isEmpty)

        try opened.show()

        #expect(opened.loaded.map(\.id) == ["2"])
        #expect(fetcher.purposes == [.display])
    }

    /// 並びに出たときに読めなかったら、初めて開いたときに読み直す。
    @Test func retriesOnFirstOpenAfterFailure() async throws {
        let fetcher = Fetcher([.failure(URLError(.notConnectedToInternet)), .success(Self.account)])
        let opened = Opened(fetcher: fetcher)
        defer { opened.close() }

        opened.loading.loadAccount()
        try await waitUntil { opened.failures == 1 }

        try opened.show()

        try await waitUntil { opened.loaded.map(\.id) == ["2"] }
        #expect(opened.accounts.map(\.id) == ["2"])
        #expect(fetcher.purposes == [.display, .display])
    }

    /// 読めなかったら、開く前でも、頼まれたときに読み直す。読めていたら読み直さず、アカウントをもう一度渡す。
    /// 並びが変わるたびに、アイコンのないプロフィールを読み直すため。
    @Test func loadAccountRetriesFailureAndRepeatsLoadedAccount() async throws {
        let fetcher = Fetcher([.failure(URLError(.notConnectedToInternet)), .success(Self.account)])
        let opened = Opened(fetcher: fetcher)
        defer { opened.close() }
        opened.loading.loadAccount()
        try await waitUntil { opened.failures == 1 }

        opened.loading.loadAccount()
        try await waitUntil { opened.accounts.map(\.id) == ["2"] }
        opened.loading.loadAccount()

        #expect(opened.accounts.map(\.id) == ["2", "2"])
        #expect(fetcher.purposes.count == 2)
        #expect(opened.loaded.isEmpty)
    }

    /// 設定する前に読めていたアカウントは、設定したときに渡す。
    @Test func givesAccountLoadedBeforeObserving() async throws {
        let fetcher = Fetcher([.success(Self.account)])
        let opened = Opened(fetcher: fetcher)
        defer { opened.close() }
        opened.loading.loadAccount()
        try await waitUntil { opened.accounts.count == 1 }

        var given: [Account] = []
        opened.loading.onAccount = { given.append($0) }

        #expect(given.map(\.id) == ["2"])
    }
}
