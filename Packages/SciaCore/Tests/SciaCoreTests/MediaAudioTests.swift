import Testing
@testable import SciaCore

struct MediaAudioTests {
    @Test func 音声のトラックがあって消音していないときだけ鳴らす() {
        #expect(MediaAudioMode.forPlayer(hasAudio: true, isMuted: false) == .playback)
        #expect(MediaAudioMode.forPlayer(hasAudio: true, isMuted: true) == .ambient)
        #expect(MediaAudioMode.forPlayer(hasAudio: false, isMuted: false) == .ambient)
    }

    @Test func 希望がなければセッションを止める() {
        let demands = MediaAudioDemands<Int>()
        #expect(demands.mode == nil)
    }

    @Test func 次のページが先に希望を出しても前のページの取り下げで止めない() {
        var demands = MediaAudioDemands<Int>()
        demands.set(.playback, for: 1)
        demands.set(.ambient, for: 2)
        #expect(demands.mode == .playback)
        demands.set(nil, for: 1)
        #expect(demands.mode == .ambient)
        demands.set(nil, for: 2)
        #expect(demands.mode == nil)
    }
}
