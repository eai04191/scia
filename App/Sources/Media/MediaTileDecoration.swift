import SciaCore
import UIKit

/// サムネイルの上に重ねる表示。タイルの本物も、ビューアや投稿欄の開閉で動かす複製も、この値を`MediaTileDecorationView`で描く。
/// 描く道を1つにして、複製にだけ表示が欠けることをなくす。表示を足すときは、既定値を付けずにプロパティを足し、値を作る箇所をコンパイラーに挙げさせる。
struct MediaTileDecoration: Equatable {
    /// 動画の再生アイコン。
    var showsPlay: Bool
    /// 左下のバッジのラベル（ALT、GIF、HDR）。
    var badgeMarks: [MediaBadgeView.Mark]
    /// バッジを出すか。出さないときも、バッジがあった位置を示せるよう、大きさと位置は決める。
    var showsBadge: Bool
    /// 中央に出す記号（音声、種類の分からないファイル）。
    var symbol: Symbol?
    /// 残りの枚数。0なら出さない。
    var hiddenCount: Int

    struct Symbol: Equatable {
        let name: String
        /// 画像の上に重ねる。画像の上では白く影を付け、画像のない枠の上では本文に近い色にする。
        let isOverImage: Bool
    }

    static let none = MediaTileDecoration(showsPlay: false, badgeMarks: [], showsBadge: false, symbol: nil, hiddenCount: 0)
}

/// 再生アイコンや記号の大きさを、タイルの大きさから決めるチューニングの値。
struct MediaTileSymbolSizing: Equatable {
    let ratio: Double
    let range: ClosedRange<Double>

    @MainActor
    init(tuning: TuningStore) {
        ratio = tuning.value(of: TuningCatalog.mediaSymbolRatio)
        range = tuning.value(of: TuningCatalog.mediaSymbolMinSize)...tuning.value(of: TuningCatalog.mediaSymbolMaxSize)
    }

    init(ratio: Double, range: ClosedRange<Double>) {
        self.ratio = ratio
        self.range = range
    }

    func pointSize(tileSize: CGSize) -> CGFloat {
        MediaTileSymbol.pointSize(tileSize: tileSize, ratio: ratio, range: range)
    }
}

/// 複製を作るのに要る、タイルの上の表示と、それを並べたタイルの大きさ。
struct MediaTileDecorationLayout: Equatable {
    let decoration: MediaTileDecoration
    let sizing: MediaTileSymbolSizing
    let size: CGSize

    /// 何も重ねていないタイル。
    static func undecorated(size: CGSize) -> Self {
        MediaTileDecorationLayout(decoration: .none, sizing: MediaTileSymbolSizing(ratio: 0, range: 0...0), size: size)
    }
}

/// `MediaTileDecoration`を描く。タイルの本物では枠の大きさに合わせて並べ直し、複製では作ったときのタイルの大きさで並べたまま、
/// 枠の大きさが変わっても各部品をタイルと同じ角からの位置に保つ（`init(frozen:)`）。
final class MediaTileDecorationView: UIView {
    /// 重ねる部品。開閉で動かす複製は、部品ごとに動かし方を決める。
    enum Part: CaseIterable {
        case symbol
        case play
        case more
        case badge
    }

    private let symbolView = UIImageView()
    /// 動画の再生アイコン。バッジと同じ下地の丸に三角を載せ、タイムラインのバッジとも、ビューアの丸い再生ボタンとも揃える。
    private let playView = UIView()
    private let playGlyphView = UIImageView(image: UIImage(systemName: "play.fill"))
    private let moreLabel = UILabel()
    private let badge = MediaBadgeView()
    /// 作ったときの大きさで並べたまま、並べ直さない。
    private var isFrozen = false
    /// いまアイコンに当てている大きさ。同じなら設定し直さない。
    private var symbolPointSize: CGFloat?

    var decoration = MediaTileDecoration.none {
        didSet {
            guard decoration != oldValue else { return }
            apply()
        }
    }

    var sizing = MediaTileSymbolSizing(ratio: 0, range: 0...0) {
        didSet {
            guard sizing != oldValue else { return }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        symbolView.contentMode = .center
        symbolView.layer.shadowColor = UIColor.black.cgColor
        symbolView.layer.shadowRadius = 4
        symbolView.layer.shadowOffset = .zero
        playView.backgroundColor = MediaBadgeView.backgroundColor
        playGlyphView.tintColor = .white
        playGlyphView.contentMode = .center
        playView.addSubview(playGlyphView)
        moreLabel.font = .preferredFont(forTextStyle: .title1).bold
        moreLabel.textColor = .white
        moreLabel.textAlignment = .center
        moreLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        for part in Part.allCases {
            addSubview(view(for: part))
        }
        apply()
        // バッジは文字の大きさで幅が変わるため、並べ直す。
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
    }

    /// `layout`のタイルと同じ見え方で並べた複製。枠の大きさが変わっても並べ直さず、全体を覆う残りの枚数と中央の記号は枠に合わせて伸ばし、
    /// 再生アイコンとバッジは同じ大きさのまま、タイルと同じ角からの位置に保つ。ビューアの大きさまで広がっても、三角やラベルがぼけない。
    convenience init(frozen layout: MediaTileDecorationLayout) {
        self.init(frame: CGRect(origin: .zero, size: layout.size))
        // イニシャライザーの中で入れた値では`didSet`が呼ばれないので、ここで描く。
        sizing = layout.sizing
        decoration = layout.decoration
        apply()
        layoutIfNeeded()
        isFrozen = true
        for part in Part.allCases {
            view(for: part).autoresizingMask = switch part {
            case .symbol, .more: [.flexibleWidth, .flexibleHeight]
            case .play: [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            case .badge: [.flexibleRightMargin, .flexibleTopMargin]
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func view(for part: Part) -> UIView {
        switch part {
        case .symbol: symbolView
        case .play: playView
        case .more: moreLabel
        case .badge: badge
        }
    }

    /// 再生アイコンの三角。開閉で動かす複製は、丸と別の倍率で縮める。
    var playGlyph: UIView { playGlyphView }

    /// バッジの枠。消していれば、バッジがあった位置。付けるラベルがなければnil。
    func badgePreviewFrame(in space: UIView) -> CGRect? {
        guard !decoration.badgeMarks.isEmpty else { return nil }
        return badge.convert(badge.bounds, to: space)
    }

    private func apply() {
        symbolView.image = decoration.symbol.flatMap { UIImage(systemName: $0.name) }
        let isOverImage = decoration.symbol?.isOverImage ?? true
        symbolView.tintColor = isOverImage ? .white : .secondaryLabel
        symbolView.layer.shadowOpacity = isOverImage ? 0.4 : 0
        playView.isHidden = !decoration.showsPlay
        moreLabel.isHidden = decoration.hiddenCount == 0
        moreLabel.text = "+\(decoration.hiddenCount)"
        badge.marks = decoration.badgeMarks
        badge.isHidden = !decoration.showsBadge || decoration.badgeMarks.isEmpty
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isFrozen else { return }
        symbolView.frame = bounds
        let pointSize = sizing.pointSize(tileSize: bounds.size)
        if symbolPointSize != pointSize {
            symbolPointSize = pointSize
            symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: pointSize)
            playGlyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: (pointSize * Self.playGlyphRatio).rounded())
        }
        playView.bounds.size = CGSize(width: pointSize, height: pointSize)
        playView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        playView.layer.cornerRadius = pointSize / 2
        // 三角は重心が左に寄って見えるため、丸の中で少し右へずらす。
        playGlyphView.frame = playView.bounds.offsetBy(dx: pointSize * Self.playGlyphOffsetRatio, dy: 0)
        moreLabel.frame = bounds
        // バッジをタイルの端から離す余白。狭いタイルでもすべてのラベルを出せるよう、タイルの短い辺に合わせて6ptから2ptまで縮める。
        let inset = min(max(min(bounds.width, bounds.height) / 10, 2), 6).rounded()
        let badgeSize = badge.sizeThatFits(CGSize(width: max(bounds.width - inset * 2, 0), height: bounds.height))
        badge.frame = CGRect(x: inset, y: bounds.maxY - inset - badgeSize.height, width: badgeSize.width, height: badgeSize.height)
    }

    /// 再生アイコンの丸の直径に対する、三角の大きさの比。
    private static let playGlyphRatio: CGFloat = 0.45
    /// 再生アイコンの三角を右へずらす量の、丸の直径に対する比。
    private static let playGlyphOffsetRatio: CGFloat = 0.04
}
