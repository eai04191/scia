import Foundation

/// 添付ファイルの代替テキストのうち、説明として読む意味のあるものを選ぶ。
public enum AltTextFilter {
    /// 説明として意味のある代替テキスト。なければnil。
    /// 空白だけのものは、設定にかかわらず常に除く。`ignoresUseless`なら、投稿するアプリが自動で付ける決まった文字列も除く。
    /// 前後の空白を除いて完全に一致するものだけを対象にし、説明の一部に含むもの（「Screenshot of ...」など）は残す。
    /// 返す文字列は、届いたものから手を加えない。
    public static func meaningful(_ description: String?, ignoresUseless: Bool) -> String? {
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if ignoresUseless && isUseless(trimmed) { return nil }
        return description
    }

    /// 投稿するアプリが自動で付ける、説明にならない文字列。
    /// undefinedは、JavaScriptで未設定の値を文字列にしたものなので、大文字・小文字を区別する。
    /// Screenshotは、書き方の揺れがあっても説明にならないため、区別しない。
    private static func isUseless(_ trimmed: String) -> Bool {
        trimmed == "undefined" || trimmed.caseInsensitiveCompare("Screenshot") == .orderedSame
    }
}

extension MediaAttachment {
    /// 説明として意味のない代替テキストを除いた添付ファイル。
    public func filteringAltText(ignoresUseless: Bool) -> MediaAttachment {
        let filtered = AltTextFilter.meaningful(description, ignoresUseless: ignoresUseless)
        guard filtered != description else { return self }
        return MediaAttachment(
            id: id,
            type: type,
            url: url,
            previewUrl: previewUrl,
            remoteUrl: remoteUrl,
            description: filtered,
            meta: meta,
            blurhash: blurhash
        )
    }
}
