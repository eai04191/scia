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

    /// - Parameter isPrivate: Safariのcookieを使わずに認可画面を開く。
    func login(authenticator: WebAuthenticator, isPrivate: Bool) async {
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
                try await authenticator.authenticate(url: url, callbackScheme: AppDependencies.oauthCallbackScheme, isPrivate: isPrivate)
            }
            logger.info("login succeeded instance=\(SciaLog.host(of: instance), privacy: .public)")
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
    /// デバッグビルドで、ログインせずにダミーのデータで入るボタンを押したとき。nilならボタンを出さない。
    var onDummySession: (@MainActor () -> Void)?

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
                            // 行の既定の上下の余白を除き、アイコンと名前を入力欄の上にまとめて見せる
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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
                #if DEBUG
                if let onDummySession {
                    Section {
                        Button("ダミーのデータで入る") { onDummySession() }
                    } footer: {
                        Text("デバッグビルドだけ。通信せず、ダミーの投稿と通知でホームと通知の画面に入ります。")
                    }
                }
                #endif
            }
            .topEdgeEffectHiddenOnMac()
            // ログインボタンは一覧の外の下端に固定する。候補がいくつ並んでも押し出されず、キーボードが出ればその上に乗る。
            // 一覧を最後までスクロールしたときに、末尾のクレジットがボタンに詰まらないよう、間をあける。
            .safeAreaBar(edge: .bottom, spacing: 16) {
                // 長押しで、Safariのログイン状態を使わないプライベートのログインを選べる。iOSの戻るボタンの長押しと同じ作り。
                Menu {
                    // メニューの幅が狭く「プライベートでログイン」は途中で折り返すため、名前を短くして説明をサブタイトルに回す。
                    Button { login(isPrivate: true) } label: {
                        Image(systemName: "hand.raised")
                        Text("プライベート")
                        Text("Safariのログイン状態を使わない")
                    }
                } label: {
                    ZStack {
                        Text("ログイン")
                            .opacity(model.isLoggingIn ? 0 : 1)
                        if model.isLoggingIn {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                } primaryAction: {
                    login()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canLogin)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            // セクションの間の既定の間隔は広く、アイコンと名前が入力欄から離れて見えるため詰める
            .listSectionSpacing(.compact)
            .navigationTitle(isFirstLogin ? "" : "アカウントを追加")
            // 最初の起動の画面はタイトルもキャンセルのボタンもなく、空のバーが高さだけ取るので隠す
            .toolbar(isFirstLogin ? .hidden : .automatic, for: .navigationBar)
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
        login(isPrivate: false)
    }

    private func login(isPrivate: Bool) {
        guard let authenticator = makeAuthenticator() else { return }
        Task { await model.login(authenticator: authenticator, isPrivate: isPrivate) }
    }
}

/// 最初の起動のログイン画面の一番上に出す、アプリのアイコンと名前。
/// 開くとすぐキーボードが出るので、候補を押し下げすぎないよう小さめにする。
private struct AppHeader: View {
    private let iconSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 8) {
            if let image = AppDependencies.appIcon.current.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    // 白地のアイコンは背景に溶けて輪郭が見えないため、設定のアイコンを選ぶ行と同じく縁を引く。角の丸みは60ptで13.5ptの割合
                    .overlay {
                        RoundedRectangle(cornerRadius: iconSize * 13.5 / 60, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    }
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
