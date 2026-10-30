/// 編集履歴の版ごとに、何を見せるかを決める。版の組み合わせ、添付ファイルをぼかす理由、見出し、変更の注記、メディアと投票の文言を、描き方に頼らない値で返す。
/// 文字の書体や色、サムネイルの並べ方は、描く側が決める。
public enum EditHistoryPresentation {
    /// 版ごとの中身。
    public struct Entry: Equatable, Sendable {
        public let revision: StatusRevision
        public let editNumber: Int
        /// 「いまの投稿（2回目の編集）」のような見出し。
        public let title: String
        /// 本文や注意書きの違いでは見えない変更の注記（「閲覧注意を付けた」など）。
        public let notes: [String]
        public let spoiler: RichTextDiff?
        /// 本文。段落がなければnil。
        public let body: RichTextDiff?
        /// この版の添付ファイルをぼかす理由。ぼかさなければnil。
        public let mediaCover: MediaCover?
        public let mediaChanges: [MediaChange]
        /// 投票の選択肢。投票がなければnil。
        public let pollOptions: [PollOptionLine]?
    }

    /// 足した、外した、代替テキストを変えた添付ファイルの行。
    public struct MediaChange: Equatable, Sendable {
        public let attachment: MediaAttachment
        /// 「画像を追加」のような見出し。
        public let title: String
        /// 変えた代替テキストの違い。
        public let detail: RichTextDiff?
        public let isRemoved: Bool
        /// サムネイルをぼかす理由。ぼかさなければnil。
        public let cover: MediaCover?
    }

    /// 投票の選択肢の行。
    public struct PollOptionLine: Equatable, Sendable {
        /// 「・」を頭に付けた選択肢。
        public let text: String
        public let change: DiffChange
        /// 読み上げる文。足した、消した選択肢には、そのことを頭に付ける。
        public let accessibilityText: String
    }

    /// 今の投稿の版から順に並べる。
    /// - Parameters:
    ///   - latestCover: 今の投稿の版の添付ファイルをぼかす理由。一覧と同じく、使う人が開いた・隠した選択に従う。ぼかさなければnil。
    ///   - isHidden: 使う人が一覧で添付ファイルを隠した。過去の版と外した添付ファイルも、閲覧注意がなくてもぼかす。
    ///     開いた選択は今の投稿の版だけに当てる。過去の版には、開いた今の版にない画像があるため。
    ///   - filterTitles: 添付ファイルをぼかすフィルターのうち、一致したものの名前。フィルターは今の内容に一致したものだが、
    ///     ぼかしたいのはこの投稿の添付ファイルなので、版ごとに判定し直さず、過去の版と外した添付ファイルにも当てる。
    ///   - revealedEditNumbers: ぼかしを外した版。
    public static func entries(
        for history: StatusEditHistory,
        latestCover: MediaCover?,
        isHidden: Bool,
        filterTitles: [String],
        revealedEditNumbers: Set<Int>
    ) -> [Entry] {
        history.entries.enumerated().map { index, entry in
            self.entry(
                for: entry,
                previous: history.entries.indices.contains(index + 1) ? history.entries[index + 1].revision : nil,
                isLatest: index == 0,
                latestCover: latestCover,
                isHidden: isHidden,
                filterTitles: filterTitles,
                isRevealed: revealedEditNumbers.contains(entry.editNumber)
            )
        }
    }

    /// - Parameters:
    ///   - previous: 1つ前の版。最初の投稿ではnil。
    ///   - latestCover: 今の投稿の版の添付ファイルをぼかす理由。過去の版では使わない。
    ///   - isRevealed: この版でぼかしを外した。過去の版の添付ファイルと、この版で外した添付ファイルのぼかしに使う。
    private static func entry(
        for entry: StatusEditHistory.Entry,
        previous: StatusRevision?,
        isLatest: Bool,
        latestCover: MediaCover?,
        isHidden: Bool,
        filterTitles: [String],
        isRevealed: Bool
    ) -> Entry {
        let revision = entry.revision
        // 過去の版は、閲覧注意か注意書きがあるか、使う人が隠したか、フィルターに一致していれば、タップするまで添付ファイルをぼかす。
        // 理由は一覧と同じく、フィルター、閲覧注意、隠した、の順に出す。
        func cover(of revision: StatusRevision?) -> MediaCover? {
            guard let revision, !isRevealed else { return nil }
            let isSensitive = revision.sensitive || !revision.spoilerText.isEmpty
            if !filterTitles.isEmpty { return .filtered(filterTitles) }
            guard isSensitive || isHidden else { return nil }
            return isSensitive ? .sensitive : .hidden
        }
        let revisionCover = isLatest ? latestCover : cover(of: revision)
        let title = entry.isOriginal ? "最初の投稿" : "\(entry.editNumber)回目の編集"
        return Entry(
            revision: revision,
            editNumber: entry.editNumber,
            title: isLatest ? "いまの投稿（\(title)）" : title,
            notes: (changesFirstBlockLayout(entry.body) ? ["段落の形を変えた"] : []) + entry.changes.compactMap { note(for: $0, in: revision) },
            spoiler: entry.spoiler,
            body: entry.body.blocks.isEmpty ? nil : entry.body,
            mediaCover: revisionCover,
            mediaChanges: entry.changes.compactMap { change in
                // 外した添付ファイルは、外す前の版にあったものなので、その版の閲覧注意でぼかす。
                // この版で閲覧注意を外していても、外す前にぼかしていた画像を、開いただけで見せない。
                let thumbnailCover = if case .mediaRemoved = change { cover(of: previous) } else { revisionCover }
                return mediaChange(for: change, cover: thumbnailCover)
            },
            pollOptions: pollOptions(of: entry)
        )
    }

    /// 先頭の段落の形（引用かどうかなど）だけを変えた。2つ目からの段落は、区切りに足した改行の記号で示せるが、先頭には記号を置く場所がないため、文字で知らせる。
    private static func changesFirstBlockLayout(_ body: RichTextDiff) -> Bool {
        guard let first = body.blocks.first else { return false }
        return first.breakChange == .inserted && first.pieces.first?.change != .inserted
    }

    private static func note(for change: StatusEditHistory.Change, in revision: StatusRevision) -> String? {
        switch change {
        case .sensitiveAdded: "閲覧注意を付けた"
        case .sensitiveRemoved: "閲覧注意を外した"
        case .mediaReordered:
            revision.mediaAttachments.allSatisfy { $0.type == .image } ? "画像の並びを変えた" : "メディアの並びを変えた"
        case .mediaAdded, .mediaRemoved, .mediaDescriptionChanged, .pollOptions: nil
        }
    }

    private static func mediaChange(for change: StatusEditHistory.Change, cover: MediaCover?) -> MediaChange? {
        switch change {
        case .mediaAdded(let attachment):
            MediaChange(attachment: attachment, title: "\(attachment.type.displayName)を追加", detail: nil, isRemoved: false, cover: cover)
        case .mediaRemoved(let attachment):
            MediaChange(attachment: attachment, title: "\(attachment.type.displayName)を削除", detail: nil, isRemoved: true, cover: cover)
        case .mediaDescriptionChanged(let attachment, let description):
            MediaChange(attachment: attachment, title: "代替テキストを変更", detail: description, isRemoved: false, cover: cover)
        case .sensitiveAdded, .sensitiveRemoved, .mediaReordered, .pollOptions:
            nil
        }
    }

    /// 選択肢が変わった版では違いを重ね、変わっていない版ではこの版の選択肢をそのまま並べる。
    private static func pollOptions(of entry: StatusEditHistory.Entry) -> [PollOptionLine]? {
        let options: [StatusEditHistory.PollOption]? = entry.changes.lazy.compactMap { change in
            if case .pollOptions(let options) = change { options } else { nil }
        }.first ?? entry.revision.pollOptions?.map { StatusEditHistory.PollOption($0, .unchanged) }
        guard let options, !options.isEmpty else { return nil }
        return options.map { option in
            let accessibilityText = switch option.change {
            case .unchanged: option.title
            case .inserted: "追加：\(option.title)"
            case .removed: "削除：\(option.title)"
            }
            return PollOptionLine(text: "・\(option.title)", change: option.change, accessibilityText: accessibilityText)
        }
    }
}

extension MediaAttachment.Kind {
    /// 使う人に見せる種類の名前。「画像」「動画」など。
    public var displayName: String {
        switch self {
        case .image: "画像"
        case .gifv: "GIF"
        case .video: "動画"
        case .audio: "音声"
        case .unknown: "ファイル"
        }
    }
}
