import os
import SciaCore
import UIKit
import UniformTypeIdentifiers

/// 画面のどこにドロップした画像や動画でも、投稿欄に添付するための受け口。タブバーの画面全体に付ける。
/// 投稿欄の本文へのドロップは、本文の入力欄が先に受け取り、ペーストと同じく文字は本文に、メディアは添付に振り分ける。
/// アプリの中から始めたドラッグ（添付の並べ替えなど）は受け取らない。添付の列から外へ出したときに、同じものがもう一度添付されるため。
@MainActor
final class MediaDropTarget: NSObject {
    /// ドロップを受け取ったときに、読み込みを始めた項目を渡す。読み終えるのを待つ処理は、受け取った側がセッションの持ち主の子で始める。
    var onDrop: (MediaDrop) -> Void = { _ in }

    private let logger = SciaLog.logger(category: "compose")

    /// ファイルのURLの項目を先に見る。MacのFinderのファイルは、ファイルのURLとFinderのアイコンの画像を一緒に持つため（`LocalMediaLoader.hasFileURL`）。
    private static let acceptedTypes = [UTType.fileURL.identifier] + LocalMediaLoader.mediaTypes.map(\.identifier)
}

/// 1回のドロップで、読み込みを始めた項目。
@MainActor
struct MediaDrop {
    fileprivate let loaded: LoadedMedia
    fileprivate let loads: [Task<Void, any Error>]

    /// 読み終えるのを待ち、画像か動画として読めたものをドロップした順に返す。読めなかった項目（画像か動画でないファイルや、読み込みに失敗したもの）は数だけ返す。
    func result() async -> (media: [PastedMedia], missingCount: Int) {
        for load in loads {
            _ = await load.result
        }
        let media = loaded.media.compactMap(\.self)
        return (media, loaded.media.count - media.count)
    }

    /// 添付せずに捨てる。読んでいる途中のものは、読み終えてから消す。端末の中のコピーで通信しないので、セッションを閉じても止めない。
    func discard() {
        Task(.withoutRequests) {
            for item in await result().media {
                item.discard()
            }
        }
    }
}

/// ドロップした項目ごとの読み込みの結果を、ドロップした順に並べる。
@MainActor
private final class LoadedMedia {
    var media: [PastedMedia?]

    init(count: Int) {
        media = Array(repeating: nil, count: count)
    }
}

extension MediaDropTarget {
    private static func startLoading(from provider: NSItemProvider) async -> PastedMedia? {
        if LocalMediaLoader.hasFileURL(provider) {
            return await LocalMediaLoader.startLoadingPastedFile(from: provider)
        }
        return LocalMediaLoader.droppedMediaType(in: provider).map { LocalMediaLoader.startLoadingPasted(from: provider, type: $0) }
    }
}

extension MediaDropTarget: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.localDragSession == nil && session.hasItemsConforming(toTypeIdentifiers: Self.acceptedTypes)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        // 項目の読み込みは、ドロップを受け取ったこの処理の中で始める。抜けたあとでは読めなくなることがあるため。
        let loaded = LoadedMedia(count: session.items.count)
        let loads = session.items.enumerated().map { index, item in
            let provider = item.itemProvider
            return Task.immediate(.withoutRequests) { @MainActor () -> Void in
                loaded.media[index] = await Self.startLoading(from: provider)
            }
        }
        logger.info("media drop: received (count=\(loads.count))")
        onDrop(MediaDrop(loaded: loaded, loads: loads))
    }
}
