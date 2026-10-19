#if DEBUG
import SciaCore
import UIKit

/// ステータスバーの場所に流す通知（`StatusBarTickerView`）。
/// 確かめるシミュレーターはアイランドのある機種だけなので、ノッチと切り欠きのない形は、ここで機種の画面の幅に置いて縮めて見る。
/// 切り欠きの位置は、点線で重ねる。実物のアイランドとノッチは黒く、カプセルと見分けられないため。
enum StatusBarTickerCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "アイランド: お気に入り（短い本文）") { preview(.island, item(.favourite, alice, text("おはよう"))) },
            CatalogState(title: "アイランド: 長い名前と長い本文（行末をぼかす）") { preview(.island, item(.favourite, longName, text(longText))) },
            CatalogState(title: "アイランド: ブースト") { preview(.island, item(.reblog, bob, text("今日は駅前のパン屋が開いていた"))) },
            CatalogState(title: "アイランド: 画像だけの投稿") { preview(.island, item(.favourite, alice, media(sensitive: false))) },
            CatalogState(title: "アイランド: 閲覧注意の画像だけの投稿") { preview(.island, item(.reblog, bob, media(sensitive: true))) },
            CatalogState(title: "アイランド: フォロー（アカウント名を出す）") { preview(.island, item(.follow, carol, .handle("@carol@remote.example"))) },
            CatalogState(title: "アイランド: 文字も画像もない投稿（右は空ける）") { preview(.island, item(.favourite, alice, .none)) },
            CatalogState(title: "ノッチ（iPhone 11〜14）: お気に入り。左が狭いため、記号はアイコンに重ねる") { preview(.notch, item(.favourite, alice, text("おはよう"))) },
            CatalogState(title: "ノッチ: 長い名前と長い本文") { preview(.notch, item(.favourite, longName, text(longText))) },
            CatalogState(title: "ノッチ: 画像だけの投稿") { preview(.notch, item(.favourite, alice, media(sensitive: false))) },
            CatalogState(title: "切り欠きなし（iPhone SE、iPad）: お気に入り") { preview(.flat, item(.favourite, alice, text("おはよう"))) },
            CatalogState(title: "切り欠きなし: 長い名前と長い本文") { preview(.flat, item(.favourite, longName, text(longText))) },
            CatalogState(title: "切り欠きなし: 画像だけの投稿") { preview(.flat, item(.favourite, alice, media(sensitive: false))) },
        ]
    }

    private enum Device {
        case island
        case notch
        case flat

        /// 画面の幅と、上端から見せる高さと、切り欠き。アイランドはiPhone 16 Pro、ノッチはiPhone 12、切り欠きなしはiPhone SEの値。
        var screen: (size: CGSize, cutout: StatusBarCutout) {
            switch self {
            case .island: (CGSize(width: 402, height: 62), .island(CGRect(x: 138.33, y: 14, width: 125.33, height: 36.67), sideMargin: 24.4))
            case .notch: (CGSize(width: 390, height: 44), .notch(CGRect(x: 89.67, y: 0, width: 210.67, height: 32)))
            case .flat: (CGSize(width: 375, height: 28), .none(height: 20))
            }
        }
    }

    private static let longText = "とても長い本文。狭い場所に収まらない分は末尾を省いて出すので、どこで切れるかを確かめる"
    private static let alice = CatalogFixtures.account(displayName: "アリス", acct: "alice@remote.example", avatar: CatalogFixtures.imageURL(width: 120, height: 120, color: .systemPink))
    private static let bob = CatalogFixtures.account(displayName: "Bob", acct: "bob@remote.example", avatar: CatalogFixtures.imageURL(width: 120, height: 120, color: .systemGreen))
    private static let carol = CatalogFixtures.account(displayName: "キャロル", acct: "carol@remote.example", avatar: CatalogFixtures.imageURL(width: 120, height: 120, color: .systemPurple))
    private static let longName = CatalogFixtures.account(
        displayName: "とても長い表示名のアカウントで名前が収まらない",
        acct: "longname@remote.example",
        avatar: CatalogFixtures.imageURL(width: 120, height: 120, color: .systemTeal)
    )

    private static func item(_ kind: MastodonNotification.Kind, _ account: Account, _ subject: StatusBarTickerItem.Subject) -> StatusBarTickerItem {
        StatusBarTickerItem(id: "catalog", kind: kind, account: account, subject: subject)
    }

    private static func text(_ text: String) -> StatusBarTickerItem.Subject {
        .text(RichText.plain(text, emojis: []))
    }

    private static func media(sensitive: Bool) -> StatusBarTickerItem.Subject {
        .media(CatalogFixtures.attachment("ticker", width: 800, height: 600, color: .systemBlue, label: "画像", blurhash: CatalogFixtures.blurhash), isSensitive: sensitive)
    }

    @MainActor
    private static func preview(_ device: Device, _ item: StatusBarTickerItem) -> UIView {
        let (size, cutout) = device.screen
        let canvas = UIView(frame: CGRect(origin: .zero, size: size))
        canvas.backgroundColor = .systemBackground
        let ticker = StatusBarTickerView(cutout: cutout)
        ticker.frame = canvas.bounds
        canvas.addSubview(ticker)
        ticker.show(item, animated: false)
        let outline = CAShapeLayer()
        outline.fillColor = nil
        outline.strokeColor = UIColor.systemGray.cgColor
        outline.lineWidth = 1
        outline.lineDashPattern = [3, 3]
        switch cutout {
        case .island(let rect, _):
            outline.path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).cgPath
        case .notch(let rect):
            outline.path = UIBezierPath(roundedRect: rect, byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: 12, height: 12)).cgPath
        case .none:
            break
        }
        canvas.layer.addSublayer(outline)
        return CatalogFrame.bordered(ScaledCanvas(canvas))
    }
}

/// 機種の画面の幅で組んだものを、カタログの幅に縮めて見せる。
private final class ScaledCanvas: UIView {
    private let canvas: UIView
    private let designSize: CGSize

    init(_ canvas: UIView) {
        self.canvas = canvas
        designSize = canvas.bounds.size
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(canvas)
        heightAnchor.constraint(equalTo: widthAnchor, multiplier: designSize.height / designSize.width).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = bounds.width / designSize.width
        canvas.bounds = CGRect(origin: .zero, size: designSize)
        canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
#endif
