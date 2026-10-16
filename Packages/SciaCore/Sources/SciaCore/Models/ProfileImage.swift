import Foundation

/// プロフィールに出す画像。タップすると、添付ファイルと同じビューアで大きく見られる。
public enum ProfileImage: String, Hashable, Sendable, CaseIterable {
    case avatar
    case header
}

extension Account {
    /// 画像を、ビューアで開く添付ファイルとして表す。元の画像とアニメーションしない版のどちらのURLもなければnil。
    /// 元の画像はアニメーションするGIFのことがあるため、共有と保存ではそのまま渡し、一覧で読み込んだ静止画を届くまでの下地にする。
    /// IDは添付ファイルのIDと混ざらないよう、アカウントと画像の種類から作る。
    public func attachment(of image: ProfileImage) -> MediaAttachment? {
        let (original, still) = switch image {
        case .avatar: (avatar, avatarStatic)
        case .header: (header, headerStatic)
        }
        guard let url = original ?? still else { return nil }
        return MediaAttachment(id: "account:\(id):\(image.rawValue)", type: .image, url: url, previewUrl: still ?? url)
    }
}
