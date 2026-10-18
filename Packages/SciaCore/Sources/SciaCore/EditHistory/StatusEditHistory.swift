import Foundation

/// 編集履歴の画面に並べる、版ごとの中身と、1つ前の版からの変更。
public struct StatusEditHistory: Equatable, Sendable {
    /// 新しい版から順に並べる。最後が最初の投稿。
    public let entries: [Entry]

    public struct Entry: Equatable, Sendable {
        public let revision: StatusRevision
        /// 何回目の編集か。最初の投稿は0。
        public let editNumber: Int
        /// 1つ前の版との違いを重ねた本文。最初の投稿では、すべて変わらないものとして並べる。
        public let body: RichTextDiff
        /// 注意書き。この版にも前の版にもなければnil。
        public let spoiler: RichTextDiff?
        /// 本文と注意書きのほかに変わったこと。最初の投稿では空。
        public let changes: [Change]

        public var isOriginal: Bool { editNumber == 0 }
    }

    /// 本文と注意書きのほかに、1つ前の版から変わったこと。並べる順は、閲覧注意、添付ファイル、投票。
    public enum Change: Equatable, Sendable {
        case sensitiveAdded
        case sensitiveRemoved
        case mediaAdded(MediaAttachment)
        /// 前の版にあって、この版で外された添付ファイル。
        case mediaRemoved(MediaAttachment)
        /// 代替テキストが変わった。添付ファイルはこの版のもの。
        case mediaDescriptionChanged(MediaAttachment, RichTextDiff)
        /// 両方の版にある添付ファイルの並び順が変わった。
        case mediaReordered
        /// 投票の選択肢が変わった。投票を付けた、外したときも含む。選択肢を変えるとサーバーは票を数え直す。
        case pollOptions([PollOption])
    }

    public struct PollOption: Equatable, Sendable {
        public let title: String
        public let change: DiffChange

        public init(_ title: String, _ change: DiffChange) {
            self.title = title
            self.change = change
        }
    }

    /// `revisions`はAPIの返す順（古い版から）。`mentions`と`tags`は今の投稿のもので、版ごとには返らないため、すべての版の本文の解釈に使う。
    /// `minimumUnchangedRatio`は`RichTextDiff`の、書き直したとみなす境目。
    public init(revisions: [StatusRevision], mentions: [Mention], tags: [Tag], language: String?, minimumUnchangedRatio: Double) {
        func body(of revision: StatusRevision) -> RichText {
            MastodonHTMLParser(mentions: mentions, tags: tags, emojis: revision.emojis).parse(revision.content)
        }
        func spoiler(of revision: StatusRevision) -> RichText? {
            revision.spoilerText.isEmpty ? nil : .plain(revision.spoilerText, emojis: revision.emojis)
        }
        func diff(_ old: RichText, _ new: RichText) -> RichTextDiff {
            RichTextDiff(old: old, new: new, language: language, minimumUnchangedRatio: minimumUnchangedRatio)
        }
        var entries: [Entry] = []
        for (index, revision) in revisions.enumerated() {
            guard index > 0 else {
                entries.append(Entry(
                    revision: revision,
                    editNumber: 0,
                    body: RichTextDiff(unchanged: body(of: revision)),
                    spoiler: spoiler(of: revision).map(RichTextDiff.init(unchanged:)),
                    changes: []
                ))
                continue
            }
            let previous = revisions[index - 1]
            let spoilerDiff: RichTextDiff? = switch (spoiler(of: previous), spoiler(of: revision)) {
            case (nil, nil): nil
            case (let old, let new): diff(old ?? RichText(blocks: []), new ?? RichText(blocks: []))
            }
            entries.append(Entry(
                revision: revision,
                editNumber: index,
                body: diff(body(of: previous), body(of: revision)),
                spoiler: spoilerDiff,
                changes: Self.changes(from: previous, to: revision, diff: { diff(.plain($0, emojis: []), .plain($1, emojis: [])) })
            ))
        }
        self.entries = entries.reversed()
    }

    private static func changes(from old: StatusRevision, to new: StatusRevision, diff: (String, String) -> RichTextDiff) -> [Change] {
        var changes: [Change] = []
        switch (old.sensitive, new.sensitive) {
        case (false, true): changes.append(.sensitiveAdded)
        case (true, false): changes.append(.sensitiveRemoved)
        default: break
        }
        changes += mediaChanges(from: old.mediaAttachments, to: new.mediaAttachments, diff: diff)
        if old.pollOptions != new.pollOptions {
            let options = SequenceDiff.merged(old.pollOptions ?? [], new.pollOptions ?? [])
            changes.append(.pollOptions(options.map { PollOption($0.0, $0.1) }))
        }
        return changes
    }

    /// 添付ファイルはIDで同じものを見分ける。並びは新しい版の順で、外されたものは最後に並べる。
    private static func mediaChanges(from old: [MediaAttachment], to new: [MediaAttachment], diff: (String, String) -> RichTextDiff) -> [Change] {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))
        var changes: [Change] = []
        for attachment in new {
            guard let previous = oldByID[attachment.id] else {
                changes.append(.mediaAdded(attachment))
                continue
            }
            let oldDescription = previous.description ?? ""
            let newDescription = attachment.description ?? ""
            if oldDescription != newDescription {
                changes.append(.mediaDescriptionChanged(attachment, diff(oldDescription, newDescription)))
            }
        }
        changes += old.filter { !newIDs.contains($0.id) }.map(Change.mediaRemoved)
        let keptOldOrder = old.map(\.id).filter(newIDs.contains)
        let keptNewOrder = new.map(\.id).filter { oldByID[$0] != nil }
        if keptOldOrder != keptNewOrder {
            changes.append(.mediaReordered)
        }
        return changes
    }
}
