import Observation
import SciaCore
import UIKit

/// 一覧で本文の右に出す添付ファイル。投稿欄のカプセルと同じく紙焼きの写真に見立てて重ね、一辺の正方形の中に、回した写真の角まで収める。
/// 1つだけでも写真にする。傾けるときは3枚目まで、傾けないときは4枚目までを重ね、それより後ろはいちばん奥の写真の下に隠れているものとする。
/// 傾けないときは、手で置いた写真の見立てをやめ、奥へ行くほど同じ幅ずつ右下へずらして並べ、投稿ごとにばらつかせない。
/// 回す角度、ずらす量、影の濃さは一覧のチューニングで決め、フチの太さ、角の丸み、影の広がりは、写真の大きさによらずカプセルの写真と同じにする。
/// どこを押しても1枚目から開き、長押しのメニューも1枚目のものを出す。奥の写真はほとんど隠れていて、押し分けられないため。
///
/// 閲覧注意などでぼかすときは、写真のフチと重なりはそのまま見せ、中の画像を読まずにblurhashで描いて、リンクカードのサムネイルと同じ薄い素材を重ねる。
/// 写真は小さく文字が入りきらないため、手前の写真にだけ目の記号を出す。
@MainActor
final class MediaPhotoStackView: PhotoStackView {
    private let tuning: TuningStore
    /// チューニングで決めた基準の置き方。ずらす量は写真の一辺に対する割合。
    private var basePlacements: [PhotoStackPlacement] = []
    /// 投稿ごとにばらつかせる、角度（度）とずらす量（写真の一辺に対する割合）の幅。
    private var variation = (rotation: 0.0, offset: 0.0)
    /// ばらつきを決める投稿のID。nilならばらつかせない。
    private var seed: String?
    /// 写真を傾ける。falseなら、どの写真もまっすぐに置く。
    private var tilts = true
    /// 傾けないときに、1枚ごとに右下へずらす幅（写真の一辺に対する割合）。
    private var straightStep = 0.0
    /// この投稿の置き方。基準の置き方を、投稿のIDでばらつかせたもの。
    private var placements: [PhotoStackPlacement] = []
    /// いま写真に渡している置き方。ずらす量はpt。同じなら渡し直さず、並べ直しを繰り返さない。
    private var appliedPlacements: [PhotoStackPlacement] = []
    private var fit: PhotoStackFit?
    private var count = 0
    private var isCovered = false
    /// 写真ごとのぼかしの素材。初めてぼかすときに作る。
    private var covers: [UIVisualEffectView] = []
    /// ぼかしているときに読み上げる文。
    private var coverAccessibilityLabel = ""
    /// ぼかしを押されたときに呼ぶ。読み上げで押されたときも呼ぶ。
    var onReveal: (() -> Void)?

    /// 手前の1枚のサムネイル。押したときの処理を受ける。
    var frontTile: MediaTileView { front.tile }

    /// 描く写真の数の上限。傾けるときは3枚目まで、傾けないときは4枚目まで。
    private var maximumShown: Int {
        tilts ? 3 : photos.count
    }

    /// `index`番目の添付ファイルを開閉する起点のサムネイル。描いていない添付ファイルは、いちばん奥に描いた写真のもの。写真を出していなければnil。
    func tile(at index: Int) -> MediaTileView? {
        let shown = photos.prefix { !$0.isHidden }.count
        guard shown > 0 else { return nil }
        return photos[min(index, shown - 1)].tile
    }

    init(store: MediaImageStore, tuning: TuningStore = AppDependencies.tuning) {
        self.tuning = tuning
        super.init(store: store, photoCount: 4)
        front.isUserInteractionEnabled = true
        front.tile.isUserInteractionEnabled = true
        front.tile.isAccessibilityElement = true
        for (index, photo) in photos.enumerated() {
            // 描いていない添付ファイルは、いちばん奥に描いた写真の位置にあるものとして、その写真を開閉の起点にする。
            // どの写真がいちばん奥になるかは傾けるかと添付の数で変わるため、どの写真でも、描いている添付ファイルかを確かめさせる。
            photo.tile.standsInForOtherAttachments = true
            // ビューアが奥の写真とのあいだで画像を動かすとき、それより手前の写真を画像のさらに手前に重ねる。手前にあるものほど後ろに並べる。
            photo.tile.overlappingViews = Array(photos.prefix(index).reversed())
            // ビューアが画像を動かしている間は、サムネイルだけでなく写真のフチごと隠す。白い枠を一覧に残さないため。
            photo.tile.onConcealedForViewerChange = { [weak photo] concealed in photo?.isConcealed = concealed }
        }
        accessibilityTraits = .button
        followTuning()
    }

    /// 角度、ずらす量、影の濃さを、チューニングの値に合わせ続ける。
    private func followTuning() {
        withObservationTracking {
            applyTuning()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTuning() }
        }
    }

    private func applyTuning() {
        basePlacements = [
            PhotoStackPlacement(rotation: tuning.value(of: TuningCatalog.mediaStackFrontRotation)),
            PhotoStackPlacement(
                rotation: tuning.value(of: TuningCatalog.mediaStackBackRotation),
                offsetX: tuning.value(of: TuningCatalog.mediaStackBackOffsetX),
                offsetY: tuning.value(of: TuningCatalog.mediaStackBackOffsetY)
            ),
            PhotoStackPlacement(
                rotation: tuning.value(of: TuningCatalog.mediaStackThirdRotation),
                offsetX: tuning.value(of: TuningCatalog.mediaStackThirdOffsetX),
                offsetY: tuning.value(of: TuningCatalog.mediaStackThirdOffsetY)
            ),
        ]
        variation = (tuning.value(of: TuningCatalog.mediaStackRotationVariation), tuning.value(of: TuningCatalog.mediaStackOffsetVariation))
        straightStep = tuning.value(of: TuningCatalog.mediaStackStraightStep)
        setShadowOpacities(
            stack: Float(tuning.value(of: TuningCatalog.mediaStackShadowOpacity)),
            between: Float(tuning.value(of: TuningCatalog.mediaStackBetweenShadowOpacity))
        )
        updatePlacements()
    }

    /// 傾けるときは、基準の置き方を投稿のIDでばらつかせる。同じ投稿は、どの行で描いても同じ形になる。
    /// 傾けないときは、まっすぐに置き、奥へ行くほど同じ幅ずつ右下へずらす。等間隔を崩さないよう、ばらつかせない。
    private func updatePlacements() {
        if tilts {
            placements = seed.map {
                PhotoStackVariation.placements(basePlacements, seed: $0, maximumRotation: variation.rotation, maximumOffset: variation.offset)
            } ?? basePlacements
        } else {
            placements = photos.indices.map { index in
                PhotoStackPlacement(rotation: 0, offsetX: straightStep * Double(index), offsetY: straightStep * Double(index))
            }
        }
        setNeedsLayout()
    }

    /// - Parameter coverTitle: ぼかしているときに読み上げる、ぼかしている理由。
    func apply(_ content: MediaGridView.Content, coverTitle: String) {
        if content.stackSeed != seed || content.tiltsStack != tilts {
            seed = content.stackSeed
            tilts = content.tiltsStack
            updatePlacements()
        }
        let attachments = Array(content.attachments.prefix(maximumShown))
        count = attachments.count
        isCovered = content.isCovered
        for (index, photo) in photos.enumerated() {
            guard index < attachments.count else {
                photo.isHidden = true
                photo.tile.apply(nil, hiddenCount: 0, isCovered: false, policy: content.thumbnailPolicy)
                continue
            }
            photo.isHidden = false
            // 奥の写真のバッジは、隅からのぞいて手前の写真のものに見えるため出さない。
            photo.tile.hidesBadge = index > 0 || !content.showsBadges
            photo.tile.apply(attachments[index], hiddenCount: 0, isCovered: content.isCovered, policy: content.thumbnailPolicy)
        }
        if content.isCovered {
            loadCovers()
        }
        for (index, cover) in covers.enumerated() {
            cover.isHidden = !content.isCovered || index >= attachments.count
        }
        // ぼかしている間は、添付ファイルの説明を読まず、ぼかしている理由を読む。押すとぼかしを外す。
        coverAccessibilityLabel = "\(coverTitle)、タップして表示"
        isAccessibilityElement = content.isCovered
        front.tile.isAccessibilityElement = !content.isCovered
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var accessibilityLabel: String? {
        get { isCovered ? coverAccessibilityLabel : nil }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard isCovered else { return false }
        onReveal?()
        return true
    }

    /// 写真ごとのぼかしを作る。サムネイルの中に入れ、写真と一緒に回る。目の記号は手前の写真にだけ出す。
    private func loadCovers() {
        guard covers.isEmpty else { return }
        covers = photos.map { photo in
            let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            effect.isUserInteractionEnabled = false
            effect.frame = photo.tile.bounds
            effect.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if photo === front {
                let symbol = UIImageView(image: UIImage(systemName: "eye.slash"))
                symbol.tintColor = .secondaryLabel
                symbol.contentMode = .center
                symbol.frame = effect.contentView.bounds
                symbol.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                effect.contentView.addSubview(symbol)
            }
            photo.tile.addSubview(effect)
            return effect
        }
    }

    /// 重なりのどこを押しても、手前の1枚を押したことにする。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, !front.isHidden, bounds.contains(point) else { return super.hitTest(point, with: event) }
        return front.tile
    }

    /// 正方形に収める写真の大きさと位置を決めてから、写真を置く。
    override func layoutSubviews() {
        let fit = PhotoStackFit(placements: placements, count: count, side: min(bounds.width, bounds.height))
        self.fit = fit
        photoSide = fit.photoSide
        let scaled = placements.map {
            PhotoStackPlacement(rotation: $0.rotation, offsetX: $0.offsetX * fit.photoSide, offsetY: $0.offsetY * fit.photoSide)
        }
        if scaled != appliedPlacements {
            appliedPlacements = scaled
            setPlacements(scaled)
        }
        super.layoutSubviews()
    }

    override func frontCenter() -> CGPoint {
        fit?.frontCenter ?? CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
