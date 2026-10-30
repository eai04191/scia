import SciaCore
import UIKit

/// 読み込みとストリーミングを受け持つ側（`FeedTimelineModel`など）からの命令を受ける。
extension TimelineViewController: TimelineDisplay {
    func prefetchAvatars(of entries: [TimelineEntry]) {
        prefetchAvatars(for: entries)
    }

    func currentAnchorID() -> ItemID? {
        currentAnchor()?.id
    }
}

extension StreamingStatusPullView: StreamingStatusDisplay {}
