import Foundation
import SciaCore

extension SharedMediaInbox {
    /// アプリと共有拡張が両方読むフォルダー。project.ymlの`SCIA_APP_GROUP`を、Info.plistを通して読む。
    /// App Groupの権限がない署名で入れたときはnil。
    static let app: SharedMediaInbox? = {
        guard let appGroup = Bundle.main.object(forInfoDictionaryKey: "SciaAppGroup") as? String else {
            preconditionFailure("Info.plistにSciaAppGroupがない")
        }
        return SharedMediaInbox(appGroup: appGroup)
    }()
}
