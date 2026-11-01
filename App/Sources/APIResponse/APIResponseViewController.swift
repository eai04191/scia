import SciaCore
import UIKit

/// 投稿をサーバーから読み直した、APIの応答のJSON。サーバーが投稿に付けた値（言語など）を確かめるために出す。
///
/// 一覧が持っている投稿は読んだあとにモデルへ変換していて、元の応答を持っていないため、開くたびにサーバーから読み直す。
/// 出すのは開いた時点の値で、一覧に流れてきた時点の値とは、その後の編集などで違うことがある。
final class APIResponseViewController: UIViewController {
    private enum State {
        case loading
        case failed(ErrorPresentation)
        case loaded(String)
    }

    /// アプリ全体のアプリ内通知。コピーしたことを知らせる。
    var notices: NoticeCenter?

    private let fetch: @MainActor () async throws -> Data
    private let describe: @MainActor (any Error) async -> ErrorPresentation
    private let tuning: TuningStore
    private let textView = UITextView()
    private var state = State.loading
    private var loadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - fetch: 応答の本文を読む。
    ///   - describe: 読めなかったときに出す理由。
    init(
        fetch: @escaping @MainActor () async throws -> Data,
        describe: @escaping @MainActor (any Error) async -> ErrorPresentation,
        tuning: TuningStore = AppDependencies.tuning
    ) {
        self.fetch = fetch
        self.describe = describe
        self.tuning = tuning
        super.init(nibName: nil, bundle: nil)
        title = "APIの応答"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let copy = UIBarButtonItem(title: "コピー", image: UIImage(systemName: "doc.on.doc"), primaryAction: UIAction { [weak self] _ in self?.copyText() })
        let share = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareText(_:)))
        navigationItem.rightBarButtonItems = [share, copy]
        load()
    }

    private func load() {
        state = .loading
        render()
        loadTask?.cancel()
        loadTask = Task(.action) { [weak self] in
            guard let self else { return }
            do {
                state = .loaded(try APIResponseText.formatted(try await fetch()))
            } catch is CancellationError {
                return
            } catch {
                state = .failed(await describe(error))
            }
            render()
        }
    }

    private var loadedText: String? {
        guard case .loaded(let text) = state else { return nil }
        return text
    }

    private func render() {
        guard isViewLoaded else { return }
        textView.text = loadedText
        textView.isHidden = loadedText == nil
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = loadedText != nil }
        setNeedsUpdateContentUnavailableConfiguration()
    }

    private func copyText() {
        guard let loadedText else { return }
        UIPasteboard.general.string = loadedText
        notices?.showTransient(.textCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    @objc private func shareText(_ sender: UIBarButtonItem) {
        guard let loadedText else { return }
        let activity = UIActivityViewController(activityItems: [loadedText], applicationActivities: nil)
        activity.popoverPresentationController?.sourceItem = sender
        present(activity, animated: true)
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        switch self.state {
        case .loading:
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .failed(let reason):
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "APIの応答を読めませんでした"
            configuration.secondaryAttributedText = reason.attributedText(textStyle: .body)
            configuration.button = .borderedTinted()
            configuration.button.title = "再試行"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
            contentUnavailableConfiguration = configuration
        case .loaded:
            contentUnavailableConfiguration = nil
        }
    }
}
