import AuthenticationServices
import UIKit

/// ASWebAuthenticationSessionで認可画面を開き、リダイレクト先のURLを返す。
@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, any Error>?

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    /// ユーザーが認可画面を閉じた場合は`CancellationError`を投げる。
    /// - Parameter isPrivate: Safariのcookieを読まず、ログインで入ったcookieもSafariに残さない。Safariで使っているアカウントとは別のアカウントでログインするときに使う。
    func authenticate(url: URL, callbackScheme: String, isPrivate: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callbackURL, error in
                let result: Result<URL, any Error>
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    result = .failure(CancellationError())
                } else if let error {
                    result = .failure(error)
                } else if let callbackURL {
                    result = .success(callbackURL)
                } else {
                    result = .failure(URLError(.badServerResponse))
                }
                Task { @MainActor in self?.finish(result) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = isPrivate
            self.session = session
            // 開始に失敗したとき、completionHandlerにもエラーが届くかはドキュメントに書かれていない。
            // どちらの経路が先に来ても一度だけ再開するよう、finishで受け付けを一本化する。
            if !session.start() {
                finish(.failure(ASWebAuthenticationSessionError(.presentationContextInvalid)))
            }
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard let continuation = pending else { return }
        pending = nil
        session = nil
        continuation.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }
}
