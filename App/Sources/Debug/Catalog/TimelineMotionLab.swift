import SciaCore
import UIKit

/// 投稿の高さが変わる、新着が入る、メニューを開いている、を手で組み合わせて、読んでいる位置と動きを確かめる画面。
/// 実物の`TimelineViewController`に番号付きの投稿を並べ、モデルを通さずに、並びと描き直しを実物と同じ入口から渡す。
final class TimelineMotionLabViewController: UIViewController {
    /// 高さが変わった投稿を描き直す経路。実物では、変化の種類で経路が決まる。
    private enum Route: Int, CaseIterable {
        /// 並びの置き換えで、中身が変わった投稿を動かさずに描き直す（投稿の編集など）。
        case plain
        /// 下の投稿ごと動かしてつなぐ（カスタム絵文字が届いたときなど）。
        case shifting
        /// 取り直した投稿として、高さを動かして描き直す（リンクカードが届いたときなど）。
        case animatingHeight

        var title: String {
            switch self {
            case .plain: "動かさない"
            case .shifting: "下を動かす"
            case .animatingHeight: "高さを動かす"
            }
        }
    }

    private static let postCount = 20
    private static let linesPerStep = 5
    private static let delay: TimeInterval = 3
    private static let benchmarkRounds = 5
    /// 1回ごとにコマの間隔を測る長さ。動きが止まるのを待つ長さにもなる。
    private static let benchmarkWindow: CFTimeInterval = 0.8
    /// 「下を動かす」で像を取る投稿を絞るときに渡す、伸び縮みする長さの上限。5行の本文より大きめにする。
    private static let shiftLimit: CGFloat = 240

    private let timeline = TimelineViewController(texts: .home, refresh: {})
    private let account = CatalogFixtures.account(displayName: "実験のアカウント", acct: "lab@example.com")
    /// 上から並べる投稿の番号。新着は負の番号で先頭に足す。
    private var numbers = Array(1...postCount)
    private var extraLines: [Int: Int] = [:]
    private var entries: [TimelineEntry] = []
    private var arrivalCount = 0
    private var target = 1

    private let panel = UIStackView()
    private let targetLabel = UILabel()
    private let delaySwitch = UISwitch()
    private let routeControl = UISegmentedControl(items: Route.allCases.map(\.title))
    private let menuSwitch = UISwitch()
    private let limitSwitch = UISwitch()
    private let stateLabel = UILabel()
    private let measureLabel = UILabel()
    private var stateTimer: Timer?
    private var probe: FrameProbe?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "タイムラインの動きの実験"
        view.backgroundColor = .systemBackground
        addChild(timeline)
        timeline.view.frame = view.bounds
        timeline.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(timeline.view)
        timeline.didMove(toParent: self)
        timeline.setContentState(.loaded)
        timeline.setFooterState(.reachedEnd)
        entries = makeEntries()
        timeline.setEntries(entries)
        installPanel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let covered = view.bounds.maxY - view.safeAreaInsets.bottom - panel.frame.minY
        if abs(timeline.additionalSafeAreaInsets.bottom - covered) > 0.5 {
            timeline.additionalSafeAreaInsets.bottom = covered
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStateLabel() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stateTimer?.invalidate()
        stateTimer = nil
    }

    // MARK: - 並び

    private static func id(_ number: Int) -> Status.ID {
        "lab-\(number)"
    }

    private static func name(_ number: Int) -> String {
        number > 0 ? "投稿\(number)" : "新着\(-number)"
    }

    private func status(_ number: Int) -> Status {
        let name = Self.name(number)
        let extra = (0..<(extraLines[number] ?? 0)).map { "<p>足した行\($0 + 1)</p>" }.joined()
        return Status(
            id: Self.id(number),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            account: account,
            content: "<p>\(name)</p><p>高さが変わる前の本文。読んでいる位置の目印にする。</p>\(extra)",
            spoilerText: "",
            url: nil
        )
    }

    private func makeEntries() -> [TimelineEntry] {
        numbers.map { .status(status($0)) }
    }

    // MARK: - 操作

    /// 「3秒後に行う」がオンなら、実物のメニューを開く時間をおいてから行う。
    private func perform(_ action: @escaping @MainActor () -> Void) {
        guard delaySwitch.isOn else {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { action() }
    }

    /// 操作の呼び出しにかかった時間と、そのあと1秒のコマの間隔を測って出す。
    /// コマの間隔はメインスレッドで測るので、描画のプロセスで進む動き（スプリングや切り抜き）そのものの重さは出ない。
    private func measure(_ name: String, _ action: () -> Void) {
        let start = CACurrentMediaTime()
        action()
        let call = CACurrentMediaTime() - start
        probe?.stop()
        probe = FrameProbe(start: start) { [weak self] result in
            self?.measureLabel.text = String(
                format: "%@: 呼び出し %.1fms 最初のコマまで %.1fms\n以後1秒: 最長のコマ %.1fms 落ちたコマ %d/%d",
                name, call * 1000, result.firstFrame * 1000, result.longest * 1000, result.dropped, result.frames
            )
        }
    }

    private func resizeTarget(by lines: Int) {
        let number = target
        let route = Route(rawValue: routeControl.selectedSegmentIndex) ?? .plain
        perform { [weak self] in self?.resize(number, by: lines, route: route) }
    }

    private func resize(_ number: Int, by lines: Int, route: Route) {
        let limit: CGFloat? = limitSwitch.isOn ? Self.shiftLimit : nil
        measure(route.title + (route == .shifting && limit != nil ? "（像を絞る）" : "")) {
            apply(number, by: lines, route: route, shiftLimit: limit)
        }
    }

    private func apply(_ number: Int, by lines: Int, route: Route, shiftLimit: CGFloat?) {
        let previous = entries
        extraLines[number] = max(0, (extraLines[number] ?? 0) + lines)
        entries = makeEntries()
        switch route {
        case .plain:
            timeline.setEntries(entries)
        case .shifting:
            // 並びは中身を描き直さずに置き換え、描き直しは、カスタム絵文字が届いたときと同じ入口から頼む。
            // 時間は、見比べられるよう「高さを動かす」と同じにする。
            timeline.setEntries(entries, keepingRowContentsOf: previous)
            timeline.reconfigureShiftingRowsBelow(
                [.status(Self.id(number))],
                duration: AppDependencies.tuning.value(of: TuningCatalog.linkCardTransitionDuration),
                shiftLimit: shiftLimit
            )
        case .animatingHeight:
            timeline.refreshedStatusID = Self.id(number)
            timeline.setEntries(entries)
            timeline.refreshedStatusID = nil
        }
    }

    // MARK: - ベンチマーク

    private struct Sample {
        let call: CFTimeInterval
        let frames: FrameProbe.Result
    }

    /// 対象の投稿で、経路ごとに5行足すと減らすを繰り返し、呼び出しの時間とコマの間隔をまとめて出す。結果はクリップボードにも入れる。
    private func runBenchmark() {
        let number = target
        let cases: [(name: String, route: Route, shiftLimit: CGFloat?)] = [
            ("動かさない", .plain, nil),
            ("下を動かす", .shifting, nil),
            ("下を動かす（像を絞る）", .shifting, Self.shiftLimit),
            ("高さを動かす", .animatingHeight, nil),
        ]
        let count = Self.benchmarkRounds * 2
        panel.isUserInteractionEnabled = false
        Task { @MainActor in
            var lines = ["対象: \(Self.name(number))、5行足す・減らすを\(Self.benchmarkRounds)回ずつ"]
            for item in cases {
                var samples: [Sample] = []
                for index in 0..<count {
                    measureLabel.text = "ベンチマーク中: \(item.name) \(index + 1)/\(count)"
                    let lines = index.isMultiple(of: 2) ? Self.linesPerStep : -Self.linesPerStep
                    samples.append(await sample { apply(number, by: lines, route: item.route, shiftLimit: item.shiftLimit) })
                }
                lines.append(Self.summary(item.name, samples))
            }
            let text = lines.joined(separator: "\n")
            measureLabel.text = text
            UIPasteboard.general.string = text
            panel.isUserInteractionEnabled = true
        }
    }

    private func sample(_ action: () -> Void) async -> Sample {
        await withCheckedContinuation { continuation in
            let start = CACurrentMediaTime()
            action()
            let call = CACurrentMediaTime() - start
            probe?.stop()
            probe = FrameProbe(start: start, window: Self.benchmarkWindow) { result in
                continuation.resume(returning: Sample(call: call, frames: result))
            }
        }
    }

    private static func summary(_ name: String, _ samples: [Sample]) -> String {
        func median(_ values: [CFTimeInterval]) -> Double {
            values.sorted()[values.count / 2] * 1000
        }
        let calls = samples.map(\.call)
        return String(
            format: "%@: 呼び出し 中央%.1f 最大%.1fms / 最初のコマ 中央%.1fms / 最長のコマ %.1fms 落ち %d/%d",
            name, median(calls), (calls.max() ?? 0) * 1000, median(samples.map(\.frames.firstFrame)),
            (samples.map(\.frames.longest).max() ?? 0) * 1000, samples.map(\.frames.dropped).reduce(0, +), samples.map(\.frames.frames).reduce(0, +)
        )
    }

    private func toggleActionBar() {
        let number = target
        perform { [weak self] in
            guard let self else { return }
            measure("アクションバー") { timeline.toggleActionBar(for: .status(Self.id(number))) }
        }
    }

    private func addArrival() {
        perform { [weak self] in
            guard let self else { return }
            arrivalCount += 1
            numbers.insert(-arrivalCount, at: 0)
            entries = makeEntries()
            measure("新着") { timeline.setEntries(entries) }
        }
    }

    private func setMenuFlag(_ isOn: Bool) {
        if isOn {
            timeline.menuWillShow()
        } else {
            timeline.menuDidHide()
        }
    }

    // MARK: - 操作盤

    private func installPanel() {
        targetLabel.font = .preferredFont(forTextStyle: .subheadline)
        updateTargetLabel()
        // 投稿のタップで対象を選ぶ。タップに割り当てた操作も確かめられるよう、タイムラインのタップは止めない。
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectTarget))
        tap.cancelsTouchesInView = false
        timeline.collectionView.addGestureRecognizer(tap)
        routeControl.selectedSegmentIndex = Route.plain.rawValue
        menuSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setMenuFlag(menuSwitch.isOn)
        }, for: .valueChanged)
        stateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 0
        measureLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        measureLabel.numberOfLines = 0
        measureLabel.text = "操作すると、かかった時間が出る"

        let buttons = UIStackView(arrangedSubviews: [
            button("\(Self.linesPerStep)行足す") { [weak self] in self?.resizeTarget(by: Self.linesPerStep) },
            button("\(Self.linesPerStep)行減らす") { [weak self] in self?.resizeTarget(by: -Self.linesPerStep) },
            button("アクションバー") { [weak self] in self?.toggleActionBar() },
            button("新着") { [weak self] in self?.addArrival() },
        ])
        let benchmark = button("ベンチマーク（3つの経路を順に測る）") { [weak self] in self?.runBenchmark() }
        buttons.spacing = 6
        buttons.distribution = .fillProportionally

        panel.axis = .vertical
        panel.spacing = 8
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        panel.addArrangedSubview(targetLabel)
        panel.addArrangedSubview(routeControl)
        panel.addArrangedSubview(buttons)
        panel.addArrangedSubview(benchmark)
        panel.addArrangedSubview(row(label("\(Int(Self.delay))秒後に行う（実物のメニューを開く時間）"), delaySwitch))
        panel.addArrangedSubview(row(label("メニューを開いている扱いにする"), menuSwitch))
        panel.addArrangedSubview(row(label("「下を動かす」で像を取る投稿を絞る"), limitSwitch))
        panel.addArrangedSubview(stateLabel)
        panel.addArrangedSubview(measureLabel)

        let background = UIView()
        background.backgroundColor = .secondarySystemBackground
        background.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background)
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            background.topAnchor.constraint(equalTo: panel.topAnchor),
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func label(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 0
        return label
    }

    private func row(_ leading: UIView, _ trailing: UIView) -> UIStackView {
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [leading, trailing])
        row.alignment = .center
        row.spacing = 8
        return row
    }

    private func button(_ title: String, _ action: @escaping @MainActor () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        configuration.buttonSize = .small
        configuration.titleLineBreakMode = .byTruncatingTail
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    @objc private func selectTarget(_ tap: UITapGestureRecognizer) {
        let collectionView = timeline.collectionView
        guard let indexPath = collectionView.indexPathForItem(at: tap.location(in: collectionView)),
              case .status(let id) = timeline.itemID(at: indexPath),
              let number = numbers.first(where: { Self.id($0) == id })
        else { return }
        target = number
        updateTargetLabel()
    }

    private func updateTargetLabel() {
        targetLabel.text = "対象: \(Self.name(target))（投稿をタップして選ぶ）"
    }

    private func updateStateLabel() {
        let wanted = ["anchor:", "isAtTop:", "showingMenu:"]
        stateLabel.text = timeline.stateDump()
            .split(separator: "\n")
            .filter { line in wanted.contains { line.hasPrefix($0) } }
            .joined(separator: "\n")
    }
}

/// 始めた時刻から最初のコマまでの時間と、そのあと1秒のコマの間隔を測る。
@MainActor
private final class FrameProbe: NSObject {
    struct Result {
        var firstFrame: CFTimeInterval = 0
        var longest: CFTimeInterval = 0
        var dropped = 0
        var frames = 0
    }


    private let start: CFTimeInterval
    private let window: CFTimeInterval
    private let onFinish: (Result) -> Void
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var result = Result()

    init(start: CFTimeInterval, window: CFTimeInterval = 1, onFinish: @escaping (Result) -> Void) {
        self.start = start
        self.window = window
        self.onFinish = onFinish
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // 指定しないと、120Hzの画面でも60Hzで呼ばれ、動きの間だけ画面が120Hzになると、間隔の見込みと合わずに落ちたコマに数えてしまう。
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard let previous else {
            result.firstFrame = now - start
            previous = now
            return
        }
        let interval = now - previous
        self.previous = now
        result.frames += 1
        result.longest = max(result.longest, interval)
        // 画面の更新の間隔の1.5倍を超えたコマを、落ちたコマに数える。
        if interval > (link.targetTimestamp - link.timestamp) * 1.5 {
            result.dropped += 1
        }
        if now - start >= window {
            stop()
            onFinish(result)
        }
    }
}
