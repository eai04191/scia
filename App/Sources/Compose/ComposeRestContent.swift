import Observation
import SciaCore
import UIKit

/// 書いていないときのカプセルの1行。返信や編集の札のアイコン、添付のサムネイル、自分で書いた本文を、この順に並べる。
/// 札は文字を出さずアイコンだけにする。開閉では、札のアイコンとサムネイルを、書いているときの札と列の同じものとのあいだで動かすため、それぞれを外から読めるようにする。
@MainActor
final class ComposeRestContent: UIView {
    let chipIcon = UIImageView()
    let thumbnails = ComposeRestThumbnails()
    let label = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        chipIcon.tintColor = .tintColor
        chipIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .small)
        chipIcon.setContentHuggingPriority(.required, for: .horizontal)
        chipIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        thumbnails.setContentHuggingPriority(.required, for: .horizontal)
        thumbnails.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [chipIcon, thumbnails, label] {
            stack.addArrangedSubview(view)
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter symbolName: 札のアイコン。返信も編集もしていなければnil。
    func configure(symbolName: String?, attachments: [ComposeAttachmentStrip.Item], text: NSAttributedString) {
        chipIcon.image = symbolName.flatMap { UIImage(systemName: $0) }
        setHidden(chipIcon, symbolName == nil)
        thumbnails.update(attachments)
        setHidden(thumbnails, attachments.isEmpty)
        label.attributedText = text
    }

    /// スタックビューの行は、値が変わるときだけ隠したり出したりする。同じ値を代入し直すと、隠したものとして並べたまま見えることがあるため。
    private func setHidden(_ view: UIView, _ hidden: Bool) {
        guard view.isHidden != hidden else { return }
        view.isHidden = hidden
    }
}

/// カプセルに出す添付のサムネイル。1枚目を手前にして、3枚目までを重ねる。
/// アイコンのように見えないよう、白いフチを付けた紙焼きの写真に見立て、2枚目は1枚目の下に重ねる。
/// 手で置いた写真らしく、1枚目も真っすぐにはせず、2枚目と逆の向きにわずかに回す。
/// 3枚目は、2枚だけが置かれて見える不自然さをなくすためのもので、いちばん下に置き、1枚目の左上側から、2枚目と逆の向きに回してのぞかせる。
/// 2枚目と同じ右側からのぞかせると、縁がほぼ平行に並んでずれて見え、束の形も右へ偏るため。
/// 4枚目より後ろは3枚目の下に隠れているものとし、枚数の札は付けない。添付がないか、1枚か、それより多いかが分かれば足りるため。
/// 送れなかった添付があるときだけ、エラーのアイコンを付ける。
/// 角度と影の濃さは好みで決まるので、チューニングの値で決める。
///
/// 影は、写真の束がカプセルの面に落とす影と、上の写真が下の写真に落とす影の2つに分ける。写真ごとに影を付けると、
/// 重なったところで影が二重に濃くなり、写真の上に落ちる影もカプセルの面に落ちる影と同じ広さになるため。
@MainActor
final class ComposeRestThumbnails: UIView {
    private let tuning: TuningStore
    /// 手前の1枚を回す角度（ラジアン）。
    private var frontRotation: CGFloat = 0
    /// 奥の1枚を回す角度（ラジアン）。
    private var backRotation: CGFloat = 0
    /// 奥の1枚の中心を、手前の1枚の中心からずらす量。
    private var backOffset = CGPoint.zero
    /// 3枚目を回す角度（ラジアン）。
    private var thirdRotation: CGFloat = 0
    /// 3枚目の中心を、手前の1枚の中心からずらす量。
    private var thirdOffset = CGPoint.zero
    /// 写真同士の影の濃さ。
    private var betweenShadowOpacity: Float = 0

    /// 写真の一辺（フチを含む）。カプセルの1行の高さに収まるよう、行の高さから決める。
    var photoSide: CGFloat = 26 {
        didSet {
            guard photoSide != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// 写真の束がカプセルの面に落とす影。重ねた写真の輪郭を合わせた形で、影を1つだけ落とす。
    private let stackShadow = UIView()
    /// 手前の1枚。1枚目の添付。
    let front = ComposeRestPhoto()
    /// 奥の1枚。2枚目の添付。2枚以上のときだけ出す。
    let back = ComposeRestPhoto()
    /// 2枚目の下の1枚。3枚目の添付。3枚以上のときだけ出す。
    let third = ComposeRestPhoto()
    private(set) var frontID: DraftAttachment.ID?
    private(set) var backID: DraftAttachment.ID?
    private(set) var thirdID: DraftAttachment.ID?

    init(tuning: TuningStore = AppDependencies.tuning) {
        self.tuning = tuning
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        stackShadow.isUserInteractionEnabled = false
        for view in [stackShadow, third, back, front] {
            addSubview(view)
        }
        followTuning()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 角度と影の濃さを、チューニングの値に合わせ続ける。
    private func followTuning() {
        withObservationTracking {
            applyTuning()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTuning() }
        }
    }

    /// チューニングで決めた正解の置き方（1枚目、2枚目、3枚目）。
    private var basePlacements: [PhotoStackPlacement] = []
    /// 勢いよく閉じて散らばらせた置き方。散らばらせていなければnilで、正解の置き方を使う。次に散らばらせ直すか、チューニングを変えるまで残す。
    private var scatteredPlacements: [PhotoStackPlacement]?

    private func applyTuning() {
        basePlacements = [
            PhotoStackPlacement(rotation: tuning.value(of: TuningCatalog.composeStackFrontRotation)),
            PhotoStackPlacement(
                rotation: tuning.value(of: TuningCatalog.composeStackBackRotation),
                offsetX: tuning.value(of: TuningCatalog.composeStackBackOffsetX),
                offsetY: tuning.value(of: TuningCatalog.composeStackBackOffsetY)
            ),
            PhotoStackPlacement(
                rotation: tuning.value(of: TuningCatalog.composeStackThirdRotation),
                offsetX: tuning.value(of: TuningCatalog.composeStackThirdOffsetX),
                offsetY: tuning.value(of: TuningCatalog.composeStackThirdOffsetY)
            ),
        ]
        // 正解を調整しているときは、調整した形をそのまま見せる。
        scatteredPlacements = nil
        applyPlacements()
        ComposeRestShadow.castStack(on: stackShadow.layer, opacity: Self.stackShadowOpacity(in: tuning))
        betweenShadowOpacity = Float(tuning.value(of: TuningCatalog.composeStackBetweenShadowOpacity))
    }

    /// 投稿欄を下げた速さ（pt/秒、下向きが正）に応じて、正解の置き方から散らばらせる。遅ければ、またはチューニングでオフなら、正解の置き方に戻す。
    func scatter(velocity: Double) {
        let intensity = tuning.value(of: TuningCatalog.composeStackScatter)
            ? PhotoStackScatter.intensity(
                velocity: velocity,
                minimumVelocity: tuning.value(of: TuningCatalog.composeStackScatterMinVelocity),
                maximumVelocity: tuning.value(of: TuningCatalog.composeStackScatterMaxVelocity)
            )
            : 0
        if intensity > 0 {
            var generator = SystemRandomNumberGenerator()
            scatteredPlacements = PhotoStackScatter.scatter(
                basePlacements,
                intensity: intensity,
                maximumRotation: tuning.value(of: TuningCatalog.composeStackScatterRotation),
                maximumOffset: tuning.value(of: TuningCatalog.composeStackScatterOffset),
                using: &generator
            )
        } else {
            scatteredPlacements = nil
        }
        applyPlacements()
    }

    private func applyPlacements() {
        let placements = scatteredPlacements ?? basePlacements
        guard placements.count == 3 else { return }
        let degree = CGFloat.pi / 180
        frontRotation = placements[0].rotation * degree
        backRotation = placements[1].rotation * degree
        backOffset = CGPoint(x: placements[1].offsetX, y: placements[1].offsetY)
        thirdRotation = placements[2].rotation * degree
        thirdOffset = CGPoint(x: placements[2].offsetX, y: placements[2].offsetY)
        front.transform = CGAffineTransform(rotationAngle: frontRotation)
        back.transform = CGAffineTransform(rotationAngle: backRotation)
        third.transform = CGAffineTransform(rotationAngle: thirdRotation)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// 写真の束がカプセルの面に落とす影の濃さ。開閉で動かす複製の影も、カプセルに着くときにこの濃さにする。
    static func stackShadowOpacity(in tuning: TuningStore) -> Float {
        Float(tuning.value(of: TuningCatalog.composeStackShadowOpacity))
    }

    func update(_ items: [ComposeAttachmentStrip.Item]) {
        frontID = items.first?.attachment.id
        backID = items.count > 1 ? items[1].attachment.id : nil
        if let first = items.first {
            front.apply(first)
        }
        back.isHidden = items.count < 2
        if items.count > 1 {
            back.apply(items[1])
        }
        thirdID = items.count > 2 ? items[2].attachment.id : nil
        third.isHidden = items.count < 3
        if items.count > 2 {
            third.apply(items[2])
        }
        // エラーのアイコンは手前の写真に載せ、開閉では写真と一緒に隠して動かす。カプセルに残すと、写真が着く前にアイコンだけが現れるため。
        front.showsFailure = items.contains { $0.status == .failed || $0.status == .descriptionFailed }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// 添付の写真。開閉で、列の同じ添付とのあいだを動かす起点と行き先にする。出していなければnil。
    func photo(for id: DraftAttachment.ID) -> ComposeRestPhoto? {
        if id == frontID { return front }
        if id == backID, !back.isHidden { return back }
        if id == thirdID, !third.isHidden { return third }
        return nil
    }

    /// 開閉で写真を隠している間は、束の影も隠す。動かす複製がまとめて影を落とすため。
    func setStackShadowConcealed(_ concealed: Bool) {
        stackShadow.alpha = concealed ? 0 : 1
    }

    /// 写真同士の影を、薄い状態から浮かび上がらせる。開閉で写真が着いたあとに呼ぶ。動いている間の複製は、写真同士の影を落とさないため。
    func revealBetweenShadows(duration: TimeInterval) {
        for photo in [front, back, third] {
            photo.revealBetweenShadow(duration: duration)
        }
    }

    /// 見えている写真の、1枚目の中心から見た左右の端。回した写真の角も含める。束の幅はこの間にし、1枚目を左端からこの分だけ右に置く。
    private var horizontalExtent: (minX: CGFloat, maxX: CGFloat) {
        let half = photoSide / 2
        var placements = [(offset: CGFloat(0), rotation: frontRotation)]
        if !back.isHidden {
            placements.append((backOffset.x, backRotation))
        }
        if !third.isHidden {
            placements.append((thirdOffset.x, thirdRotation))
        }
        let extents = placements.map { placement in
            let reach = half * (abs(cos(placement.rotation)) + abs(sin(placement.rotation)))
            return (placement.offset - reach, placement.offset + reach)
        }
        return (extents.map(\.0).min() ?? -half, extents.map(\.1).max() ?? half)
    }

    /// 回した写真が上下にはみ出す分は、行の高さに収まらないので幅だけ取り、上下ははみ出させる。
    override var intrinsicContentSize: CGSize {
        let extent = horizontalExtent
        return CGSize(width: extent.maxX - extent.minX, height: photoSide)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: photoSide, height: photoSide)
        let frontCenter = CGPoint(x: -horizontalExtent.minX, y: bounds.midY)
        front.bounds.size = size
        front.center = frontCenter
        back.bounds.size = size
        back.center = CGPoint(x: frontCenter.x + backOffset.x, y: frontCenter.y + backOffset.y)
        third.bounds.size = size
        third.center = CGPoint(x: frontCenter.x + thirdOffset.x, y: frontCenter.y + thirdOffset.y)
        layoutShadows()
    }

    /// 束の影は見えている写真の輪郭を合わせた形で、写真同士の影は、下の写真の中に、それより上の写真の輪郭で落とす。
    private func layoutShadows() {
        let stacked = [front, back, third].filter { !$0.isHidden }
        stackShadow.frame = bounds
        let union = UIBezierPath()
        for photo in stacked {
            union.append(outline(of: photo))
        }
        stackShadow.layer.shadowPath = union.cgPath
        for (index, photo) in stacked.enumerated() {
            let above = stacked.prefix(index)
            guard !above.isEmpty else {
                photo.setBetweenShadow(outline: nil, opacity: 0)
                continue
            }
            let outline = UIBezierPath()
            for upper in above {
                outline.append(self.outline(of: upper))
            }
            // 束の中の位置から、下の写真の中の位置へ移す。
            let toPhoto = CGAffineTransform(translationX: -photo.center.x, y: -photo.center.y)
                .concatenating(photo.transform.inverted())
                .concatenating(CGAffineTransform(translationX: photo.bounds.width / 2, y: photo.bounds.height / 2))
            outline.apply(toPhoto)
            photo.setBetweenShadow(outline: outline.cgPath, opacity: betweenShadowOpacity)
        }
    }

    /// 写真の輪郭を、束の中の位置で返す。
    private func outline(of photo: UIView) -> UIBezierPath {
        let size = photo.bounds.size
        let path = UIBezierPath(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), cornerRadius: ComposeRestPhoto.cornerRadius)
        path.apply(photo.transform)
        path.apply(CGAffineTransform(translationX: photo.center.x, y: photo.center.y))
        return path
    }
}

/// カプセルに重ねた写真の影の形。写真は薄いので、写真同士の影は、束がカプセルの面に落とす影より近く、ぼかしも小さい。
enum ComposeRestShadow {
    /// 写真の束がカプセルの面に落とす影。
    static func castStack(on layer: CALayer, opacity: Float) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 0.5)
    }

    /// 上の写真が下の写真に落とす影。
    static func castBetween(on layer: CALayer, opacity: Float) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = 0.75
        layer.shadowOffset = CGSize(width: 0, height: 0.25)
    }
}

/// 白いフチの付いた紙焼きの写真。自分では影を落とさず、上に重ねた写真の影を、自分の中にだけ描く。
@MainActor
final class ComposeRestPhoto: UIView {
    static let border: CGFloat = 2
    static let cornerRadius: CGFloat = 3

    let tile = MediaTileView(store: AppDependencies.mediaImages)
    /// 上に重ねた写真の影を、この写真の外にはみ出させずに描く枠。
    private let betweenShadowClip = UIView()
    private let betweenShadow = CALayer()
    private let failureMark = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))

    /// 送れなかった添付があることを、右下の角にアイコンで出す。
    var showsFailure = false {
        didSet { failureMark.isHidden = !showsFailure }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .white
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        tile.isUserInteractionEnabled = false
        tile.isAccessibilityElement = false
        // 小さな枠では、ALTやGIFの札は読めないうえ、カプセルに文字を増やすため出さない。
        tile.hidesBadge = true
        tile.layer.cornerRadius = Self.cornerRadius - Self.border / 2
        // 回して置くので、縁がギザギザにならないよう、紙と中の画像の縁をなめらかに描く。
        layer.allowsEdgeAntialiasing = true
        tile.layer.allowsEdgeAntialiasing = true
        addSubview(tile)
        betweenShadowClip.isUserInteractionEnabled = false
        betweenShadowClip.clipsToBounds = true
        betweenShadowClip.layer.cornerRadius = Self.cornerRadius
        betweenShadowClip.layer.cornerCurve = .continuous
        betweenShadowClip.layer.addSublayer(betweenShadow)
        addSubview(betweenShadowClip)
        // 感嘆符を白、円を赤で描き、どんなサムネイルの上でも見分けられるようにする。列のエラーのアイコンと同じ。
        failureMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12).applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        failureMark.isHidden = true
        addSubview(failureMark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ item: ComposeAttachmentStrip.Item) {
        if let attached = item.attachedMedia {
            tile.apply(attached, hiddenCount: 0, isCovered: false, policy: ComposeAttachmentStrip.attachedThumbnailPolicy)
        } else {
            tile.applyLocal(thumbnail: item.local?.thumbnail, kind: item.local?.file?.kind, description: "")
        }
    }

    /// 上に重ねた写真の輪郭（この写真の中の位置）で、影を落とす。上に写真がなければnil。
    func setBetweenShadow(outline: CGPath?, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        betweenShadow.shadowPath = outline
        ComposeRestShadow.castBetween(on: betweenShadow, opacity: outline == nil ? 0 : opacity)
        CATransaction.commit()
    }

    func revealBetweenShadow(duration: TimeInterval) {
        UIView.performWithoutAnimation { betweenShadowClip.alpha = 0 }
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.betweenShadowClip.alpha = 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tile.frame = bounds.insetBy(dx: Self.border, dy: Self.border)
        betweenShadowClip.frame = bounds
        betweenShadow.frame = bounds
        let mark = failureMark.intrinsicContentSize
        failureMark.frame = CGRect(x: bounds.maxX - mark.width / 2 - 1, y: bounds.maxY - mark.height / 2 - 1, width: mark.width, height: mark.height)
    }
}
