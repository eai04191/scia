import UIKit

extension UIViewController {
    /// ベンチマークの一覧を出す。`benchmark`を渡すと、そのベンチマークの画面まで開く。
    func presentBenchmarks(opening benchmark: Benchmark? = nil) {
        let controllers: [UIViewController] = [BenchmarkListViewController()] + (benchmark.map { [BenchmarkRunViewController(benchmark: $0)] } ?? [])
        if let navigation = self as? UINavigationController, navigation.viewControllers.first is BenchmarkListViewController {
            navigation.setViewControllers(controllers, animated: false)
            return
        }
        let navigation = UINavigationController()
        navigation.setViewControllers(controllers, animated: false)
        present(navigation, animated: true)
    }
}

/// ベンチマークの一覧。選ぶと、そのベンチマークを走らせる画面へ入る。
final class BenchmarkListViewController: UIViewController, UICollectionViewDelegate {
    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout.list(using: UICollectionLayoutListConfiguration(appearance: .insetGrouped))
    )
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ベンチマーク"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, id in
            guard let benchmark = Benchmark.all.first(where: { $0.id == id }) else { return }
            var content = cell.defaultContentConfiguration()
            content.text = benchmark.title
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(Benchmark.all.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        self.dataSource = dataSource
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: animated) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource?.itemIdentifier(for: indexPath), let benchmark = Benchmark.all.first(where: { $0.id == id }) else { return }
        navigationController?.pushViewController(BenchmarkRunViewController(benchmark: benchmark), animated: true)
    }
}

/// 1つのベンチマークを走らせる画面。上の枠で測り、結果をコピーできるテキストで出す。
final class BenchmarkRunViewController: UIViewController {
    private let benchmark: Benchmark
    private let stage = UIView()
    private let runButton = UIButton(configuration: .filled())
    private let resultView = UITextView()
    private var task: Task<Void, Never>?
    private var deactivationObserver: (any NSObjectProtocol)?

    init(benchmark: Benchmark) {
        self.benchmark = benchmark
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = benchmark.title
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "コピー", image: UIImage(systemName: "doc.on.doc"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            UIPasteboard.general.string = resultView.text
        })
        navigationItem.rightBarButtonItem?.isEnabled = false

        stage.backgroundColor = .secondarySystemBackground
        stage.layer.cornerRadius = 12
        stage.clipsToBounds = true
        runButton.configuration?.title = "実行"
        runButton.addAction(UIAction { [weak self] _ in self?.start() }, for: .primaryActionTriggered)
        resultView.isEditable = false
        resultView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultView.backgroundColor = .clear

        let stack = UIStackView(arrangedSubviews: [stage, runButton, resultView])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stage.heightAnchor.constraint(equalToConstant: 200),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            task?.cancel()
        }
    }

    private func start() {
        guard task == nil else { return }
        runButton.isEnabled = false
        runButton.configuration?.title = "実行中"
        navigationItem.rightBarButtonItem?.isEnabled = false
        resultView.text = ""
        // 裏に回る間も時間は進むのに表示の時計は止まるため、途中までの値が測れたように見えてしまう。止めてやり直してもらう。
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: view.window?.windowScene,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.task?.cancel()
            }
        }
        let benchmark = benchmark
        task = Task { [weak self] in
            guard let self else { return }
            let header = [benchmark.title] + Self.environment(screen: view.window?.screen)
            do {
                let body = try await benchmark.run(stage)
                resultView.text = (header + body).joined(separator: "\n")
                navigationItem.rightBarButtonItem?.isEnabled = true
            } catch is CancellationError {
                resultView.text = "計測の途中でアプリがアクティブでなくなったため、止めました。もう一度実行してください。"
            } catch {
                resultView.text = (header + ["失敗: \(error)"]).joined(separator: "\n")
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            finish()
        }
    }

    private func finish() {
        deactivationObserver.map(NotificationCenter.default.removeObserver)
        deactivationObserver = nil
        runButton.isEnabled = true
        runButton.configuration?.title = "実行"
        task = nil
    }

    /// 結果を読むのに要る、ビルドと端末と画面の情報。
    private static func environment(screen: UIScreen?) -> [String] {
        let device = UIDevice.current
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "オン" : "オフ"
        return [
            "ビルド: \(BuildInfo.current.text)",
            "端末: \(DeviceModel.identifier) \(device.systemName) \(device.systemVersion)",
            "画面の最大フレームレート: \(screen?.maximumFramesPerSecond ?? 0) 低電力モード: \(lowPower)",
        ]
    }
}
