import Foundation

/// ビルド元のブランチとcommit。Tools/embed-build-info.shがビルド時にInfo.plistへ書き込む。
struct BuildInfo {
    let version: String
    let branch: String
    /// 未commitの変更を含むビルドは「-dirty」が付く。
    let commit: String

    static let current = BuildInfo(bundle: .main)

    init(bundle: Bundle) {
        version = bundle.string(forInfoKey: "CFBundleShortVersionString")
        branch = bundle.string(forInfoKey: "SciaGitBranch")
        commit = bundle.string(forInfoKey: "SciaGitCommit")
    }

    /// 例: 0.0.0 (main @ eb4c0e3)
    var text: String {
        "\(version) (\(branch) @ \(commit))"
    }
}

private extension Bundle {
    func string(forInfoKey key: String) -> String {
        // ビルドのスクリプトが必ず書き込むため、ないのはビルド設定の誤り
        guard let value = object(forInfoDictionaryKey: key) as? String else {
            preconditionFailure("Info.plistに\(key)がない")
        }
        return value
    }
}
