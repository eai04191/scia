import SciaCore
import SwiftUI
import UIKit

@MainActor
enum DiscomfortReportPresenter {
    /// 状態ダンプはシートを出す前、違和感を覚えた瞬間の状態を書き出す。
    static func present(in window: UIWindow) {
        guard var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        guard !(top is DiscomfortReportHostingController) else { return }

        let draft = DiscomfortReportDraft(
            capturedAt: Date(),
            logMarker: RecentLogReader.writeMarker(),
            stateDumps: AppDependencies.stateDumps.dumpAll()
        )
        let controller = DiscomfortReportHostingController(draft: draft)
        top.present(controller, animated: true)
    }
}

private final class DiscomfortReportHostingController: UIHostingController<DiscomfortReportView> {
    init(draft: DiscomfortReportDraft) {
        super.init(rootView: DiscomfortReportView(draft: draft, store: AppDependencies.discomfortReports))
        isModalInPresentation = true
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
