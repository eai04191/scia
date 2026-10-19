import os
import SciaCore
import SwiftUI

@MainActor
@Observable
final class LoginModel {
    var instanceInput = ""
    private(set) var isLoggingIn = false
    private(set) var errorMessage: String?

    /// ログインできたときに呼ぶ。保存に失敗したら投げ、ログイン画面にエラーを出す。
    private let onLogin: @MainActor (Credential) throws -> Void
    private let serverSuggestions: ServerSuggestions
    private let logger = SciaLog.logger(category: "login")

    /// - Parameter accountDomains: ログイン済みのアカウントのサーバー。候補の上に出す。
    init(accountDomains: [String] = [], onLogin: @escaping @MainActor (Credential) throws -> Void) {
        self.onLogin = onLogin
        let knownDomains: [String]
        do {
            knownDomains = try ServerSuggestions.loadKnownDomains()
        } catch {
            // 一覧はアプリに同梱していて、読めないのはビルドの誤りに限る。ログインは打てばできるので、候補をログイン済みのサーバーだけにして続ける。
            logger.error("known servers unavailable: \(SciaLog.describe(error), privacy: .public)")
            knownDomains = []
        }
        serverSuggestions = ServerSuggestions(accountDomains: accountDomains, knownDomains: knownDomains)
    }

    /// 打ったアドレスに合うサーバー。
    var suggestions: [String] {
        serverSuggestions.suggestions(for: instanceInput)
    }

    func showError(_ message: String) {
        errorMessage = message
    }

    func login(authenticator: WebAuthenticator) async {
        errorMessage = nil
        let instance: URL
        do {
            instance = try InstanceAddress.parse(instanceInput)
        } catch {
            errorMessage = ErrorPresentation(error).text
            return
        }

        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let credential = try await AppDependencies.oauth.login(instance: instance) { url in
                try await authenticator.authenticate(url: url, callbackScheme: AppDependencies.oauthCallbackScheme)
            }
            logger.info("login succeeded instance=\(instance.absoluteString, privacy: .public)")
            try onLogin(credential)
        } catch is CancellationError {
            logger.info("login cancelled")
        } catch {
            logger.error("login failed: \(SciaLog.describe(error), privacy: .public)")
            errorMessage = ErrorPresentation(error).text
        }
    }
}

struct LoginView: View {
    @Bindable var model: LoginModel
    /// 認可画面を出すウィンドウ。SwiftUIの外から渡す。
    let makeAuthenticator: @MainActor () -> WebAuthenticator?
    /// アカウントを追加するためにシートで出したときに、閉じるボタンで呼ぶ。nilなら閉じるボタンを出さない。
    var onCancel: (@MainActor () -> Void)?

    /// 最初の起動で出すログイン画面か。アカウントの追加のシートでは、アプリの名前を出さない。
    private var isFirstLogin: Bool { onCancel == nil }

    private var canLogin: Bool {
        !model.isLoggingIn && !model.instanceInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if isFirstLogin {
                    Section {
                        AppHeader()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        InstanceTextField(placeholder: "stellaria.network", text: $model.instanceInput, onSubmit: login)
                    }
                    .disabled(model.isLoggingIn)
                } header: {
                    Text("サーバー")
                } footer: {
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text("アカウントがあるMastodonのサーバーのアドレス")
                    }
                }
                let suggestions = model.suggestions
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions, id: \.self) { domain in
                            Button {
                                model.instanceInput = domain
                            } label: {
                                SuggestionLabel(domain: domain, input: model.instanceInput)
                            }
                            // ログインボタンより目立たせないため、操作の色ではなく本文の色にする。
                            .tint(.primary)
                        }
                    } footer: {
                        // 一覧を無償で使わせてもらっている感謝を込めて、キラキラを添える。
                        Text("サーバー一覧の提供: [FediDB](https://fedidb.com) \(Text(Image(systemName: "sparkles")).foregroundStyle(.yellow))")
                    }
                    .disabled(model.isLoggingIn)
                }
            }
            // ログインボタンは一覧の外の下端に固定する。候補がいくつ並んでも押し出されず、キーボードが出ればその上に乗る。
            // 一覧を最後までスクロールしたときに、末尾のクレジットがボタンに詰まらないよう、間をあける。
            .safeAreaBar(edge: .bottom, spacing: 16) {
                Button(action: login) {
                    ZStack {
                        Text("ログイン")
                            .opacity(model.isLoggingIn ? 0 : 1)
                        if model.isLoggingIn {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canLogin)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .navigationTitle(isFirstLogin ? "" : "アカウントを追加")
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル", role: .cancel) { onCancel() }
                    }
                }
            }
        }
    }

    private func login() {
        guard let authenticator = makeAuthenticator() else { return }
        Task { await model.login(authenticator: authenticator) }
    }
}

/// 最初の起動のログイン画面の一番上に出す、アプリのアイコンと名前。
private struct AppHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            if let image = AppDependencies.appIcon.current.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)
            }
            Text("Scia")
                .font(.largeTitle.bold())
        }
        .frame(maxWidth: .infinity)
    }
}

/// 候補の行。打った部分を太字にして、なぜその候補が出たかを見せる。
private struct SuggestionLabel: View {
    let domain: String
    let input: String

    var body: some View {
        text
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var text: Text {
        guard let range = ServerSuggestions.matchedRange(of: input, in: domain) else { return Text(verbatim: domain) }
        let before = String(domain[..<range.lowerBound])
        let matched = String(domain[range])
        let after = String(domain[range.upperBound...])
        return Text("\(before)\(Text(verbatim: matched).bold())\(after)")
    }
}
