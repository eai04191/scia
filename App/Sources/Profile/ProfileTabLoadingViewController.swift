import SciaCore
import UIKit

/// タブに置いたプロフィールの、アカウントを読むまでの画面。並びにはアカウントのIDしかなく、プロフィール画面はアカウントがないと作れないため、
/// 並びに出たときにアカウントを読み（`loadAccount`）、タブのアイコンに使えるよう`onAccount`に渡す。
/// 初めて開いたときに読めていれば`onLoad`に渡し、渡された側が、この画面をプロフィール画面に差し替える。
/// 投稿は、開くまで読まない。決まりはdocs/tabs.mdの「プロフィール」にある。
final class ProfileTabLoadingViewController: UIViewController {
    private enum State {
        case idle
        case loading
        case loaded(Account)
        case failed(ErrorPresentation)
    }

    private let fetch: @Sendable () async throws -> Account
    private let tasks: TaskScope
    private var state = State.idle
    private var loadTask: Task<Void, Never>?
    private var hasAppeared = false
    /// 読めたアカウントを、開いているかによらず渡す。設定する前に読めていたら、設定したときに渡す。
    var onAccount: ((Account) -> Void)? {
        didSet {
            if case .loaded(let account) = state {
                onAccount?(account)
            }
        }
    }
    /// 開いている画面に、読めたアカウントを渡す。開く前に読めていたら、開いたときに渡す。
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

    /// アカウントを読み始める。読めなかったときは読み直し、読めていたら`onAccount`にもう一度渡す。読んでいる途中なら何もしない。
    func loadAccount() {
        switch state {
        case .idle, .failed:
            load()
        case .loaded(let account):
            onAccount?(account)
        case .loading:
            break
        }
    }

    /// 読めていたら、プロフィール画面に差し替えさせる。並びに出たときに読めなかったら、初めて開いたときに読み直す。
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        let isFirst = !hasAppeared
        hasAppeared = true
        switch state {
        case .idle:
            load()
        case .loaded(let account):
            onLoad?(account)
        case .failed where isFirst:
            load()
        case .loading, .failed:
            break
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
                guard let self else { return }
                state = .loaded(account)
                onAccount?(account)
                if hasAppeared {
                    onLoad?(account)
                }
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
        case .idle, .loading, .loaded:
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
