import SciaCore
import UIKit

/// 投稿の高さが変わる、新着が入る、メニューを開いている、を手で組み合わせて、読んでいる位置と動きを確かめる画面。
/// 実物の`TimelineViewController`に番号付きの投稿を並べ、モデルを通さずに、並びと描き直しを実物と同じ入口から渡す。
final class TimelineMotionLabViewController: UIViewController {
    private static let postCount = 20
    private static let linesPerStep = 5
    private static let delay: TimeInterval = 3
    /// 毎秒の編集で、投稿の本文の途中に入れる行の数。伸びる、縮む、途中の行が足される、削られる、を順に起こす。
    private static let autoEditLines = [3, 1, 5, 0, 2]
    private static let benchmarkRounds = 5
    /// 1回ごとにコマの間隔を測る長さ。動きが止まるのを待つ長さにもなる。
    private static let benchmarkWindow: CFTimeInterval = 0.8
    private let timeline = TimelineViewController(texts: .home, refresh: {})
    private let account = CatalogFixtures.account(displayName: "実験のアカウント", acct: "lab@example.com")
    /// 上から並べる投稿の番号。新着は負の番号で先頭に足す。
    private var numbers = Array(1...postCount)
    private var extraLines: [Int: Int] = [:]
    /// リンクカードを付けている投稿の番号。
    private var carded: Set<Int> = []
    private var entries: [TimelineEntry] = []
    private var arrivalCount = 0
    private var target = 1

    private let panel = UIStackView()
    private let targetLabel = UILabel()
    private let delaySwitch = UISwitch()
    private let menuSwitch = UISwitch()
    private let autoEditSwitch = UISwitch()
    private var autoEditTimer: Timer?
    private var autoEditStep = 0
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
        autoEditTimer?.invalidate()
        autoEditTimer = nil
        autoEditSwitch.isOn = false
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
            // 足す行は本文の途中に入れる。前後の文字が、編集で動くところを見られる。
            content: "<p>\(name)</p>\(extra)<p>高さが変わる前の本文。読んでいる位置の目印にする。</p>",
            spoilerText: "",
            url: nil,
            card: carded.contains(number) ? Self.card : nil
        )
    }

    /// 通信しないで出せるよう、画像のないカードにする。
    private static let card = URL(string: "https://news.example/articles/lab").map {
        PreviewCard(url: $0, title: "実験のリンクカード", description: "投稿に部品が現れたり消えたりする動きを見る。", type: .link, providerName: "", image: nil, width: 0, height: 0, blurhash: nil)
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
        perform { [weak self] in
            guard let self else { return }
            measure(lines > 0 ? "\(lines)行足す" : "\(-lines)行減らす") { apply(number, by: lines) }
        }
    }

    /// 対象の投稿の本文を伸び縮みさせ、投稿が編集されたときと同じ入口から並びを渡す。
    private func apply(_ number: Int, by lines: Int) {
        extraLines[number] = max(0, (extraLines[number] ?? 0) + lines)
        entries = makeEntries()
        timeline.setEntries(entries)
    }

    // MARK: - ベンチマーク

    private struct Sample {
        let call: CFTimeInterval
        let frames: FrameProbe.Result
    }

    /// 対象の投稿で、5行足すと減らすを繰り返し、呼び出しの時間とコマの間隔をまとめて出す。結果はクリップボードにも入れる。
    private func runBenchmark() {
        let number = target
        let count = Self.benchmarkRounds * 2
        panel.isUserInteractionEnabled = false
        Task { @MainActor in
            var samples: [Sample] = []
            for index in 0..<count {
                measureLabel.text = "ベンチマーク中: \(index + 1)/\(count)"
                let lines = index.isMultiple(of: 2) ? Self.linesPerStep : -Self.linesPerStep
                samples.append(await sample { apply(number, by: lines) })
            }
            let text = Self.summary("\(Self.name(number))、\(Self.linesPerStep)行足す・減らすを\(Self.benchmarkRounds)回ずつ", samples)
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

    /// 対象の投稿のリンクカードを付け外しし、取り直した投稿が届いたときと同じ入口から並びを渡す。
    private func toggleCard() {
        let number = target
        perform { [weak self] in
            guard let self else { return }
            measure(carded.contains(number) ? "カードを外す" : "カードを付ける") {
                carded.formSymmetricDifference([number])
                entries = makeEntries()
                timeline.setEntries(entries)
            }
        }
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

    /// オンにしたときの対象の投稿を、毎秒編集して高さを変え続ける。スクロールして、投稿が画面のどこにあるときの動きも見られる。
    private func setAutoEdit(_ isOn: Bool) {
        autoEditTimer?.invalidate()
        autoEditTimer = nil
        guard isOn else { return }
        let number = target
        autoEditTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.editAutomatically(number) }
        }
    }

    private func editAutomatically(_ number: Int) {
        extraLines[number] = Self.autoEditLines[autoEditStep % Self.autoEditLines.count]
        autoEditStep += 1
        entries = makeEntries()
        timeline.setEntries(entries)
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
            button("+\(Self.linesPerStep)行") { [weak self] in self?.resizeTarget(by: Self.linesPerStep) },
            button("-\(Self.linesPerStep)行") { [weak self] in self?.resizeTarget(by: -Self.linesPerStep) },
            button("カード") { [weak self] in self?.toggleCard() },
            button("アクションバー") { [weak self] in self?.toggleActionBar() },
            button("新着") { [weak self] in self?.addArrival() },
        ])
        let benchmark = button("ベンチマーク") { [weak self] in self?.runBenchmark() }
        buttons.spacing = 6
        buttons.distribution = .fillProportionally

        panel.axis = .vertical
        panel.spacing = 8
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        panel.addArrangedSubview(targetLabel)
        panel.addArrangedSubview(buttons)
        panel.addArrangedSubview(benchmark)
        panel.addArrangedSubview(row(label("\(Int(Self.delay))秒後に行う（実物のメニューを開く時間）"), delaySwitch))
        panel.addArrangedSubview(row(label("メニューを開いている扱いにする"), menuSwitch))
        autoEditSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setAutoEdit(autoEditSwitch.isOn)
        }, for: .valueChanged)
        panel.addArrangedSubview(row(label("対象の投稿を毎秒編集する"), autoEditSwitch))
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
    private var hitches = HitchCounter()

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

    /// 測るのをやめ、そこまでの結果を渡す。待っている側を、結果を渡さずに残さない。
    func stop() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        result.dropped = hitches.summary.droppedFrames
        onFinish(result)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        hitches.record(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        guard let previous else {
            result.firstFrame = now - start
            previous = now
            return
        }
        let interval = now - previous
        self.previous = now
        result.frames += 1
        result.longest = max(result.longest, interval)
        if now - start >= window {
            stop()
        }
    }
}
