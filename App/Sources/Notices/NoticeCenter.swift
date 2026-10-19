import UIKit

/// チップの中身を決めるときに渡す、前に出ている画面の様子。文言は出す側が、この様子を受け取って決める。決まりはdocs/notices.mdの「置き場所」にある。
struct NoticeContext {
    /// ビューアで見ているもの。ビューアでなければnil。
    struct Viewer: Equatable {
        /// いま見ている添付ファイルの、共有や保存で落とすURL。落とせるものがなければnil。
        var currentURL: URL?
    }

    var viewer: Viewer?
    /// チップを出したウインドウ。
    weak var window: UIWindow?

    /// チップを押して出すアラートや一覧を、この上に出す。押した時点のウインドウのいちばん手前の画面。
    /// チップを出した時点の画面で決めると、その画面（止めるかの確認など）が閉じたあとに押しても、何も出せないため。
    @MainActor var presenter: UIViewController? {
        window?.rootViewController?.frontmostPresented
    }

    static let list = NoticeContext(viewer: nil)
}

/// 前に出ている画面が、チップの列に伝えること。
struct NoticePlacement {
    /// 列の上端。ウインドウの座標。
    var top: CGFloat
    var viewer: NoticeContext.Viewer?
    /// その画面の中だけで意味のある、出たままのアプリ内通知。画面を閉じると、画面と一緒に薄くなって消える。
    var screenNotice: Notice?
    /// 画面だけのチップの濃さ。払って閉じる途中は、背景に合わせて薄くする。
    var screenAlpha: CGFloat = 1
    /// ボタン類を隠している。使う人が対処するまで残るもの（出たままの失敗、ログインし直し）を、場所を空けたまま薄くする。
    var hidesChrome = false
}

/// チップの列の置き場所を、自分で決める画面。決めない画面は、上の安全領域のすぐ下に置く。
///
/// 入れ物（ナビゲーション、タブ）は問い合わせを前に出ている子へ渡す。状態バーの見た目を子に決めさせる`childForStatusBarStyle`と同じ形。
@MainActor
protocol NoticeScreen: UIViewController {
    /// - Parameter below: この画面の下にある画面が置く、列の上端（ウインドウの座標）。重ねて出す画面（ビューア）が、開く途中と閉じる途中の位置を決めるのに使う。
    func noticePlacement(below: CGFloat) -> NoticePlacement
}

/// アプリ全体のアプリ内通知。セッションごとに1つ持ち、ウインドウごとのチップの列（`NoticeOverlay`）に配る。
///
/// 中身は「前の画面の様子を受け取ってチップの中身を返す関数」で受け取る。数秒で消えるものは出す時点で列ごとに一度だけ呼んで固定し、
/// 出たままのものは様子が変わるたびに呼び直す。Macではウインドウごとに列があり、アプリ全体のものは全部のウインドウに出す。
@MainActor
final class NoticeCenter {
    typealias Content = @MainActor (NoticeContext) -> Notice?

    /// ログインし直しの段。トークンが無効だと分かったときだけ出す。
    struct Reauthentication {
        /// 使っているアカウント。複数のアカウントを使えるため、どのアカウントかを添える。
        var handle: String
        /// ログインし直しを始めてから認可画面が出るまで。
        var isInProgress = false
        var action: @MainActor () -> Void
    }

    var reauthentication: Reauthentication? {
        didSet {
            for overlay in overlays.allObjects {
                overlay.reauthenticationDidChange()
            }
        }
    }
    /// 「操作の状況」の一覧を、渡した画面の上に開く。出たままのアプリ内通知が2件以上のときに、チップから開く。nilなら開けない。
    var showOperationStatus: (@MainActor (UIViewController) -> Void)?
    private var persistent: [PersistentNotices.Slot: Content] = [:]
    private let overlays = NSHashTable<NoticeOverlay>.weakObjects()

    /// 出たままのアプリ内通知を出すか、中身の決め方を替える。nilなら消す。
    func setPersistent(_ content: Content?, in slot: PersistentNotices.Slot) {
        persistent[slot] = content
        persistentDidChange()
    }

    /// 出たままのアプリ内通知の元が変わった。列ごとに中身を決め直す。
    func persistentDidChange() {
        for overlay in overlays.allObjects {
            overlay.contentDidChange()
        }
    }

    /// 前の画面の様子が`context`のときの、`slot`の出たままのアプリ内通知。
    func persistentNotice(in slot: PersistentNotices.Slot, context: NoticeContext) -> Notice? {
        persistent[slot]?(context)
    }

    /// 数秒で消えるチップを、全部の列に出す。
    /// - Parameter slot: このアプリ内通知で`slot`の出たままのチップが消えるなら、その場所で入れ替える（ダウンロード中から保存しましたへ）。
    func showTransient(duration: TimeInterval, replacing slot: PersistentNotices.Slot? = nil, _ content: @escaping @MainActor (NoticeContext) -> Notice) {
        for overlay in overlays.allObjects {
            overlay.showTransient(content, duration: duration, replacing: slot)
        }
    }

    func showTransient(_ notice: Notice, duration: TimeInterval) {
        showTransient(duration: duration) { _ in notice }
    }

    /// アラートを出す先。手前のウインドウの、いちばん手前の画面。
    var presenter: UIViewController? {
        let all = overlays.allObjects
        let overlay = all.first { $0.window?.isKeyWindow == true } ?? all.first
        return overlay?.window?.rootViewController?.frontmostPresented
    }

    func register(_ overlay: NoticeOverlay) {
        overlays.add(overlay)
    }
}
