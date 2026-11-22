import Foundation
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// ミュートしたユーザーとブロックしたユーザーの画面で、解除した人の行を、使う人の操作として閉じる動きで消す。
@Suite(.scratch, .failureState)
@MainActor
struct ModerationAccountListTests {
    private static func account(_ id: String) -> String {
        #"{"id":"\#(id)","username":"u\#(id)","acct":"u\#(id)@remote.example","display_name":"U\#(id)","avatar":"https://remote.example/a.png","avatar_static":"https://remote.example/a.png","header":"https://remote.example/h.png","header_static":"https://remote.example/h.png","note":"","url":"https://remote.example/@u\#(id)","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
    }

    @MainActor
    private struct Opened {
        let controller: AccountListController
        let viewController: TimelineViewController
        let window: UIWindow
        let tasks: TaskScope
        let load: Task<Void, Never>?

        func cell(of accountID: String) -> UICollectionViewCell? {
            let collectionView = viewController.collectionView
            collectionView.layoutIfNeeded()
            return collectionView.visibleCells.first { cell in
                guard let indexPath = collectionView.indexPath(for: cell) else { return false }
                return viewController.itemIdentifier(at: indexPath) == TimelineEntry.account(Self.dummy(accountID)).id
            }
        }

        static func dummy(_ id: String) -> Account {
            Account(id: id, username: "u\(id)", acct: "u\(id)@remote.example", displayName: "", avatar: nil)
        }

        func close() {
            tasks.close()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func open(_ kind: AccountListKind, gate: Gate = Gate(isOpen: true), waitsForLoad: Bool = true) async throws -> Opened {
        let body = "[" + ["11", "12", "13"].map(Self.account).joined(separator: ",") + "]"
        let transport = RoutedListTransport(body: body, gate: gate)
        let credential = Credential(instance: try #require(URL(string: "https://example.social")), accessToken: "token", clientID: "id", clientSecret: "secret", accountID: "1", username: "alice")
        let client = MastodonClient(credential: credential, transport: transport)
        let tasks = TaskScope()
        let settings = AppSettings(defaults: TestScratch.defaults("ModerationAccountListTests"))
        let (controller, viewController) = AccountListController.make(kind: kind, client: client, settings: settings, tasks: tasks)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: viewController)
        window.makeKeyAndVisible()
        let load = controller.start(purpose: .action)
        if waitsForLoad {
            await load?.value
        }
        window.layoutIfNeeded()
        return Opened(controller: controller, viewController: viewController, window: window, tasks: tasks, load: load)
    }

    /// 解除した関係が届いたら、その人の行を消し、下の行が詰める動きで上がる。まだミュートしている関係では消さない。
    @Test func unmutedRowClosesWithMotion() async throws {
        let opened = try await open(.mutes)
        defer { opened.close() }
        #expect(opened.cell(of: "12") != nil)

        opened.controller.apply(Relationship(id: "12", muting: true))
        #expect(opened.cell(of: "12") != nil, "まだミュートしている人の行を消しました")

        opened.controller.apply(Relationship(id: "12", muting: false))

        #expect(opened.cell(of: "12") == nil, "解除した人の行が残っています")
        let below = try #require(opened.cell(of: "13"))
        // 出てくるときのフェード（`opacity`）は読み込んだときから付いているので、詰める動きの`position`を見る。
        #expect(below.layer.animationKeys()?.contains("position") == true, "消した行の下の行が動いていません")
    }

    /// 読んでいる途中に解除が届いたら、届いた応答にその人がいても、読み終えたリストに出さない。
    @Test func unmutedDuringLoadIsNotShown() async throws {
        let gate = Gate()
        let opened = try await open(.mutes, gate: gate, waitsForLoad: false)
        defer { opened.close() }
        try await waitUntil { gate.waiterCount == 1 }

        opened.controller.apply(Relationship(id: "12", muting: false))
        gate.open()
        await opened.load?.value

        #expect(opened.cell(of: "11") != nil)
        #expect(opened.cell(of: "12") == nil, "読んでいる途中に解除した人が出ています")
    }

    /// 行のスワイプは「ブロックを解除」で、押すと解除を送る。行を消すのは、関係が届いてから。
    @Test func swipeSendsUnblock() async throws {
        let opened = try await open(.blocks)
        defer { opened.close() }
        var sent: [(String, String)] = []
        opened.controller.onChangeRelation = { change, account in sent.append((String(describing: change), account.id)) }

        #expect(opened.viewController.accountRemoval.title == "ブロックを解除")
        let remove = try #require(opened.viewController.onRemoveAccount)
        remove(Opened.dummy("11"))

        #expect(sent.map(\.0) == ["unblock"])
        #expect(sent.map(\.1) == ["11"])
        #expect(opened.cell(of: "11") != nil)
    }
}

/// 人のリストの読み込みにだけ、門が開いてから決まった人を返す通信。ほかの読み込みは失敗させる。
private final class RoutedListTransport: HTTPTransport {
    private let body: String
    private let gate: Gate

    init(body: String, gate: Gate) {
        self.body = body
        self.gate = gate
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        guard ["/api/v1/mutes", "/api/v1/blocks"].contains(url.path()) else { throw URLError(.notConnectedToInternet) }
        try await gate.wait()
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
