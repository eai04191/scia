import Observation
import SciaCore
import UIKit

/// 書いていないときのカプセルの1行。返信や編集のラベルのアイコン、予約の時計、添付のサムネイル、自分で書いた本文を、この順に並べる。
/// ラベルは文字を出さずアイコンだけにする。開閉では、ラベルのアイコンとサムネイルを、書いているときのラベルと列の同じものとのあいだで動かすため、それぞれを外から読めるようにする。
@MainActor
final class ComposeRestContent: UIView {
    let chipIcon = UIImageView()
    /// 予約しているときの時計。
    let scheduleIcon = UIImageView(image: UIImage(systemName: "clock"))
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
        scheduleIcon.tintColor = .tintColor
        scheduleIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .small)
        scheduleIcon.setContentHuggingPriority(.required, for: .horizontal)
        scheduleIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        scheduleIcon.isHidden = true
        thumbnails.setContentHuggingPriority(.required, for: .horizontal)
        thumbnails.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [chipIcon, scheduleIcon, thumbnails, label] {
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

    /// - Parameters:
    ///   - symbolName: ラベルのアイコン。返信も編集もしていなければnil。
    ///   - showsSchedule: 予約している。
    func configure(symbolName: String?, showsSchedule: Bool, attachments: [ComposeAttachmentStrip.Item], text: NSAttributedString) {
        chipIcon.image = symbolName.flatMap { UIImage(systemName: $0) }
        setHidden(chipIcon, symbolName == nil)
        setHidden(scheduleIcon, !showsSchedule)
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

/// カプセルに出す添付のサムネイル。重ね方は`PhotoStackView`にあり、ここではカプセルの1行の高さに収める大きさと、チューニングで決める置き方を渡す。
/// 送れなかった添付があるときだけ、エラーのアイコンを付ける。
/// 角度と影の濃さは好みで決まるので、チューニングの値で決める。投稿欄を勢いよく閉じたときは、正解の置き方から散らばらせる。
@MainActor
final class ComposeRestThumbnails: PhotoStackView {
    private let tuning: TuningStore
    private(set) var frontID: DraftAttachment.ID?
    private(set) var backID: DraftAttachment.ID?
    private(set) var thirdID: DraftAttachment.ID?

    init(tuning: TuningStore = AppDependencies.tuning) {
        self.tuning = tuning
        super.init(store: AppDependencies.mediaImages)
        isUserInteractionEnabled = false
        followTuning()
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
        setPlacements(basePlacements)
        setShadowOpacities(stack: Self.stackShadowOpacity(in: tuning), between: Float(tuning.value(of: TuningCatalog.composeStackBetweenShadowOpacity)))
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
        setPlacements(scatteredPlacements ?? basePlacements)
    }

    /// 写真のスタックがカプセルの面に落とす影の濃さ。開閉で動かす複製の影も、カプセルに着くときにこの濃さにする。
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
    func photo(for id: DraftAttachment.ID) -> StackedPhotoView? {
        if id == frontID { return front }
        if id == backID, !back.isHidden { return back }
        if id == thirdID, !third.isHidden { return third }
        return nil
    }
}

extension StackedPhotoView {
    func apply(_ item: ComposeAttachmentStrip.Item) {
        if let attached = item.attachedMedia {
            tile.apply(attached, hiddenCount: 0, isCovered: false, policy: ComposeAttachmentStrip.attachedThumbnailPolicy)
        } else {
            tile.applyLocal(thumbnail: item.local?.thumbnail, kind: item.local?.displayKind, description: "")
        }
    }
}
