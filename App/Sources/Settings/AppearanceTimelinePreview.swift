import SciaCore
import SwiftUI
import UIKit

/// 「投稿の見た目」のプレビュー。見本を並べたタイムラインの一覧（`AppearanceSamples.timeline`）を子に置く。
/// 区切り線、返信の線、光のように一覧が決める見た目も、タイムラインと同じになる。決まりはdocs/appearance.mdの「プレビュー」にある。
final class AppearanceTimelinePreviewController: UIViewController {
    let timeline: TimelineViewController
    /// `fitRevision`が変わったときと幅が変わったときに、並べた見本の高さを渡す。値を変えて見本の高さが変わっても呼ばない。
    var onFitHeight: ((CGFloat) -> Void)?
    private var entries: [TimelineEntry] = []
    /// 前に並べたときの、高さを合わせ直すきっかけ。
    private var fitRevision: Int?
    /// 高さを渡した幅。nilなら、次に並べたときに渡す。
    private var fittedWidth: CGFloat?

    init(timeline: TimelineViewController) {
        self.timeline = timeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(timeline)
        timeline.view.frame = view.bounds
        timeline.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(timeline.view)
        timeline.didMove(toParent: self)
    }

    /// 見本を並べる。触っている間だけ足した見本は、そこまでスクロールして見せる。
    /// - Parameter fitRevision: 高さを合わせ直すきっかけ。変わったときは、並べた見本の高さを`onFitHeight`で渡し直す。
    func apply(entries: [TimelineEntry], fitRevision: Int) {
        loadViewIfNeeded()
        if self.fitRevision != fitRevision {
            self.fitRevision = fitRevision
            fittedWidth = nil
            view.setNeedsLayout()
        }
        guard entries != self.entries else { return }
        let added = entries.filter { entry in !self.entries.contains { $0.id == entry.id } }
        let isFirst = self.entries.isEmpty
        self.entries = entries
        timeline.setEntries(entries)
        if !isFirst, case .status(let status)? = added.first {
            timeline.scrollToStatus(status.id, at: .top)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let onFitHeight, view.bounds.width > 0, fittedWidth != view.bounds.width else { return }
        fittedWidth = view.bounds.width
        timeline.view.layoutIfNeeded()
        timeline.collectionView.layoutIfNeeded()
        let height = timeline.collectionView.collectionViewLayout.collectionViewContentSize.height
        // 並べている最中にSwiftUIの状態を変えないよう、並べ終えてから渡す。
        DispatchQueue.main.async {
            onFitHeight(height)
        }
    }
}

struct AppearanceTimelinePreview: UIViewControllerRepresentable {
    let samples: AppearanceSamples
    let entries: [TimelineEntry]
    /// 見本を描く外観。外観ごとにしか効かない項目を触っている間だけ、端末の外観と違うものにする。
    var interfaceStyle: UIUserInterfaceStyle = .unspecified
    var fitRevision = 0
    let onFitHeight: (CGFloat) -> Void

    func makeUIViewController(context: Context) -> AppearanceTimelinePreviewController {
        AppearanceTimelinePreviewController(timeline: samples.timeline)
    }

    func updateUIViewController(_ controller: AppearanceTimelinePreviewController, context: Context) {
        controller.onFitHeight = onFitHeight
        controller.timeline.overrideUserInterfaceStyle = interfaceStyle
        controller.apply(entries: entries, fitRevision: fitRevision)
    }
}

/// 見本が収まる高さにし、収まらなければ上限の高さの中でスクロールさせるプレビュー。
/// 高さは、画面に出たときと`fitRevision`が変わったときだけ合わせ直し、値を変えている間は変えない。
/// 変えると下の項目の一覧が動き、スライダーなどの操作している部品が指の下から動いてしまうため。
struct FittedAppearancePreview: View {
    let samples: AppearanceSamples
    let entries: [TimelineEntry]
    var interfaceStyle: UIUserInterfaceStyle = .unspecified
    let heightLimit: CGFloat
    var fitRevision = 0
    @State private var height: CGFloat?
    /// 画面に出た回数。重ねた画面から戻ったときは、そこで変えた値で見本の高さが変わっているので、合わせ直す。
    @State private var appearances = 0

    var body: some View {
        var hasher = Hasher()
        hasher.combine(fitRevision)
        hasher.combine(appearances)
        return AppearanceTimelinePreview(samples: samples, entries: entries, interfaceStyle: interfaceStyle, fitRevision: hasher.finalize(), onFitHeight: fit)
            .frame(height: min(height ?? .infinity, heightLimit))
            .onAppear { appearances += 1 }
    }

    /// 最初の高さは、動かさずに合わせる。
    private func fit(_ newHeight: CGFloat) {
        guard height != nil else {
            height = newHeight
            return
        }
        withAnimation(.smooth) { height = newHeight }
    }
}
