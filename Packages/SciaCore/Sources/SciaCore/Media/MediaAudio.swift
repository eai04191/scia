import Foundation

/// メディアを再生している間の、アプリの音声セッションの扱い。
public enum MediaAudioMode: Equatable, Sendable {
    /// 消音モードに従い、ほかのアプリの音と混ぜる。
    case ambient
    /// 消音モードがオンでも鳴らし、ほかのアプリの音を止める。
    case playback

    /// 音声のトラックがあり、消音していないときだけ鳴らす。音のないGIFや消音した動画で、ほかのアプリの音楽を止めないため。
    /// トラックを読み込む前は`hasAudio`がfalseなので、読み込むまでは混ぜて再生する。
    public static func forPlayer(hasAudio: Bool, isMuted: Bool) -> MediaAudioMode {
        hasAudio && !isMuted ? .playback : .ambient
    }
}

/// メディアを表示しているページごとの希望をまとめ、音声セッションをどうするかを決める。
/// ビューアでページを送ると、前のページが消えるより先に次のページが希望を出すことがあるため、ページごとに持つ。
public struct MediaAudioDemands<Owner: Hashable> {
    private var modes: [Owner: MediaAudioMode] = [:]

    public init() {}

    /// 1つでも鳴らすページがあれば鳴らす。希望がなくなったらnilで、セッションを止める。
    public var mode: MediaAudioMode? {
        if modes.values.contains(.playback) { return .playback }
        return modes.isEmpty ? nil : .ambient
    }

    /// ページの希望を替える。nilで取り下げる。
    public mutating func set(_ mode: MediaAudioMode?, for owner: Owner) {
        modes[owner] = mode
    }
}
