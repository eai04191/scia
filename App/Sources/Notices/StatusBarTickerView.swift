import os
import SciaCore
import UIKit

/// 画面の上端の、ステータスバーが使っている場所の形。ステータスバーの通知を、この形に合わせて描く。
enum StatusBarCutout: Equatable {
    /// Dynamic Island。枠は画面の座標。`sideMargin`は、広げたカプセルの左右の余白。
    case island(CGRect, sideMargin: CGFloat)
    /// ノッチ。枠は画面の座標で、上端は画面の上端。
    case notch(CGRect)
    /// 切り欠きがなく、ステータスバーが横幅いっぱいにある（iPhone SE、iPad）。
    case none(height: CGFloat)

    /// この機種でステータスバーの通知を出せるか。iPhoneでは、アイランドとノッチの値を測った機種と、切り欠きのない機種だけで出せる。
    /// 表にない機種では、切り欠きの位置と大きさを推し量ると切り欠きとずれた黒を描くため、出さずに、設定画面で使えないことを伝える。
    @MainActor
    static var isAvailable: Bool {
        UIDevice.current.userInterfaceIdiom != .phone || DeviceModel.isMeasured(DeviceModel.identifier)
    }

    /// 今の画面の形。ステータスバーが出ない向き（iPhoneの横向き）と、`isAvailable`でない機種ではnil。
    /// アイランドとノッチの位置と画面の角の形を返すAPIはないため、機種の識別子で`IslandModel`と`NotchModel`の表を引く。
    /// 画面の大きさと安全領域では見分けない。iPhone 18 Proは、17 Proと画面の大きさも安全領域も同じで、アイランドの幅だけが違うため。
    @MainActor
    static func current(in window: UIWindow) -> StatusBarCutout? {
        let width = window.bounds.width
        let top = window.safeAreaInsets.top
        guard window.traitCollection.userInterfaceIdiom == .phone else {
            return flatBand(in: window)
        }
        guard window.traitCollection.verticalSizeClass != .compact else { return nil }
        let identifier = DeviceModel.identifier
        if let model = IslandModel.table[identifier] {
            return model.scaled(toWidth: width)
        }
        if let model = NotchModel.table[identifier] {
            return model.scaled(toWidth: width)
        }
        if DeviceModel.flatIdentifiers.contains(identifier) {
            return .none(height: max(top, 20))
        }
        // 次に表へ足す値が分かるよう、機種と画面の大きさを残す。
        logger.info("statusBarTicker unmeasured model: \(identifier, privacy: .public) \(width, privacy: .public)x\(window.bounds.height, privacy: .public) top=\(top, privacy: .public)")
        return nil
    }

    /// iPadとMacの、ウィンドウの上端のステータスバーの帯。ステータスバーがウィンドウの上に重なっていなければnil。
    /// 全画面のiPadでは、ステータスバーの高さ（iPad miniで32pt）と安全領域の上端が同じ。Macでは、ステータスバーを描かないが、
    /// ナビゲーションバーの上に同じ高さ（20pt）の安全領域を空けているので、そこに流す。
    /// ウィンドウ表示のiPadでは、ステータスバーは画面の上端にあってウィンドウの上にはなく、`statusBarFrame`は32ptを返すのに、
    /// 安全領域の上端は10ptしかない。流すと、ウィンドウの操作ボタンに重なり、ステータスバーを隠した分の補いで画面が下へずれる。
    @MainActor
    private static func flatBand(in window: UIWindow) -> StatusBarCutout? {
        let height = window.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
        guard height > 0, window.safeAreaInsets.top >= height else { return nil }
        return .none(height: height)
    }

    private static let logger = SciaLog.logger(category: "statusBarTicker")
}

/// アイランドのある機種の、シミュレーターで測った値。値は縦向きの画面の座標（pt）。
/// アイランドの枠は、機種ごとのシミュレーターの画面を`xcrun simctl io <端末> screenshot --mask=black`で撮って測った。
/// 左右の余白は、画面の外形（機種の定義のframebufferMaskのPDF）を、アイランドの上から画面の上端までの余白だけ内側へ縮めた範囲に、
/// カプセルの縦の真ん中の左右の端が収まる最小の値を、1/20pt刻みで測った。
struct IslandModel {
    /// 測ったときの縦向きの画面の大きさ。
    let screen: CGSize
    let island: CGRect
    let sideMargin: CGFloat

    /// 画面の幅が`width`のときの、アイランドの枠と左右の余白。
    /// 「拡大表示」の「文字を拡大」では、画面の画素は同じまま、1ptあたりの画素が増えて画面のptが狭くなる。
    /// iPhone 16 Proの実機では、402×874ptが320×693ptになり、1ptあたりの画素は3から3.76875（1206画素÷320pt）になった。
    /// 横は画素の幅とptの幅がちょうど対応するので、測った値を画面の幅の比で縮めれば、同じ画素を指す。
    /// 縦は693ptが2611.7画素で、画面の2622画素より約10画素足りないが、上端から同じ比で縮めればよい。
    /// 拡大表示のシミュレーターで、広げたカプセルの上下の端がアイランドと同じ画素（42〜151）に、左右の端が式どおりの画素に来ることを確かめた。
    func scaled(toWidth width: CGFloat) -> StatusBarCutout {
        let ratio = width / screen.width
        let rect = CGRect(x: island.minX * ratio, y: island.minY * ratio, width: island.width * ratio, height: island.height * ratio)
        return .island(rect, sideMargin: sideMargin * ratio)
    }

    // 画面の大きさと角の形が同じ機種は、同じ値になる。
    /// iPhone 14 Pro、15、15 Pro、16（393×852pt）。
    private static let pro61 = IslandModel(screen: CGSize(width: 393, height: 852), island: CGRect(x: 134, y: 11.33, width: 125, height: 36.67), sideMargin: 19.61)
    /// iPhone 14 Pro Max、15 Plus、15 Pro Max、16 Plus（430×932pt）。
    private static let proMax67 = IslandModel(screen: CGSize(width: 430, height: 932), island: CGRect(x: 152.33, y: 11.33, width: 125.33, height: 36.67), sideMargin: 19.61)
    /// iPhone 16 Pro、17、17 Pro（402×874pt）。
    private static let pro63 = IslandModel(screen: CGSize(width: 402, height: 874), island: CGRect(x: 138.33, y: 14, width: 125.33, height: 36.67), sideMargin: 24.4)
    /// iPhone 16 Pro Max、17 Pro Max（440×956pt）。
    private static let proMax69 = IslandModel(screen: CGSize(width: 440, height: 956), island: CGRect(x: 157.33, y: 14, width: 125.33, height: 36.67), sideMargin: 24.58)
    /// iPhone Air（420×912pt）。
    private static let air = IslandModel(screen: CGSize(width: 420, height: 912), island: CGRect(x: 147.33, y: 20, width: 125.33, height: 36.67), sideMargin: 28.81)
    /// iPhone 18 Pro（402×874pt）。17 Proと画面は同じで、アイランドが狭い。
    private static let pro18 = IslandModel(screen: CGSize(width: 402, height: 874), island: CGRect(x: 153.67, y: 14, width: 94.67, height: 36.67), sideMargin: 24.4)
    /// iPhone 18 Pro Max（440×956pt）。
    private static let proMax18 = IslandModel(screen: CGSize(width: 440, height: 956), island: CGRect(x: 172.67, y: 14, width: 94.67, height: 36.67), sideMargin: 24.58)

    static let table: [String: IslandModel] = [
        "iPhone15,2": pro61, // iPhone 14 Pro
        "iPhone15,3": proMax67, // iPhone 14 Pro Max
        "iPhone15,4": pro61, // iPhone 15
        "iPhone15,5": proMax67, // iPhone 15 Plus
        "iPhone16,1": pro61, // iPhone 15 Pro
        "iPhone16,2": proMax67, // iPhone 15 Pro Max
        "iPhone17,3": pro61, // iPhone 16
        "iPhone17,4": proMax67, // iPhone 16 Plus
        "iPhone17,1": pro63, // iPhone 16 Pro
        "iPhone17,2": proMax69, // iPhone 16 Pro Max
        "iPhone18,3": pro63, // iPhone 17
        "iPhone18,1": pro63, // iPhone 17 Pro
        "iPhone18,2": proMax69, // iPhone 17 Pro Max
        "iPhone18,4": air, // iPhone Air
        "iPhone19,2": pro18, // iPhone 18 Pro
        "iPhone19,3": proMax18, // iPhone 18 Pro Max
        "iPhone19,7": proMax18, // iPhone 18 Pro Max（機種の定義のrepresentedModelIdentifiersにある、もう1つの識別子）
    ]
}

/// ノッチのある機種の、機種の定義の画面の形（framebufferMaskのPDF）から測った値。値は縦向きの画面の座標（pt）。
/// ノッチは画面の上端の中央にあり、PDFでは画面の外として抜けている。PDFを画面の画素の大きさで描き、画素を1ptあたりの画素で割った。
/// 幅は、画面の縁へつながって広がる上端から4pt以下を除いた、いちばん広いところ（どの機種も上から4pt）。そこから下へ少しずつ細くなるので、文字がノッチにかからない。
/// iPhone 11は、シミュレーターの画面の画像で測った値（高さ33pt、幅230pt）とも合う。
/// iPhone 12 miniと13 miniは、機種の定義の画素（1080×2340）を3で割った360×780ptではなく、375×812ptで描かれる（1ptは2.88画素）。
/// PDFは1125×2436なので、そのまま3で割った。12 miniのシミュレーターの画像を2.88で割った値（高さ34.38pt、幅226.4pt）と合う。
struct NotchModel {
    /// 測ったときの縦向きの画面の大きさ。
    let screen: CGSize
    let notch: CGSize

    /// 画面の幅が`width`のときの、ノッチの枠。拡大表示では、`IslandModel.scaled(toWidth:)`と同じく画面の幅の比で縮める。
    func scaled(toWidth width: CGFloat) -> StatusBarCutout {
        let ratio = width / screen.width
        let size = CGSize(width: notch.width * ratio, height: notch.height * ratio)
        return .notch(CGRect(origin: CGPoint(x: (width - size.width) / 2, y: 0), size: size))
    }

    /// iPhone 11（414×896pt）。
    private static let iPhone11 = NotchModel(screen: CGSize(width: 414, height: 896), notch: CGSize(width: 231, height: 33))
    /// iPhone 11 Pro（375×812pt）。
    private static let pro11 = NotchModel(screen: CGSize(width: 375, height: 812), notch: CGSize(width: 209.67, height: 30))
    /// iPhone 11 Pro Max（414×896pt）。
    private static let proMax11 = NotchModel(screen: CGSize(width: 414, height: 896), notch: CGSize(width: 210, height: 30))
    /// iPhone 12 mini（375×812pt）。
    private static let mini12 = NotchModel(screen: CGSize(width: 375, height: 812), notch: CGSize(width: 227, height: 34.33))
    /// iPhone 12、12 Pro（390×844pt）。
    private static let pro12 = NotchModel(screen: CGSize(width: 390, height: 844), notch: CGSize(width: 210.67, height: 32))
    /// iPhone 12 Pro Max（428×926pt）。
    private static let proMax12 = NotchModel(screen: CGSize(width: 428, height: 926), notch: CGSize(width: 210, height: 32))
    /// iPhone 13 mini（375×812pt）。
    private static let mini13 = NotchModel(screen: CGSize(width: 375, height: 812), notch: CGSize(width: 175, height: 37.33))
    /// iPhone 13、13 Pro、14、16e、17e（390×844pt）。
    private static let pro13 = NotchModel(screen: CGSize(width: 390, height: 844), notch: CGSize(width: 162.67, height: 33.67))
    /// iPhone 13 Pro Max、14 Plus（428×926pt）。
    private static let proMax13 = NotchModel(screen: CGSize(width: 428, height: 926), notch: CGSize(width: 162, height: 33.67))

    static let table: [String: NotchModel] = [
        "iPhone12,1": iPhone11, // iPhone 11
        "iPhone12,3": pro11, // iPhone 11 Pro
        "iPhone12,5": proMax11, // iPhone 11 Pro Max
        "iPhone13,1": mini12, // iPhone 12 mini
        "iPhone13,2": pro12, // iPhone 12
        "iPhone13,3": pro12, // iPhone 12 Pro
        "iPhone13,4": proMax12, // iPhone 12 Pro Max
        "iPhone14,4": mini13, // iPhone 13 mini
        "iPhone14,5": pro13, // iPhone 13
        "iPhone14,2": pro13, // iPhone 13 Pro
        "iPhone14,3": proMax13, // iPhone 13 Pro Max
        "iPhone14,7": pro13, // iPhone 14
        "iPhone14,8": proMax13, // iPhone 14 Plus
        "iPhone17,5": pro13, // iPhone 16e
        "iPhone18,5": pro13, // iPhone 17e
    ]
}

enum DeviceModel {
    /// 切り欠きのないiPhone（iPhone SEの第2世代と第3世代）。
    static let flatIdentifiers: Set<String> = ["iPhone12,8", "iPhone14,6"]

    /// ステータスバーの場所の形を測ってある機種か。
    static func isMeasured(_ identifier: String) -> Bool {
        IslandModel.table[identifier] != nil || NotchModel.table[identifier] != nil || flatIdentifiers.contains(identifier)
    }

    /// 機種の識別子（iPhone17,1など）。シミュレーターでは、まねている機種の識別子。
    static var identifier: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }
}

/// ステータスバーの場所に出す、1件の通知。左に誰が何をしたか、右に対象の投稿の文頭かサムネイルを出す。
/// アイランドとノッチは黒いので、同じ黒を切り欠きから左右に広げ、切り欠きが広がったように見せる。
/// アイランドの機種では、アイランドと同じ丸みのカプセルを浮かせる。画面の外形を、アイランドの上から画面の上端までの余白（iPhone 16 Proで14pt）だけ内側へ縮めた範囲に、
/// カプセルの縦の真ん中の左右の端が収まるところまで広げる。左右の余白が上より狭いと、黒い板が画面の上に貼ってあるように見えたため。
/// 切り欠きのない画面では、黒い帯を張らず、ステータスバーの文字を入れ替えたように、地を透かしてふだんの文字の色で描く。
/// 次の通知へは、文字を上へ送って入れ替える。
final class StatusBarTickerView: UIView, UILargeContentViewerInteractionDelegate {
    /// 画面の描き換えと同じ時間。テストでは差し替える。
    var mediaTime: () -> CFTimeInterval = AppDependencies.mediaTime
    /// 押されたとき。
    var onTap: (() -> Void)?
    /// 出入りの時間。
    var animationDuration: TimeInterval = 0.35

    private(set) var cutout: StatusBarCutout
    private let capsule = UIView()
    private var content: ContentViews?
    /// 背景を広げたり縮めたりしている動き。背景の枠と丸み、中身の位置と濃さを、UIKitと同じスプリングの進み具合から前もって計算し、
    /// 同じ時刻表のキーフレームのアニメーションにして描画に任せる。
    /// 中身は背景の子なので、背景をUIKitのアニメーションで動かして毎コマ中身を合わせると、置いた位置が画面に出るときには背景がもう1コマ動いていて、
    /// その分だけ中身が横にも縦にもずれる。毎コマ自分で動かすと、メインスレッドが重いときにコマが落ち、UIKitのスプリングとも曲線が変わる。
    private var motion: Motion?
    /// 背景の端に合わせて置く中身。広げている途中に次の通知が来ると、入れ替わる2つの中身が並ぶ。
    private var trackedContents: [ContentViews] = []
    /// 入れ替えで薄くなって出ていく途中の中身。入れ替わりの途中に消すときも、背景の端に合わせて置くために持つ。
    private var leavingContents: [ContentViews] = []
    /// 背景と一緒に出入りする中身。濃さも進み具合で決める。広げている途中に入れ替わったらnilにし、入れ替えの薄くする動きに任せる。
    private var fadingContent: ContentViews?
    private(set) var item: StatusBarTickerItem?
    private(set) var isExpanded = false
    /// 長押しの拡大表示で読んでいる間。次の通知へ進めず、消さない。
    private(set) var isHeldForLargeContent = false
    /// 出している通知を読み上げる文。
    var accessibilityText: String? { capsule.accessibilityLabel }

    init(cutout: StatusBarCutout) {
        self.cutout = cutout
        super.init(frame: .zero)
        applyCutoutAppearance()
        capsule.clipsToBounds = true
        capsule.layer.cornerCurve = .continuous
        capsule.alpha = 0
        capsule.isAccessibilityElement = true
        capsule.accessibilityTraits = .button
        capsule.accessibilityHint = "通知タブを開きます"
        capsule.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        // 文字はステータスバーの高さに収めるため、端末の文字の大きさに合わせて大きくできない。タブバーと同じく、
        // 文字を大きくする設定では、長押しで拡大表示（Large Content Viewer）に出し、指を離すと押したことにする。
        capsule.showsLargeContentViewer = true
        capsule.scalesLargeContentImage = true
        addInteraction(UILargeContentViewerInteraction(delegate: self))
        addSubview(capsule)
        AppDependencies.emojiImages.addListener(owner: self) { [weak self] _ in
            self?.content?.render()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCutout(_ cutout: StatusBarCutout) {
        guard cutout != self.cutout else { return }
        self.cutout = cutout
        applyCutoutAppearance()
        setNeedsLayout()
    }

    /// アイランドとノッチの黒に合わせ、文字と記号の色はダークモードの色にする。切り欠きのない画面では、地を透かしてふだんの色にする。
    private func applyCutoutAppearance() {
        if case .none = cutout {
            overrideUserInterfaceStyle = .unspecified
            capsule.backgroundColor = .clear
            // 帯の上から下ろして出し、上へ抜いて消す。iPhoneとiPadでは帯の上は画面の外だが、Macではタイトルバーの上に描かれて見えるため、ウィンドウの外は切る。
            clipsToBounds = true
        } else {
            overrideUserInterfaceStyle = .dark
            capsule.backgroundColor = .black
            clipsToBounds = false
        }
    }

    /// `point`（このビューの座標）を受けるビュー。出ていて、見えているカプセルの上なら、カプセルを返す。ほかの場所の指は、下の画面に通すためnilを返す。
    /// 広げている途中は、カプセルの枠（モデルの値）が先に広がり終わった大きさになっているため、描いている途中の枠で決める。
    func tapTarget(at point: CGPoint) -> UIView? {
        let visible = capsule.layer.presentation()?.frame ?? capsule.frame
        guard isExpanded, visible.contains(point) else { return nil }
        return capsule
    }

    /// 通知を出す。出ていれば、文字を上へ送って入れ替える。
    /// 「視差効果を減らす」がオンなら、動かさずに薄くして入れ替え、カプセルも広げずに浮かび上がらせる。
    func show(_ item: StatusBarTickerItem, animated: Bool) {
        self.item = item
        let incoming = ContentViews(item: item, metrics: metrics)
        capsule.addSubview(incoming.left)
        capsule.addSubview(incoming.right)
        capsule.accessibilityLabel = incoming.accessibilityLabel
        capsule.largeContentTitle = incoming.accessibilityLabel
        capsule.largeContentImage = UIImage(systemName: NotificationAppearance(item.kind).symbolName)
        let outgoing = content
        content = incoming
        let wasExpanded = isExpanded
        isExpanded = true
        guard animated else {
            outgoing?.removeFromSuperview()
            capsule.alpha = 1
            setNeedsLayout()
            layoutIfNeeded()
            return
        }
        let reducesMotion = UIAccessibility.isReduceMotionEnabled
        if wasExpanded, let motion {
            // 広げている途中に次の通知が来たら、新しい中身も残りの動きに合わせて背景の端に沿わせ、上へ送らずに薄くして入れ替える。
            // 上へ送る動きは、背景の端に沿わせる位置の動きとぶつかるため。
            layoutContent(incoming, in: expandedFrame)
            if tracksEdges {
                trackedContents.append(incoming)
                follow(incoming, along: motion)
            }
            fadingContent = nil
            startLeaving(outgoing)
            incoming.setAlpha(0)
            UIView.animate(withDuration: animationDuration * 0.6, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                incoming.setAlpha(1)
                outgoing?.setAlpha(0)
            } completion: { [weak self] _ in
                self?.finishLeaving(outgoing)
            }
            return
        }
        if wasExpanded {
            layoutContent(incoming, in: expandedFrame)
            let shift = reducesMotion ? 0 : metrics.height * 0.7
            incoming.offset(by: shift)
            incoming.setAlpha(0)
            startLeaving(outgoing)
            UIView.animate(withDuration: animationDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                incoming.offset(by: -shift)
                incoming.setAlpha(1)
                outgoing?.offset(by: -shift)
                outgoing?.setAlpha(0)
            } completion: { [weak self] _ in
                self?.finishLeaving(outgoing)
            }
            return
        }
        // 消し終えていれば中身は残っていない。残っていれば、縮めている途中か薄くしている途中なので、出ていく途中の中身として、見えている濃さから薄くして入れ替える。
        // その場で取り除くと、中身が1コマで消える。
        let outgoingAlpha = outgoing.map { CGFloat($0.left.layer.presentation()?.opacity ?? Float($0.left.alpha)) }
        startLeaving(outgoing)
        if reducesMotion {
            capsule.frame = expandedFrame
            layoutContent(incoming, in: expandedFrame)
            capsule.layer.cornerRadius = cornerRadius(for: expandedFrame)
            capsule.alpha = 0
            UIView.animate(withDuration: animationDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.capsule.alpha = 1
            }
            if let outgoing, let outgoingAlpha {
                fadeOut(outgoing, from: outgoingAlpha)
            }
            return
        }
        // 切り欠きの大きさから広げる。中身は背景の端と一緒に、切り欠きの中から外へ出る。切り欠きのない画面では、上から下ろす。
        // 縮めている途中なら、今の見た目の枠から広げ直す。
        if motion == nil {
            setCapsule(frame: collapsedFrame, cornerRadius: cornerRadius(for: collapsedFrame))
        }
        capsule.alpha = 1
        layoutContent(incoming, in: expandedFrame)
        trackedContents = [incoming] + leavingContents
        fadingContent = incoming
        animateCapsule(to: expandedFrame, dampingRatio: 0.85, contentAlpha: { progress in min(max(progress / 0.25, 0), 1) }) {}
        if let outgoing, let outgoingAlpha {
            fadeOut(outgoing, from: outgoingAlpha)
        }
    }

    /// 出ていく中身を、`alpha`から入れ替えと同じ時間で薄くして取り除く。縮めるときに付けた濃さの動きは外し、この薄くする動きに替える。
    private func fadeOut(_ content: ContentViews, from alpha: CGFloat) {
        for layer in [content.left.layer, content.right.layer] {
            layer.removeAnimation(forKey: Self.animationKeyPrefix + "opacity")
        }
        content.setAlpha(alpha)
        UIView.animate(withDuration: animationDuration * 0.6, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            content.setAlpha(0)
        } completion: { [weak self] _ in
            self?.finishLeaving(content)
        }
    }

    /// 切り欠きへ縮めて消す。「視差効果を減らす」がオンなら、その場で薄くして消す。
    func hide(animated: Bool, completion: (() -> Void)? = nil) {
        guard isExpanded else {
            completion?()
            return
        }
        isExpanded = false
        item = nil
        let finished = { [weak self] in
            guard let self, !self.isExpanded else { return }
            self.capsule.alpha = 0
            self.content?.removeFromSuperview()
            self.content = nil
            self.removeLeavingContents()
            completion?()
        }
        guard animated else {
            finished()
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: animationDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.capsule.alpha = 0
            } completion: { _ in
                finished()
            }
            return
        }
        // 中身は背景の端と一緒に切り欠きの中へしまわれる。濃さは、ほとんど縮み終わるまで保つ。アイランドに重なった分は実機では見えないため。
        // 入れ替わりの途中なら、出ていく途中の中身も背景の端に合わせて置く。置かないと、縮む背景に置いていかれて端で切れる。
        trackedContents = (content.map { [$0] } ?? []) + leavingContents
        fadingContent = content
        animateCapsule(to: collapsedFrame, dampingRatio: 1, contentAlpha: { progress in min(max((1 - progress) / 0.25, 0), 1) }) {
            finished()
        }
    }

    private func startLeaving(_ content: ContentViews?) {
        guard let content else { return }
        leavingContents.append(content)
    }

    private func finishLeaving(_ content: ContentViews?) {
        guard let content else { return }
        content.removeFromSuperview()
        leavingContents.removeAll { $0 === content }
        trackedContents.removeAll { $0 === content }
    }

    private func removeLeavingContents() {
        for content in leavingContents {
            content.removeFromSuperview()
            trackedContents.removeAll { $0 === content }
        }
        leavingContents = []
    }

    /// 背景を広げたり縮めたりしている動きの、始まりと行き先の枠と丸み。途中から加わる中身の動きを、残りの時間に合わせて作るために持つ。
    /// 始まった時刻は持たず、描き始めた時刻を`motionStartTime`で読む。
    private struct Motion {
        let id: UUID
        let spring: UIKitSpring
        let fromFrame: CGRect
        let toFrame: CGRect
        let fromRadius: CGFloat
        let toRadius: CGFloat

        func frame(at progress: CGFloat) -> CGRect {
            CGRect(
                x: fromFrame.minX + (toFrame.minX - fromFrame.minX) * progress,
                y: fromFrame.minY + (toFrame.minY - fromFrame.minY) * progress,
                width: fromFrame.width + (toFrame.width - fromFrame.width) * progress,
                height: fromFrame.height + (toFrame.height - fromFrame.height) * progress
            )
        }

        func radius(at progress: CGFloat) -> CGFloat {
            max(fromRadius + (toRadius - fromRadius) * progress, 0)
        }
    }

    /// キーフレームの間隔。線でつないでも、120Hzの画面でスプリングの曲線と見分けがつかない細かさにする。
    private static let keyframeInterval: TimeInterval = 1.0 / 240
    private static let animationKeyPrefix = "statusBarTicker."

    /// 背景を、今の見た目の枠から`target`へ、UIKitと同じスプリングで動かす。中身も同じ時刻表で背景の端に沿わせ、背景と一緒に出入りする中身の濃さも同じ進み具合で決める。
    private func animateCapsule(to target: CGRect, dampingRatio: CGFloat, contentAlpha: @escaping (CGFloat) -> CGFloat, completion: @escaping () -> Void) {
        // 動いている途中なら、今の見た目で止めてから動かし直す。
        let presentation = capsule.layer.presentation()
        let fromFrame = presentation?.frame ?? capsule.frame
        let fromRadius = presentation?.cornerRadius ?? capsule.layer.cornerRadius
        removeMotionAnimations()
        let spring = UIKitSpring.make(duration: animationDuration, dampingRatio: dampingRatio)
        let motion = Motion(
            id: UUID(),
            spring: spring,
            fromFrame: fromFrame,
            toFrame: target,
            fromRadius: fromRadius,
            toRadius: cornerRadius(for: target)
        )
        self.motion = motion
        let times = keyframeTimes(from: 0, to: spring.duration)
        let progresses = times.map { CGFloat(spring.progress(at: $0)) }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.motion?.id == motion.id else { return }
            self.motion = nil
            self.trackedContents = []
            self.fadingContent = nil
            completion()
        }
        setCapsule(frame: target, cornerRadius: motion.toRadius)
        let frames = progresses.map(motion.frame(at:))
        addKeyframes(to: capsule.layer, keyPath: "position", values: frames.map { NSValue(cgPoint: CGPoint(x: $0.midX, y: $0.midY)) }, times: times, beginTime: nil)
        addKeyframes(to: capsule.layer, keyPath: "bounds", values: frames.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.size)) }, times: times, beginTime: nil)
        addKeyframes(to: capsule.layer, keyPath: "cornerRadius", values: progresses.map { motion.radius(at: $0) }, times: times, beginTime: nil)
        if tracksEdges {
            for content in trackedContents {
                follow(content, along: motion)
            }
        }
        if let fadingContent {
            // 濃さは、濃くした状態からの差として重ねる。入れ替えで薄い状態から出てくる途中なら、その動きを残したまま、背景と一緒に出入りする分だけ薄くする。
            // 置き換えると、出てくる途中の濃さが1コマで濃くなる。
            fadingContent.setAlpha(1)
            for layer in [fadingContent.left.layer, fadingContent.right.layer] {
                addKeyframes(to: layer, keyPath: "opacity", values: progresses.map { Float(contentAlpha($0) - 1) }, times: times, beginTime: nil, additive: true)
            }
        }
        CATransaction.commit()
        #if DEBUG
        startTrace()
        #endif
    }

    /// 中身を、`motion`の残りの時間、背景の端から余白だけ内側に沿わせる。動き終わったときの位置を、中身の置き場所にする。
    private func follow(_ content: ContentViews, along motion: Motion) {
        // まだ描き始めていなければ、背景と同じく描き始める時刻から動かす。
        let startTime = motionStartTime
        let elapsed = startTime.map { max(mediaTime() - $0, 0) } ?? 0
        guard elapsed < motion.spring.duration else { return }
        let times = keyframeTimes(from: elapsed, to: motion.spring.duration)
        let placements = times.map { edgeFrames(content, visible: motion.frame(at: CGFloat(motion.spring.progress(at: $0)))) }
        guard let last = placements.last else { return }
        // 沿わせるのは横の位置だけにする。縦は、入れ替えで上へ送っている途中の中身が、送っている途中の高さから続けて動けるよう、置いた高さのままにする。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.left.layer.position.x = last.left.midX
        content.right.layer.position.x = last.right.midX
        let beginTime = startTime.map { $0 + elapsed }
        let shiftedTimes = times.map { $0 - elapsed }
        addKeyframes(to: content.left.layer, keyPath: "position.x", values: placements.map { $0.left.midX }, times: shiftedTimes, beginTime: beginTime)
        addKeyframes(to: content.right.layer, keyPath: "position.x", values: placements.map { $0.right.midX }, times: shiftedTimes, beginTime: beginTime)
        CATransaction.commit()
    }

    private func keyframeTimes(from start: TimeInterval, to end: TimeInterval) -> [TimeInterval] {
        let count = max(Int(((end - start) / Self.keyframeInterval).rounded(.up)), 1)
        return (0...count).map { start + (end - start) * Double($0) / Double(count) }
    }

    /// 背景の動きを描き始めた時刻。まだ描いていなければnil。
    /// 動きを足したあと、描く前にメインスレッドが止まる（押して通知タブへ移るときなど）と、足した時刻から数えた動きは止まっていた分だけ進んだところから描かれ、1コマで飛ぶ。
    /// そのため背景の動きは描き始めた時刻から始め、あとから加わる中身の動きはこの時刻に合わせる。
    private var motionStartTime: CFTimeInterval? {
        guard let animation = capsule.layer.animation(forKey: Self.animationKeyPrefix + "position"), animation.beginTime > 0 else { return nil }
        return capsule.layer.convertTime(animation.beginTime, to: nil)
    }

    /// `values`を`times`（`beginTime`からの経過時間）に置いたキーフレームを足す。モデルの値は呼ぶ前に行き先にしておく。
    /// `beginTime`がnilなら、描き始める時刻から動かす。
    /// `additive`なら、モデルの値とほかの動きの値に足す。
    private func addKeyframes(to layer: CALayer, keyPath: String, values: [Any], times: [TimeInterval], beginTime: CFTimeInterval?, additive: Bool = false) {
        guard let duration = times.last, duration > 0 else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / duration) }
        animation.calculationMode = .linear
        animation.isAdditive = additive
        animation.duration = duration
        if let beginTime {
            animation.beginTime = layer.convertTime(beginTime, from: nil)
        }
        animation.fillMode = .backwards
        layer.add(animation, forKey: Self.animationKeyPrefix + keyPath)
    }

    /// 背景と中身の、今の見た目の位置で止める。中身の動き（上へ送る途中のUIKitのアニメーションを含む）も、背景に沿わせ直すので外す。
    /// 背景と中身の、背景に合わせた動きを、今の見た目の位置で止める。
    /// 中身を上へ送って入れ替えている途中のUIKitの動きは残す。中身は横の位置だけを背景に沿わせるので、送る動きとぶつからない。
    /// 外して見えている高さから動かし直すと、描くまでにメインスレッドが止まったとき（押して通知タブへ移るときなど）、止まっている間に進んだ分だけ、1コマで高さが戻る。
    private func removeMotionAnimations() {
        motion = nil
        for layer in [capsule.layer] + (trackedContents + leavingContents).flatMap({ [$0.left.layer, $0.right.layer] }) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.animationKeyPrefix) {
                layer.removeAnimation(forKey: key)
            }
        }
    }

    private func setCapsule(frame: CGRect, cornerRadius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = frame
        capsule.layer.cornerRadius = cornerRadius
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isExpanded, motion == nil else { return }
        capsule.frame = expandedFrame
        capsule.layer.cornerRadius = cornerRadius(for: expandedFrame)
        if let content {
            layoutContent(content, in: expandedFrame)
        }
    }

    @objc private func tapped() {
        onTap?()
    }

    /// 拡大表示の対象かどうかの判定は、指を受けるかどうかと同じ`tapTarget(at:)`で決める。
    /// 拡大表示を出している間は、読み終えるまで次の通知へ進めない。
    func largeContentViewerInteraction(_ interaction: UILargeContentViewerInteraction, itemAt point: CGPoint) -> (any UILargeContentViewerItem)? {
        let target = tapTarget(at: point)
        isHeldForLargeContent = target != nil
        return target
    }

    func largeContentViewerInteraction(_ interaction: UILargeContentViewerInteraction, didEndOn item: (any UILargeContentViewerItem)?, at point: CGPoint) {
        isHeldForLargeContent = false
        guard item != nil, tapTarget(at: point) != nil else { return }
        onTap?()
    }

    // MARK: - 形

    private struct Metrics {
        let height: CGFloat
        let fontSize: CGFloat
        let avatarSide: CGFloat
        let thumbnailSide: CGFloat
        /// 何をされたかの記号を、アイコンの右下に重ねる。名前の前に並べると、名前の入る幅が狭いとき。
        let badgesSymbol: Bool
    }

    private var metrics: Metrics {
        let badges = AppDependencies.tuning.value(of: TuningCatalog.statusBarTickerBadgesSymbol)
        return switch cutout {
        case .island(let rect, _): Metrics(height: rect.height, fontSize: 13, avatarSide: 20, thumbnailSide: 24, badgesSymbol: badges)
        case .notch(let rect): Metrics(height: rect.height, fontSize: 12, avatarSide: 18, thumbnailSide: 22, badgesSymbol: true)
        case .none(let height): Metrics(height: height, fontSize: 12, avatarSide: 15, thumbnailSide: 16, badgesSymbol: badges)
        }
    }

    /// 広げたときのカプセルの枠。
    private var expandedFrame: CGRect {
        switch cutout {
        case .island(let rect, let sideMargin):
            CGRect(x: sideMargin, y: rect.minY, width: bounds.width - sideMargin * 2, height: rect.height)
        case .notch(let rect):
            CGRect(x: 0, y: 0, width: bounds.width, height: rect.maxY)
        case .none(let height):
            CGRect(x: 0, y: 0, width: bounds.width, height: height)
        }
    }

    private var collapsedFrame: CGRect {
        switch cutout {
        case .island(let rect, _), .notch(let rect): rect
        case .none(let height): CGRect(x: 0, y: -height, width: bounds.width, height: height)
        }
    }

    private func cornerRadius(for frame: CGRect) -> CGFloat {
        switch cutout {
        case .island:
            capsule.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            return frame.height / 2
        case .notch:
            capsule.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            return 12
        case .none:
            capsule.layer.maskedCorners = []
            return 0
        }
    }

    /// 中身が背景の端に付いて動く画面か。アイランドとノッチでは、背景が切り欠きから左右へ広がる。
    private var tracksEdges: Bool {
        if case .none = cutout { return false }
        return true
    }

    /// 背景の左端から左の中身までの余白と、右の中身から背景の右端までの余白。
    /// アイランドの機種では、チューニングの値を使う。左は先頭の記号が端の半円と同心に見える値、右は行末のぼかしを端の半円の中に入れる値を初めの値にする。
    private var edgePaddings: (leading: CGFloat, trailing: CGFloat) {
        switch cutout {
        case .island:
            let tuning = AppDependencies.tuning
            return (tuning.value(of: TuningCatalog.statusBarTickerLeadingPadding), tuning.value(of: TuningCatalog.statusBarTickerTrailingPadding))
        case .notch: return (14, 14)
        case .none: return (0, 0)
        }
    }

    /// 背景が`visible`の枠（このビューの座標）にあるときの、背景の端から余白だけ内側の中身の枠。座標はカプセルの中。
    /// 広げ終わった位置より外へは出さない。画面の外まで広げる形でも、端が画面の外へ抜けたところで中身は止まる。
    private func edgeFrames(_ content: ContentViews, visible: CGRect) -> (left: CGRect, right: CGRect) {
        let frame = expandedFrame
        let rects = contentRects(content, in: frame)
        var left = rects.left.offsetBy(dx: frame.minX, dy: frame.minY)
        var right = rects.right.offsetBy(dx: frame.minX, dy: frame.minY)
        let paddings = edgePaddings
        left.origin.x = max(visible.minX + paddings.leading, left.minX)
        right.origin.x = min(visible.maxX - paddings.trailing, right.maxX) - right.width
        return (left.offsetBy(dx: -visible.minX, dy: -visible.minY), right.offsetBy(dx: -visible.minX, dy: -visible.minY))
    }

    #if DEBUG
    /// `defaults write net.mizle.scia debug.statusBarTickerTrace -bool true`で、背景を広げたり縮めたりしている間の毎コマ、
    /// 描いている途中の背景の枠と、左右の中身の位置と濃さを、debugレベルのログに書く。見た目ではなく数値で動きを確かめるため。
    /// 値は描画が使う見た目の値（presentation layer）から読む。中身の位置は、このビューの座標で、左は左端、右は右端、縦は真ん中。targetは広がり終わったときの位置。
    private func startTrace() {
        guard UserDefaults.standard.bool(forKey: "debug.statusBarTickerTrace"), traceLink == nil else { return }
        let link = CADisplayLink(target: TraceTarget { [weak self] in self?.traceRendered() ?? false }, selector: #selector(TraceTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        traceLink = link
    }

    /// 動いている間はtrueを返す。
    private func traceRendered() -> Bool {
        guard motion != nil else {
            traceLink = nil
            return false
        }
        // まだ一度も描かれていないレイヤーには描画中の値がない。行き先の値で代えると、画面に出ていない値を書くことになるため、そのコマは書かない。
        let contents = trackedContents + leavingContents
        guard let capsulePresentation = capsule.layer.presentation(),
              contents.allSatisfy({ $0.left.layer.presentation() != nil && $0.right.layer.presentation() != nil })
        else { return true }
        let visible = capsulePresentation.frame
        let frame = expandedFrame
        let parts = contents.enumerated().compactMap { index, content -> String? in
            guard let left = content.left.layer.presentation(), let right = content.right.layer.presentation() else { return nil }
            let leftFrame = left.frame.offsetBy(dx: visible.minX, dy: visible.minY)
            let rightFrame = right.frame.offsetBy(dx: visible.minX, dy: visible.minY)
            return String(format: "c%d L=%.2f Ly=%.2f La=%.2f R=%.2f Ry=%.2f Ra=%.2f", index, leftFrame.minX, leftFrame.midY, left.opacity, rightFrame.maxX, rightFrame.midY, right.opacity)
        }
        var target = ""
        if let content = trackedContents.last {
            let rects = contentRects(content, in: frame)
            target = String(format: "target L=%.2f R=%.2f y=%.2f", rects.left.minX + frame.minX, rects.right.maxX + frame.minX, rects.left.midY + frame.minY)
        }
        let line = String(format: "trace t=%.4f bg=%.2f..%.2f y=%.2f..%.2f ", mediaTime(), visible.minX, visible.maxX, visible.minY, visible.maxY) + parts.joined(separator: " ") + " " + target
        Self.traceLogger.debug("\(line, privacy: .public)")
        return true
    }

    private var traceLink: CADisplayLink?
    private static let traceLogger = SciaLog.logger(category: "statusBarTickerTrace")
    #endif

    /// 左右の中身を置く。座標はカプセルの中。
    private func layoutContent(_ content: ContentViews, in frame: CGRect) {
        let rects = contentRects(content, in: frame)
        content.left.frame = rects.left
        content.right.frame = rects.right
    }

    /// 背景が`frame`にあるときの左右の中身の枠。座標はカプセルの中。
    private func contentRects(_ content: ContentViews, in frame: CGRect) -> (left: CGRect, right: CGRect) {
        let gap: CGFloat = 8
        let left: CGRect
        let right: CGRect
        switch cutout {
        case .island(let rect, let sideMargin):
            // 文字はアイランドと同じ高さの行に、カプセルの端から余白だけ内側に置く。
            let paddings = edgePaddings
            let leading = sideMargin + paddings.leading
            let trailing = sideMargin + paddings.trailing
            let y = rect.minY - frame.minY
            left = CGRect(x: leading - frame.minX, y: y, width: rect.minX - gap - leading, height: rect.height)
            right = CGRect(x: rect.maxX + gap - frame.minX, y: y, width: bounds.width - trailing - rect.maxX - gap, height: rect.height)
        case .notch(let rect):
            // ノッチの機種は、上の端では画面の角の丸みに文字がかかるため、少し多めに空ける。
            let inset: CGFloat = 14
            left = CGRect(x: inset, y: 0, width: rect.minX - frame.minX - gap - inset, height: frame.height)
            right = CGRect(x: rect.maxX - frame.minX + gap, y: 0, width: frame.maxX - rect.maxX - gap - inset, height: frame.height)
        case .none:
            // 切り欠きで分かれないので、誰が何をしたかのすぐ後ろに文頭を続ける。名前が長くても、文頭の場所を半分は残す。
            let inset: CGFloat = 16
            let available = frame.width - inset * 2 - gap
            let leftWidth = min(content.naturalLeftWidth, available / 2)
            left = CGRect(x: inset, y: 0, width: leftWidth, height: frame.height)
            right = CGRect(x: inset + leftWidth + gap, y: 0, width: available - leftWidth, height: frame.height)
        }
        return (left, right)
    }

    /// 1件の通知の中身。入れ替えるときに、古い中身を残したまま新しい中身を重ねて動かすため、まとめて持つ。
    @MainActor
    private final class ContentViews {
        let left = UIStackView()
        let right = UIStackView()
        let accessibilityLabel: String
        private let item: StatusBarTickerItem
        private let metrics: Metrics
        /// 入りきらない名前と文頭は、「…」で切らず、投稿の名前と同じく行末をぼかす。
        private let nameLabel = FadingLabel()
        private let subjectLabel = FadingLabel()

        init(item: StatusBarTickerItem, metrics: Metrics) {
            self.item = item
            self.metrics = metrics
            let appearance = NotificationAppearance(item.kind)
            let name = item.account.displayNameOrUsername
            let action = appearance.phrase.includesName ? "\(appearance.phrase.before)\(name)\(appearance.phrase.after)" : appearance.phrase.before
            accessibilityLabel = switch item.subject {
            case .text(let text): "\(action)。\(text.plainText)"
            case .media(_, _, let isImageOnly): "\(action)。\(isImageOnly ? "画像" : "メディア")だけの投稿"
            case .handle(let handle): "\(action)。\(handle)"
            case .none: action
            }

            for stack in [left, right] {
                stack.axis = .horizontal
                stack.alignment = .center
                stack.spacing = 5
                stack.isUserInteractionEnabled = false
            }

            let symbol = UIImageView(image: UIImage(
                systemName: appearance.symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: metrics.badgesSymbol ? metrics.avatarSide * 0.36 : metrics.fontSize, weight: .semibold)
            ))
            symbol.tintColor = appearance.color
            symbol.setContentHuggingPriority(.required, for: .horizontal)
            symbol.setContentCompressionResistancePriority(.required, for: .horizontal)

            let avatar = AvatarView(store: AppDependencies.avatarImages)
            avatar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                avatar.widthAnchor.constraint(equalToConstant: metrics.avatarSide),
                avatar.heightAnchor.constraint(equalToConstant: metrics.avatarSide),
            ])
            avatar.apply(AvatarView.Content(url: item.account.avatarStatic, shape: AppDependencies.settings.avatarShape, animates: false))
            if metrics.badgesSymbol {
                left.addArrangedSubview(Self.badged(avatar, with: symbol, side: metrics.avatarSide))
                // 右下にはみ出す記号の分を空ける。
                left.setCustomSpacing(7, after: left.arrangedSubviews[left.arrangedSubviews.count - 1])
            } else {
                left.addArrangedSubview(symbol)
                left.addArrangedSubview(avatar)
            }

            nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            left.addArrangedSubview(nameLabel)

            if case .media(let attachment, let isSensitive, _) = item.subject {
                right.addArrangedSubview(Self.thumbnail(of: attachment, isSensitive: isSensitive, side: metrics.thumbnailSide))
                // サムネイルを左に寄せるため、残りを空白で埋める。
                let spacer = UIView()
                spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
                right.addArrangedSubview(spacer)
            } else {
                subjectLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
                subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                right.addArrangedSubview(subjectLabel)
            }
            render()
        }

        /// 名前と文頭を描く。カスタム絵文字が届いたら、描き直す。
        func render() {
            let settings = AppDependencies.settings
            let fadeWidth = AppDependencies.tuning.value(of: TuningCatalog.statusBarTickerFadeWidth)
            nameLabel.fadeWidth = fadeWidth
            subjectLabel.fadeWidth = fadeWidth
            let animatedEmojis = settings.animatesCustomEmojis ? AppDependencies.emojiImages : nil
            nameLabel.emojiImages = animatedEmojis
            subjectLabel.emojiImages = animatedEmojis
            // 文字はステータスバーの高さに収めるため、大きさを決め打ちする。文字を大きくする設定では、拡大表示で読む。
            // swiftlint:disable:next fixed_font_size
            let font = UIFont.systemFont(ofSize: metrics.fontSize, weight: .semibold)
            let nameRenderer = RichTextRenderer(font: font, textColor: .label, emojiImages: AppDependencies.emojiImages, language: settings.glyphLanguageIdentifier())
            nameLabel.attributedText = nameRenderer.render(.plain(item.account.displayNameOrUsername, emojis: item.account.emojis))
            let subjectColor = UIColor.secondaryLabel
            var renderer = RichTextRenderer(
                // swiftlint:disable:next fixed_font_size
                font: .systemFont(ofSize: metrics.fontSize),
                textColor: subjectColor,
                emojiImages: AppDependencies.emojiImages,
                language: settings.glyphLanguageIdentifier()
            )
            renderer.linkColor = subjectColor
            renderer.secondaryColor = subjectColor
            switch item.subject {
            case .text(let text):
                subjectLabel.attributedText = renderer.render(text)
            case .handle(let handle):
                subjectLabel.attributedText = renderer.render(.plain(handle, emojis: []))
            case .media, .none:
                subjectLabel.attributedText = nil
            }
        }

        /// 左の中身を省かずに並べたときの幅。
        var naturalLeftWidth: CGFloat {
            let views = left.arrangedSubviews
            let widths = views.map { view in
                view is UILabel ? view.intrinsicContentSize.width : view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            }
            let spacings = views.dropLast().map { left.customSpacing(after: $0) == UIStackView.spacingUseDefault ? left.spacing : left.customSpacing(after: $0) }
            return ceil(widths.reduce(0, +) + spacings.reduce(0, +))
        }

        func offset(by dy: CGFloat) {
            left.center.y += dy
            right.center.y += dy
        }

        func setAlpha(_ alpha: CGFloat) {
            left.alpha = alpha
            right.alpha = alpha
        }

        func removeFromSuperview() {
            left.removeFromSuperview()
            right.removeFromSuperview()
        }

        /// アイコンの右下に、黒い丸に載せた記号を重ねる。
        private static func badged(_ avatar: UIView, with symbol: UIImageView, side: CGFloat) -> UIView {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            let badge = UIView()
            let badgeSide = side * 0.62
            badge.backgroundColor = .systemBackground
            badge.layer.cornerRadius = badgeSide / 2
            badge.translatesAutoresizingMaskIntoConstraints = false
            symbol.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(avatar)
            container.addSubview(badge)
            badge.addSubview(symbol)
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: side),
                container.heightAnchor.constraint(equalToConstant: side),
                avatar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                avatar.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: badgeSide),
                badge.heightAnchor.constraint(equalToConstant: badgeSide),
                badge.centerXAnchor.constraint(equalTo: container.trailingAnchor, constant: -1),
                badge.centerYAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
                symbol.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                symbol.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            ])
            return container
        }

        private static func thumbnail(of attachment: MediaAttachment, isSensitive: Bool, side: CGFloat) -> UIView {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = side * 0.22
            imageView.layer.cornerCurve = .continuous
            imageView.backgroundColor = .secondarySystemFill
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: side),
                imageView.heightAnchor.constraint(equalToConstant: side),
            ])
            let store = AppDependencies.mediaImages
            if isSensitive {
                // 閲覧注意の画像は、一覧と同じく中身を見せず、ぼかしの下地に目のアイコンを重ねる。
                imageView.image = attachment.blurhash.flatMap { store.placeholder(for: $0, aspectRatio: 1) }
                let eye = UIImageView(image: UIImage(systemName: "eye.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.4, weight: .semibold)))
                eye.tintColor = .white
                eye.translatesAutoresizingMaskIntoConstraints = false
                imageView.addSubview(eye)
                NSLayoutConstraint.activate([
                    eye.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                    eye.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                ])
                return imageView
            }
            guard let url = attachment.previewUrl else { return imageView }
            let request = MediaThumbnailRequest(url: url, maxPixelSize: Int((side * 3).rounded(.up)))
            if let cached = store.cachedThumbnail(for: request) {
                imageView.image = cached
                return imageView
            }
            Task { [weak imageView] in
                guard let image = try? await store.thumbnail(for: request), let imageView else { return }
                // 下地から1コマで替えず、一覧のサムネイルと同じく薄く重ねて入れる。
                UIView.transition(with: imageView, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    imageView.image = image
                }
            }
            return imageView
        }
    }
}

#if DEBUG
/// `CADisplayLink`は呼び先を強く持つため、ビューを持たない呼び先を挟む。ビューがなくなるか、動きが終わったら止める。
@MainActor
private final class TraceTarget: NSObject {
    private let action: () -> Bool

    init(_ action: @escaping () -> Bool) {
        self.action = action
    }

    @objc func tick(_ link: CADisplayLink) {
        if !action() {
            link.invalidate()
        }
    }
}
#endif
