import SciaCore
import SwiftUI
import UIKit

/// 最初の起動のログイン画面。ログアウトせず、サーバーにもつながずに、応答を待つ間と、待ちが長引いて「キャンセル」が出るところを見る。
enum LoginCatalog {
    /// 応答を返さないサーバー。
    private struct SilentTransport: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(for: .seconds(3_600))
            throw URLError(.timedOut)
        }

        func open(_ request: URLRequest, limit: Int) async throws -> (HTTPResponseBody, HTTPURLResponse) {
            try await Task.sleep(for: .seconds(3_600))
            throw URLError(.timedOut)
        }

        func download(_ request: URLRequest, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
            try await Task.sleep(for: .seconds(3_600))
            throw URLError(.timedOut)
        }
    }

    @MainActor
    static func states() -> [CatalogState] {
        [
            state("打つ前") { _ in },
            state("応答を待っている（\(Int(ResponseWait.limit.components.seconds))秒たつと「キャンセル」が出る。押すと打つ前に戻る）") { model in
                model.instanceInput = "mastodon.social"
                model.startLogin { _ in throw CancellationError() }
            },
            state("長いアドレスで応答を待っている") { model in
                model.instanceInput = "a-very-long-server-name-that-does-not-fit-in-the-field.example"
                model.startLogin { _ in throw CancellationError() }
            },
        ]
    }

    @MainActor
    private static func state(_ title: String, fill: @escaping @MainActor (LoginModel) -> Void) -> CatalogState {
        CatalogState(title: title) {
            guard let redirectURI = URL(string: "\(AppDependencies.oauthCallbackScheme)://oauth") else {
                preconditionFailure("OAuthのリダイレクトURIを組み立てられません")
            }
            let oauth = OAuthClient(configuration: OAuthClient.Configuration(redirectURI: redirectURI), client: HTTPClient(transport: SilentTransport()))
            let model = LoginModel(oauth: oauth) { _ in }
            fill(model)
            let controller = UIHostingController(rootView: LoginView(model: model, makeAuthenticator: { nil }))
            return CatalogControllerHost(controller, height: 640)
        }
    }
}
