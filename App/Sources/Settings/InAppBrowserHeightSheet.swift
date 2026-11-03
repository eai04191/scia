import SciaCore
import SwiftUI
import UIKit

/// ホームの上に出す、アプリ内のSafariの高さを決めるシート。シートの上端そのものをスライダーにし、つまみを引いて止めた位置を高さにする。
/// 上に空ける長さの刻み（`InAppBrowserHeight.step`）ごとに段を並べ、引いた位置にいちばん近い段で止める。いちばん下は伏せた高さ。
/// 全画面の段は並べない。並べると、iOS 26のシミュレーターではシートが画面の下と左右の端に付いた形になり、アプリ内のSafariと見え方が合わなくなったため。
/// 最初から全画面で開くかは、シートの中のスイッチで決める。
/// 段はアプリ内のSafariと同じ式と同じ元の高さで決めるので、止めたシートの上に、リンクを開いたときと同じだけホームが見える。
/// 見た目はアプリ内のSafariのシートに寄せ、上の帯に題名と完了のボタンを置く。
final class InAppBrowserHeightSheet: UIHostingController<InAppBrowserHeightChoices>, UISheetPresentationControllerDelegate {
    private let settings: AppSettings
    private let tuning: TuningStore
    /// 出した窓。アプリ内のSafariと同じく、段を決めるたびに、この窓の安全領域の中の高さから決める。
    private weak var window: UIWindow?
    /// 段に並べた上に空ける長さ。窓で決められる長さで、窓の大きさが変わったら並べ直す。
    private var spaces: [Double] = []
    /// シートが画面の下から覆っている高さが変わったときに呼ぶ。出したとき、段を移したとき、閉じたとき（0）に呼ぶ。
    var onObscuredHeightChange: ((CGFloat) -> Void)? {
        didSet { reportObscuredHeight() }
    }

    /// - Parameters:
    ///   - window: 出す窓。アプリ内のSafariと同じく、窓の安全領域の中の高さから段を決める。
    ///   - onClose: 完了のボタンを押したときに呼ぶ。閉じるのは呼んだ側が行う。
    init(settings: AppSettings, tuning: TuningStore = AppDependencies.tuning, window: UIWindow, onClose: @escaping () -> Void) {
        self.settings = settings
        self.tuning = tuning
        self.window = window
        super.init(rootView: InAppBrowserHeightChoices(settings: settings, onClose: onClose))
        modalPresentationStyle = .pageSheet
        // 閉じたあとに設定へ戻すので、スワイプで閉じさせず、完了のボタンを通す。
        isModalInPresentation = true
        if let sheet = sheetPresentationController {
            arrangeDetents(of: sheet)
            sheet.prefersGrabberVisible = true
            // 中身のスクロールでシートを広げない。広げると、高さを決める操作になって保存した高さが変わる。高さはつまみを引いたときだけ変える。
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.delegate = self
        }
        followSelection()
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func identifier(of space: Double) -> UISheetPresentationController.Detent.Identifier {
        .init("net.mizle.scia.inAppBrowserHeight.\(Int(space))")
    }

    /// 伏せた高さ。中くらいの高さの下の端。
    private var minimum: Double {
        tuning.value(of: TuningCatalog.inAppBrowserCollapsedHeight)
    }

    /// 窓で決められる長さごとに段を並べ、設定の高さの段を選ぶ。段は低い順に並べる決まりがあるため、上に空ける長さの長い順に並べる。
    private func arrangeDetents(of sheet: UISheetPresentationController) {
        guard let window else { return }
        spaces = InAppBrowserHeight.selectableSpaces(available: Double(window.safeAreaHeight), minimum: minimum)
        sheet.detents = spaces.reversed().map { space in
            .custom(identifier: Self.identifier(of: space)) { [weak self] context in
                self?.height(spaceAbove: space, in: context)
            }
        }
        sheet.selectedDetentIdentifier = Self.identifier(of: selectableHeight.spaceAbove)
        // アプリ内のSafariと同じく、後ろを暗くせず、ホームを触れるままにする。
        sheet.largestUndimmedDetentIdentifier = spaces.first.map(Self.identifier(of:))
    }

    /// 段の高さ。並べ直すまでのあいだに窓の大きさが変わって、決められなくなった段はnilにして出さない。
    private func height(spaceAbove space: Double, in context: any UISheetPresentationControllerDetentResolutionContext) -> CGFloat? {
        guard let window else { return nil }
        let available = Double(window.safeAreaHeight)
        guard InAppBrowserHeight.selectableSpaces(available: available, minimum: minimum).contains(space) else { return nil }
        return min(CGFloat(InAppBrowserHeight(spaceAbove: space).sheetHeight(available: available, minimum: minimum)), context.maximumDetentValue)
    }

    /// 設定の高さを、この窓で決められる範囲に寄せたもの。ほかの端末で決めた長さが、この窓では引ききれないときに寄せる。
    private var selectableHeight: InAppBrowserHeight {
        guard let window else { return settings.inAppBrowserHeight }
        return settings.inAppBrowserHeight.clamped(available: Double(window.safeAreaHeight), minimum: minimum)
    }

    /// 「標準に戻す」を押したら、その段へ動かす。
    private func followSelection() {
        withObservationTracking {
            _ = settings.inAppBrowserHeight
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                guard let self, let sheet = self.sheetPresentationController else { return }
                let identifier = Self.identifier(of: self.selectableHeight.spaceAbove)
                if sheet.selectedDetentIdentifier != identifier {
                    sheet.animateChanges { sheet.selectedDetentIdentifier = identifier }
                    self.reportObscuredHeight()
                }
                self.followSelection()
            }
        }
    }

    /// つまみを引いて止めたら、その高さにする。
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
        if let space = spaces.first(where: { Self.identifier(of: $0) == sheet.selectedDetentIdentifier }) {
            settings.inAppBrowserHeight = InAppBrowserHeight(spaceAbove: space)
        }
        reportObscuredHeight()
    }

    /// 完了のボタンのほか、ほかの画面を開くためにまとめて閉じたときも、覆うのをやめたと知らせる。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onObscuredHeightChange?(0)
    }

    /// 窓の大きさが変わると決められる長さも変わるので、段を並べ直し、覆う高さを知らせ直す。
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, let sheet = sheetPresentationController else { return }
            sheet.animateChanges { self.arrangeDetents(of: sheet) }
            reportObscuredHeight()
        }
    }

    /// 段の高さは安全領域の中の高さなので、アプリ内のSafariと同じく、下の安全領域を足して知らせる。
    private func reportObscuredHeight() {
        guard let window, !isBeingDismissed else { return }
        onObscuredHeightChange?(CGFloat(selectableHeight.sheetHeight(available: Double(window.safeAreaHeight), minimum: minimum)) + window.safeAreaInsets.bottom)
    }
}

/// シートの中身。高さはシートの上端で決めるので、中には今の値と、最初から全画面で開くスイッチ、標準に戻すボタン、説明を置く。
/// どれもシートの上から並べるので、シートの高さを変えても位置は動かない。
struct InAppBrowserHeightChoices: View {
    @Bindable var settings: AppSettings
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("上の余白", value: settings.inAppBrowserHeight.title)
                    Button("標準に戻す") { settings.inAppBrowserHeight = .standard }
                        .disabled(settings.inAppBrowserHeight == .standard)
                } footer: {
                    Text("シートを上下にドラッグしてリンクを開いたときの高さを調整します。")
                }
                Section {
                    Toggle("最初から全画面で開く", isOn: $settings.opensInAppBrowserFullScreen)
                }
            }
            // アプリ内のSafariのシートと同じく、後ろのホームを透かさない。透けると、シートの上に見える量が分かりにくい。
            // シートの背景は塗り替えず、中身を塗る。背景を塗り替えると、シートのフチと影まで消え、白い一覧に溶けてシートに見えないため。
            .background(Color(uiColor: .systemBackground))
            // アプリ内のSafariのシートと同じく、上の帯と中身のあいだに区切り線を引く。
            .safeAreaInset(edge: .top, spacing: 0) { Divider() }
            .navigationTitle("アプリ内のSafariの高さ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 引いて決めた高さを確かめて閉じるので、取りやめのバツではなく、確定のチェックマークにする。
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", systemImage: "checkmark", action: onClose)
                }
            }
        }
    }
}
