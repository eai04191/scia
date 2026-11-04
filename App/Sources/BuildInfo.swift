import Foundation

/// バージョン、ビルド番号、ビルド元のブランチとcommit、ビルドした日時。ブランチ、commit、日時は、Tools/embed-build-info.shがビルド時にInfo.plistへ書き込む。
struct BuildInfo {
    let version: String
    /// App Store Connectに出るビルド番号。`make archive`ではアーカイブしたUTCの日時、ほかのビルドではproject.ymlの値になる。
    let build: String
    let branch: String
    /// 未commitの変更を含むビルドは「-dirty」が付く。
    let commit: String
    let builtAt: Date

    static let current = BuildInfo(bundle: .main)

    init(bundle: Bundle) {
        version = bundle.string(forInfoKey: "CFBundleShortVersionString")
        build = bundle.string(forInfoKey: "CFBundleVersion")
        branch = bundle.string(forInfoKey: "SciaGitBranch")
        commit = bundle.string(forInfoKey: "SciaGitCommit")
        let builtAt = bundle.string(forInfoKey: "SciaBuildDate")
        // ビルドのスクリプトがISO 8601で書くため、読めないのはスクリプトの誤り
        guard let date = try? Date(builtAt, strategy: .iso8601) else {
            preconditionFailure("SciaBuildDateを読めない: \(builtAt)")
        }
        self.builtAt = date
    }

    /// 例: 0.0.0 (20261102.120000, main @ eb4c0e3, 2026-11-02T12:00:00Z)
    var text: String {
        "\(version) (\(build), \(branch) @ \(commit), \(builtAt.formatted(.iso8601)))"
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
