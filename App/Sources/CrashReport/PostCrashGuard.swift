import CoreFoundation
import Foundation
import SciaCore
import os

/// 投稿の行を処理している最中のクラッシュを記録し、次の起動からその投稿を隔離する。決まりはdocs/crash-quarantine.mdにある。
@MainActor
final class PostCrashGuard {
    private let quarantine: PostQuarantine
    private let logger = SciaLog.logger(category: "crash")
    /// 記録している投稿のID。同じ投稿を書き直さないため。
    private var markedID: Status.ID?
    private var observer: CFRunLoopObserver?

    init(defaults: UserDefaults, build: String) {
        quarantine = PostQuarantine(defaults: defaults, build: build)
    }

    /// 前の起動のクラッシュを読み、記録を始める。行を描く前に呼ぶ。
    func start(markFile: URL) {
        // 更新の前のクラッシュは、直っているかもしれない前のビルドのものなので、読むだけで隔離しない。
        if let record = CrashMark.takeRecord(fileAt: markFile), !quarantine.isNewBuild {
            logger.notice("quarantined post after crash id=\(record.itemID, privacy: .public)")
            quarantine.add(accountID: record.accountID, statusID: record.itemID)
        }
        guard CrashMark.install(fileAt: markFile) else {
            logger.error("crash mark could not be installed")
            return
        }
        // レイアウトと描画はCATransactionのコミットで行われ、これはbeforeWaitingの中で走る。そのあとに消す。
        // 処理を終えた行の記録を残すと、あとで起きた関係のないクラッシュをその行のせいにするため。
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.mark(nil) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// 使っているアカウントを切り替える。
    func activate(accountID: String) {
        CrashMark.setAccount(accountID)
    }

    /// 処理している投稿を記録する。投稿の行でなければnilを渡す。
    func mark(_ statusID: Status.ID?) {
        guard statusID != markedID else { return }
        markedID = statusID
        if let statusID {
            CrashMark.setItem(statusID)
        } else {
            CrashMark.clearItem()
        }
    }

    func isQuarantined(_ statusID: Status.ID) -> Bool {
        quarantine.contains(statusID: statusID)
    }

    /// `accountID`について、まだ伝えていない隔離した投稿のIDを返し、伝えたことにする。
    func takeUnnotified(accountID: String) -> [Status.ID] {
        quarantine.takeUnnotified(accountID: accountID)
    }

    #if DEBUG
    /// 隔離する投稿を足す。テストで、クラッシュを起こさずに隔離の状態を作るのに使う。
    func quarantineForTesting(_ statusID: Status.ID) {
        quarantine.add(accountID: "testing", statusID: statusID)
    }
    #endif
}
