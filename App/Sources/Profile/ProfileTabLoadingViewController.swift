import SciaCore
import UIKit

/// タブに置いたプロフィールの、アカウントを読むまでの画面。並びにはアカウントのIDしかなく、プロフィール画面はアカウントがないと作れないため、
/// 初めて開いたときにアカウントを読み、読めたら`onLoad`に渡す。渡された側が、この画面をプロフィール画面に差し替える。
/// 決まりはdocs/tabs.mdの「プロフィール」にある。
final class ProfileTabLoadingViewController: UIViewController {
    private enum State {
        case idle
        case loading
        case failed(ErrorPresentation)
    }

    private let fetch: @Sendable () async throws -> Account
    private let tasks: TaskScope
    private var state = State.idle
    private var loadTask: Task<Void, Never>?
    /// 読めたアカウントを渡す。
    var onLoad: ((Account) -> Void)?
    /// 読めなかったときに出す理由。
    var describe: @MainActor (any Error) async -> ErrorPresentation = { ErrorPresentation($0) }

    /// - Parameters:
    ///   - title: アカウントを読む前から出す見出し。
    ///   - tasks: 読み込みを始める持ち主。セッションの持ち主の子で、ログアウトやタブから外したときに止める。
    init(title: String, tasks: TaskScope, fetch: @escaping @Sendable () async throws -> Account) {
        self.fetch = fetch
        self.tasks = tasks
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    /// ローカルや連合と同じく、通信を増やさないよう、初めて開いたときに読む。
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if case .idle = state {
            load()
        }
    }

    private func load() {
        state = .loading
        setNeedsUpdateContentUnavailableConfiguration()
        loadTask?.cancel()
        let fetch = fetch
        loadTask = tasks.run(.display) { [weak self] in
            do {
                let account = try await fetch()
                self?.onLoad?(account)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                state = .failed(await describe(error))
                setNeedsUpdateContentUnavailableConfiguration()
            }
        }
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        switch self.state {
        case .idle, .loading:
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .failed(let reason):
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "プロフィールを読み込めませんでした"
            configuration.secondaryAttributedText = reason.attributedText(textStyle: .body)
            configuration.button = .borderedTinted()
            configuration.button.title = "再試行"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
            contentUnavailableConfiguration = configuration
        }
    }
}
