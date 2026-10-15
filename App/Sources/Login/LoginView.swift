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
    private let logger = SciaLog.logger(category: "login")

    init(onLogin: @escaping @MainActor (Credential) throws -> Void) {
        self.onLogin = onLogin
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("stellaria.network", text: $model.instanceInput)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(login)
                        .disabled(model.isLoggingIn)
                } header: {
                    Text("インスタンス")
                } footer: {
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                Section {
                    Button(action: login) {
                        HStack {
                            Text("ログイン")
                            if model.isLoggingIn {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isLoggingIn || model.instanceInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(onCancel == nil ? "Scia" : "アカウントを追加")
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
