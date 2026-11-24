import AVFoundation
import os
import SciaCore

/// メディアを再生するページの希望をまとめて、アプリの音声セッションに入れる。音声セッションはアプリに1つなので、これもアプリに1つ持つ。
@MainActor
final class MediaAudioSession {
    static let shared = MediaAudioSession()

    private let logger = SciaLog.logger(category: "MediaAudio")
    private var demands = MediaAudioDemands<ObjectIdentifier>()
    /// 最後に入れ終えた状態。`.some(nil)`は止めている。入れる途中で失敗したら、OSの状態が分からないので`nil`にし、次の希望で入れ直す。
    private var applied: MediaAudioMode?? = .some(nil)

    /// ページの希望を替える。nilで取り下げる。
    func set(_ mode: MediaAudioMode?, for owner: AnyObject) {
        demands.set(mode, for: ObjectIdentifier(owner))
        apply(demands.mode)
    }

    private func apply(_ mode: MediaAudioMode?) {
        guard applied != .some(mode) else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            switch mode {
            case .playback:
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            case .ambient:
                try session.setCategory(.ambient)
                try session.setActive(true)
            case nil:
                // 止めていたほかのアプリの音楽などを、再開できるようにする。
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            applied = .some(mode)
            logger.info("audio session: \(Self.name(of: mode), privacy: .public)")
        } catch {
            applied = nil
            logger.error("audio session failed: \(Self.name(of: mode), privacy: .public) \(SciaLog.describe(error), privacy: .public)")
        }
    }

    private static func name(of mode: MediaAudioMode?) -> String {
        mode.map { "\($0)" } ?? "inactive"
    }
}
