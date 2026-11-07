public import CoreGraphics

/// 「投稿の見た目」と「通知の見た目」で項目を触っている間に、プレビューのどこを示すか。
public enum AppearanceHighlight: Equatable, Sendable {
    /// 部品そのもの。大きさや文字、内側の余白の項目。
    case part(AppearancePreviewPart)
    /// 候補のうち、見本のどこかで先に見つかった部品。行数を0にして消える部品のように、ないときは囲んでいる部品を示す。
    /// 候補は見本全体で順に探す。行ごとに試すと、上の行にある後ろの候補が、下の行にある先の候補より先に選ばれるため。
    case firstPart([AppearancePreviewPart])
    /// 上の部品と下の部品のあいだ。どちらも、候補のうち先に見つかったものを使う。
    /// `absent`の部品がある行は使わない。本文のない投稿だけの余白を、本文のある投稿で示さないため。
    case verticalGap(above: [AppearancePreviewPart], below: [AppearancePreviewPart], absent: [AppearancePreviewPart] = [])
    /// 左の部品と右の部品のあいだ。
    case horizontalGap(leading: [AppearancePreviewPart], trailing: [AppearancePreviewPart])
    /// 候補を順に試し、見本のどこかで示せた最初のもの。名前の表記によって出ない部品のあいだを、出ないときは行全体で示すのに使う。
    indirect case firstOf([AppearanceHighlight])
    /// 1つの行の中で、候補のうち出ている部品のすべて。字形や絵文字のように、行の中のいくつもの部品に効く選択肢に使う。
    case allParts([AppearancePreviewPart])

    /// 余白が0でも見えるよう、あいだを示す帯をこれより細くしない。
    public static let minimumGapThickness: CGFloat = 2

    /// 項目に対応する場所。プレビューで示せない項目はnil。
    public init?(_ item: AppearanceValue) {
        guard let highlight = Self.highlights[item.id] else { return nil }
        self = highlight
    }

    /// 項目ごとの、プレビューで示す場所。項目は投稿の部品ごとの並びで書く。
    /// 名前の表記で出ないことのある「添える部分」は、出ていなければその行全体を示す。
    private static let highlights: [AppearanceValue.ID: AppearanceHighlight] = {
        typealias C = AppearanceCatalog
        let pairs: [(AppearanceValue, AppearanceHighlight)] = [
            (C.rowPaddingTop, .part(.rowPaddingTop)),
            (C.rowPaddingBottom, .part(.rowPaddingBottom)),
            (C.rowPaddingLeading, .part(.rowPaddingLeading)),
            (C.rowPaddingTrailing, .part(.rowPaddingTrailing)),

            (C.contextText, .part(.contextText)),
            (C.contextLabelText, .firstOf([.part(.replyLabel), .part(.replyLabelSlot)])),
            (C.contextSecondaryText, .firstPart([.contextSecondary, .contextLine])),
            (C.contextPartsSpacing, .firstOf([.horizontalGap(leading: [.contextText], trailing: [.contextSecondary]), .part(.contextLine)])),
            (C.boosterAvatarSize, .firstOf([.part(.contextAvatar), .part(.boosterAvatarSlot)])),
            (C.contextSymbolSpacing, .horizontalGap(leading: [.contextSymbol], trailing: [.contextAvatar, .contextText])),
            (C.contextAvatarTextSpacing, .firstOf([.horizontalGap(leading: [.contextAvatar], trailing: [.contextText]), .part(.boosterAvatarSlot)])),
            (C.contextSpacing, .verticalGap(above: [.contextLine], below: [.nameRow])),

            (C.avatarSize, .part(.avatar)),
            (C.avatarCornerRatio, .part(.avatarCorners)),
            (C.avatarSpacing, .horizontalGap(leading: [.avatar], trailing: [.nameRow])),
            (C.replyLineWidth, .firstOf([.part(.replyLineBelow), .part(.replyLineSlot)])),
            (C.replyLineGap, .firstOf([.verticalGap(above: [.avatar], below: [.replyLineBelow]), .part(.replyLineSlot)])),

            (C.namePrimaryText, .part(.namePrimary)),
            (C.nameSecondaryText, .firstPart([.nameSecondary, .nameRow])),
            (C.timeText, .firstOf([.part(.time), .part(.timeSlot)])),
            (C.namePartsSpacing, .firstOf([.horizontalGap(leading: [.namePrimary], trailing: [.nameSecondary]), .part(.nameRow)])),
            // 2段に分けていないと効かないので、分けていなければ名前の行を示す。
            (C.nameStackSpacing, .firstOf([.verticalGap(above: [.nameFirstLineGlyphs], below: [.nameSecondLineGlyphs]), .part(.nameRow)])),
            // 時刻は右端に寄せるので、名前が短いと最小のすき間より広く空き、値を変えても見た目が変わらない。名前が時刻に詰まった投稿で示す。
            (C.nameTimeSpacing, .firstOf([.part(.nameTimeMinGap), .horizontalGap(leading: [.nameSecondary, .namePrimary], trailing: [.time]), .part(.timeSlot)])),
            (C.visibilitySymbolSpacing, .firstOf([.part(.visibilitySymbolGap), .part(.visibilitySymbol)])),
            (C.editedMarkSpacing, .firstOf([.part(.editedMarkGap), .part(.editedMark)])),
            (C.nameFadeWidth, .firstOf([.part(.nameFade), .part(.nameRow)])),
            (C.nameUnicodeEmojiScale, .firstOf([.part(.nameUnicodeEmojis), .part(.nameRow)])),
            (C.nameCustomEmojiScale, .firstOf([.part(.nameCustomEmojis), .part(.nameRow)])),
            // アイコンの下を空けないときは、アイコンと名前の段の下にあるほうから測る。
            (C.nameBodySpacing, .verticalGap(above: [.postHeader, .nameGlyphs], below: [.spoiler, .bodyGlyphs])),
            (C.nameMediaSpacing, .verticalGap(above: [.postHeader, .nameGlyphs], below: [.media], absent: [.spoiler, .bodyText])),

            (C.bodyText, .part(.bodyText)),
            (C.bodyLineSpacing, .firstOf([.part(.bodyLineGaps), .part(.bodyText)])),
            (C.paragraphSpacing, .firstOf([.part(.bodyParagraphGaps), .part(.bodyText)])),
            (C.quoteIndent, .firstOf([.part(.quoteIndent), .part(.bodyText)])),
            (C.quoteBarWidth, .firstOf([.part(.quoteBars), .part(.bodyText)])),
            (C.unicodeEmojiScale, .firstOf([.part(.unicodeEmojis), .part(.bodyText)])),
            (C.customEmojiScale, .firstOf([.part(.customEmojis), .part(.bodyText)])),
            (C.emojiOnlyScale, .firstOf([.part(.emojiOnlyEmojis), .part(.emojiOnlyBody)])),
            (C.emojiOnlyLimit, .part(.emojiOnlyBody)),
            (C.bodyTruncationThreshold, .part(.truncatedBody)),
            (C.bodyTruncatedLines, .part(.truncatedBody)),
            (C.filterNoteText, .part(.filterNote)),
            (C.filterNoteSpacing, .verticalGap(above: [.reactions, .card, .poll, .media, .bodyGlyphs], below: [.filterNote])),

            (C.spoilerButtonText, .part(.spoilerButton)),
            (C.spoilerButtonSpacing, .verticalGap(above: [.spoilerText], below: [.spoilerButton])),
            (C.spoilerPadding, .part(.spoilerPaddingBands)),
            (C.spoilerCornerRadius, .part(.spoilerCorners)),
            (C.spoilerBodySpacing, .verticalGap(above: [.spoiler], below: [.bodyGlyphs])),

            // 本文の右に出すときは、本文とサムネイルの横のすき間になる。
            (C.bodyMediaSpacing, .firstOf([.verticalGap(above: [.bodyGlyphs], below: [.media]), .horizontalGap(leading: [.bodyText], trailing: [.besideMedia])])),
            (C.mediaTileSpacing, .part(.mediaTileGaps)),
            (C.mediaTallestAspectRatio, .firstOf([.part(.singleTallMedia), .part(.singleMedia)])),
            (C.mediaWidestAspectRatio, .firstOf([.part(.singleWideMedia), .part(.singleMedia)])),
            // 本文の下に並べているときは効かないが、何の大きさかが分かるよう、並べた添付ファイルを示す。
            // 引用とXの投稿だけを本文の右に出すときは、大きさの効く囲みの中のメディアを示す。
            (C.mediaBesideSide, .firstOf([.part(.besideMedia), .part(.xPostBesideMedia), .part(.media)])),

            (C.linkCardTitleText, .part(.cardTitle)),
            (C.linkCardDetailText, .firstOf([.part(.cardDetail), .part(.card)])),
            (C.linkCardTitleLines, .part(.cardTitle)),
            (C.linkCardImageWidthRatio, .firstOf([.part(.cardImage), .part(.cardImageSlot)])),
            (C.linkCardDescriptionLines, .firstPart([.cardDescription, .card])),
            (C.linkCardLineSpacing, .firstOf([.part(.cardLineGaps), .part(.card)])),
            (C.bodyLinkCardSpacing, .verticalGap(above: [.media, .bodyGlyphs], below: [.card])),
            (C.linkCardPadding, .part(.cardPaddingBands)),

            (C.xPostNameText, .part(.xPostName)),
            (C.xPostBodyText, .part(.xPostBody)),
            (C.xPostAvatarSize, .part(.xPostAvatar)),
            (C.xPostAvatarNameSpacing, .horizontalGap(leading: [.xPostAvatar], trailing: [.xPostName])),
            (C.xPostHeaderSpacing, .verticalGap(above: [.xPostHeader], below: [.xPostBody])),
            (C.xPostMediaSpacing, .firstOf([.verticalGap(above: [.xPostBody], below: [.xPostMedia]), .horizontalGap(leading: [.xPostBody], trailing: [.xPostBesideMedia])])),
            (C.xPostPadding, .part(.xPostPaddingBands)),
            (C.bodyXPostSpacing, .verticalGap(above: [.media, .bodyGlyphs], below: [.xPost])),

            (C.pollFooterText, .part(.pollSummary)),
            (C.bodyPollSpacing, .verticalGap(above: [.bodyGlyphs], below: [.poll])),
            (C.pollOptionSpacing, .part(.pollOptionGaps)),
            (C.pollOptionPadding, .part(.pollOptionPadding)),
            (C.pollOptionHorizontalPadding, .part(.pollOptionSidePadding)),
            (C.pollOptionCornerRadius, .part(.pollOptionCorners)),
            (C.pollFooterSpacing, .verticalGap(above: [.pollOptions], below: [.pollFooter])),

            (C.reactionText, .part(.reactionChips)),
            (C.bodyReactionsSpacing, .verticalGap(above: [.card, .xPost, .poll, .media, .bodyGlyphs, .spoiler], below: [.reactions])),
            (C.reactionSpacing, .part(.reactionGaps)),
            (C.reactionPadding, .part(.reactionPaddingBands)),
            (C.reactionHorizontalPadding, .part(.reactionSidePaddingBands)),

            (C.actionBarSpacing, .verticalGap(above: [.filterNote, .reactions, .card, .xPost, .poll, .media, .bodyGlyphs, .spoiler], below: [.actionBar])),
            (C.actionBarIconSize, .part(.actionBarIcons)),
            (C.actionBarPadding, .part(.actionBarPaddingBands)),

            (C.reactionGlowHeight, .part(.reactionGlow)),
            (C.reactionGlowDarkOpacity, .part(.reactionGlow)),
            (C.reactionGlowLightOpacity, .part(.reactionGlow)),
            (C.reactionGlowBlendWidth, .part(.reactionGlowBlend)),
            // アイコンを出さない設定では、アイコンが出る光を示す。
            (C.reactionGlowIconSize, .firstOf([.part(.reactionGlowIcons), .part(.reactionGlow)])),
            (C.reactionGlowIconOpacity, .firstOf([.part(.reactionGlowIcons), .part(.reactionGlow)])),
        ]
        typealias N = NotificationAppearanceCatalog
        let notificationPairs: [(AppearanceValue, AppearanceHighlight)] = [
            (N.groupAvatarSize, .part(.groupAvatars)),
            (N.groupAvatarSpacing, .part(.groupAvatarGaps)),
            (N.groupAvatarHeaderSpacing, .verticalGap(above: [.groupAvatars], below: [.notificationHeader])),

            (N.headerText, .part(.notificationHeader)),
            (N.headerAvatarSize, .firstOf([.part(.notificationHeaderAvatar), .part(.notificationHeader)])),
            (N.headerAvatarNameSpacing, .firstOf([.part(.notificationHeaderAvatarGap), .part(.notificationHeader)])),

            // メンションなどの名前の上の行の記号も同じ幅で置くので、誰が何をしたかの行がなければ、そちらで示す。
            (N.symbolSpacing, .firstOf([
                .horizontalGap(leading: [.notificationSymbol], trailing: [.notificationHeader]),
                .horizontalGap(leading: [.contextSymbol], trailing: [.contextText]),
            ])),

            (N.accountText, .part(.notificationAccount)),
            (N.accountSpacing, .verticalGap(above: [.notificationHeaderGlyphs], below: [.notificationAccountGlyphs])),

            (N.quotedSpacing, .verticalGap(above: [.notificationHeaderGlyphs], below: [.quotedSpoiler, .quotedBodyGlyphs, .quotedMedia])),
            (N.quotedBodyText, .part(.quotedBodyText)),
            (N.quotedBodyLines, .part(.quotedBodyText)),
            (N.quotedMediaSpacing, .verticalGap(above: [.quotedBodyGlyphs], below: [.quotedMedia])),
            (N.quotedThumbnailSize, .part(.quotedThumbnails)),
            (N.quotedThumbnailSpacing, .part(.quotedThumbnailGaps)),
            // 投票は添付ファイルの下に置くので、添付ファイルのない行で示す。
            (N.quotedPollSpacing, .verticalGap(above: [.quotedBodyGlyphs], below: [.quotedPoll], absent: [.quotedMedia])),
            (N.quotedNoteText, .part(.quotedNote)),
            (N.quotedNoteSpacing, .verticalGap(above: [.quotedPoll, .quotedMedia, .quotedBodyGlyphs], below: [.quotedNote])),

            (N.contextText, .part(.contextLine)),
            (N.contextSpacing, .verticalGap(above: [.contextLine], below: [.nameRow])),
        ]
        return Dictionary(uniqueKeysWithValues: (pairs + notificationPairs).map { ($0.0.id, $0.1) })
    }()

    /// プレビューの行を上から順に見て、示せる最初の行と、その行の座標での枠を返す。
    public func locate(in rows: [AppearancePreviewFrames]) -> (row: Int, rects: [CGRect], style: Style)? {
        if case .firstOf(let candidates) = self {
            return candidates.lazy.compactMap { $0.locate(in: rows) }.first
        }
        if case .firstPart(let parts) = self {
            return parts.lazy.compactMap { AppearanceHighlight.part($0).locate(in: rows) }.first
        }
        for (index, frames) in rows.enumerated() {
            if let found = rects(in: frames) {
                return (index, found.rects, found.style)
            }
        }
        return nil
    }

    /// 示す場所の描き方。
    public enum Style {
        /// 部品の少し外側に枠を引き、中の部品を隠さない。部品の大きさや文字を変える項目に使う。
        case enclose
        /// その場所を塗る。すき間や余白のように、塗る場所に部品がない項目に使う。
        case fill
    }

    private func rects(in frames: AppearancePreviewFrames) -> (rects: [CGRect], style: Style)? {
        func union(_ candidates: [AppearancePreviewPart]) -> CGRect? {
            candidates.lazy.compactMap { frames[$0] }.first?.reduce(CGRect.null) { $0.union($1) }
        }
        switch self {
        case .firstOf(let candidates):
            return candidates.lazy.compactMap { $0.rects(in: frames) }.first
        case .allParts(let parts):
            let rects = parts.compactMap { frames[$0] }.flatMap(\.self)
            return rects.isEmpty ? nil : (rects, .enclose)
        case .part(let part):
            return frames[part].map { ($0, part.isArea ? .fill : .enclose) }
        case .firstPart(let parts):
            return parts.lazy.compactMap { part in frames[part].map { ($0, part.isArea ? Style.fill : .enclose) } }.first
        case .verticalGap(let above, let below, let absent):
            guard absent.allSatisfy({ frames[$0] == nil }), let top = union(above), let bottom = union(below) else { return nil }
            let minX = min(top.minX, bottom.minX)
            let width = max(top.maxX, bottom.maxX) - minX
            return ([Self.band(from: top.maxY, to: bottom.minY) { CGRect(x: minX, y: $0, width: width, height: $1) }], .fill)
        case .horizontalGap(let leading, let trailing):
            guard let left = union(leading), let right = union(trailing) else { return nil }
            let minY = min(left.minY, right.minY)
            let height = max(left.maxY, right.maxY) - minY
            return ([Self.band(from: left.maxX, to: right.minX) { CGRect(x: $0, y: minY, width: $1, height: height) }], .fill)
        }
    }

    /// 枠の内側の余白の帯。上下左右の4つ。
    public static func paddingBands(of rect: CGRect, padding: CGFloat) -> [CGRect] {
        let side = min(padding, rect.width / 2)
        let edge = min(padding, rect.height / 2)
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: edge),
            CGRect(x: rect.minX, y: rect.maxY - edge, width: rect.width, height: edge),
            CGRect(x: rect.minX, y: rect.minY + edge, width: side, height: rect.height - edge * 2),
            CGRect(x: rect.maxX - side, y: rect.minY + edge, width: side, height: rect.height - edge * 2),
        ]
    }

    /// 枠の角の丸みが効く、四隅の正方形。
    public static func cornerSquares(of rect: CGRect, radius: CGFloat) -> [CGRect] {
        let side = min(radius, rect.width / 2, rect.height / 2)
        return [
            CGRect(x: rect.minX, y: rect.minY, width: side, height: side),
            CGRect(x: rect.maxX - side, y: rect.minY, width: side, height: side),
            CGRect(x: rect.minX, y: rect.maxY - side, width: side, height: side),
            CGRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side),
        ]
    }

    /// 並んだ枠のうち、隣り合うもののあいだの帯。サムネイル同士や選択肢同士のすき間を示すのに使う。
    /// 右か下にある枠のうち、いちばん近いものだけを隣とみなす。
    public static func gaps(between frames: [CGRect]) -> [CGRect] {
        var gaps: [CGRect] = []
        for frame in frames {
            let right = frames
                .filter { $0 != frame && $0.minX >= frame.maxX - 0.5 && $0.minY < frame.maxY && $0.maxY > frame.minY }
                .min { $0.minX < $1.minX }
            if let right {
                let minY = max(frame.minY, right.minY)
                let height = min(frame.maxY, right.maxY) - minY
                gaps.append(band(from: frame.maxX, to: right.minX) { CGRect(x: $0, y: minY, width: $1, height: height) })
            }
            let below = frames
                .filter { $0 != frame && $0.minY >= frame.maxY - 0.5 && $0.minX < frame.maxX && $0.maxX > frame.minX }
                .min { $0.minY < $1.minY }
            if let below {
                let minX = max(frame.minX, below.minX)
                let width = min(frame.maxX, below.maxX) - minX
                gaps.append(band(from: frame.maxY, to: below.minY) { CGRect(x: minX, y: $0, width: width, height: $1) })
            }
        }
        return gaps
    }

    /// `start`から`end`までの帯。細すぎるときは、真ん中を中心に`minimumGapThickness`まで広げる。
    private static func band(from start: CGFloat, to end: CGFloat, make: (CGFloat, CGFloat) -> CGRect) -> CGRect {
        let thickness = end - start
        guard thickness < minimumGapThickness else { return make(start, thickness) }
        let center = (start + end) / 2
        return make(center - minimumGapThickness / 2, minimumGapThickness)
    }
}
