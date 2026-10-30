import Foundation
import SciaCore

extension AppURL {
    /// いつものビルドは`scia`、撮影用のビルドは`scia-promo`。project.ymlの`SCIA_URL_SCHEME`を、Info.plistを通して読む。
    static let scheme: String = {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "SciaURLScheme") as? String else {
            preconditionFailure("Info.plistにSciaURLSchemeがない")
        }
        return scheme
    }()

    /// このビルドのスキームのURLとして読む。
    init?(_ url: URL) {
        self.init(url, scheme: Self.scheme)
    }
}
