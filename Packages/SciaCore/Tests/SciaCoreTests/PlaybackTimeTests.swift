import Testing
@testable import SciaCore

struct PlaybackTimeTests {
    @Test func formatsMinutesAndSeconds() {
        let time = PlaybackTime(elapsed: 6.4, duration: 12)
        #expect(time.elapsedText == "0:06")
        #expect(time.remainingText == "-0:06")
    }

    /// 経過は切り捨て、残りは切り上げ、2つを足すと長さになるようにする。再生し終えたら残りは0。
    @Test func elapsedAndRemainingAddUpToDuration() {
        #expect(PlaybackTime(elapsed: 0, duration: 2).remainingText == "-0:02")
        #expect(PlaybackTime(elapsed: 0.5, duration: 2).elapsedText == "0:00")
        #expect(PlaybackTime(elapsed: 0.5, duration: 2).remainingText == "-0:02")
        #expect(PlaybackTime(elapsed: 2, duration: 2).elapsedText == "0:02")
        #expect(PlaybackTime(elapsed: 2, duration: 2).remainingText == "-0:00")
    }

    /// 1時間を超える動画では、経過も残りも時間の桁を付けてそろえ、再生中に幅が変わらないようにする。
    @Test func usesHoursForLongVideos() {
        let time = PlaybackTime(elapsed: 65, duration: 5025)
        #expect(time.elapsedText == "0:01:05")
        #expect(time.remainingText == "-1:22:40")
    }

    @Test func formatsMinutesOverTen() {
        #expect(PlaybackTime(elapsed: 754, duration: 900).elapsedText == "12:34")
    }

    /// 長さを読み込む前は、NaNや負の値が来ることがある。0として扱う。
    @Test(arguments: [Double.nan, -1, .infinity])
    func treatsUnknownAsZero(_ value: Double) {
        let time = PlaybackTime(elapsed: value, duration: value)
        #expect(time.elapsedText == "0:00")
        #expect(time.remainingText == "-0:00")
        #expect(time.progress == 0)
    }

    @Test func progressIsClampedToRange() {
        #expect(PlaybackTime(elapsed: 3, duration: 12).progress == 0.25)
        #expect(PlaybackTime(elapsed: 13, duration: 12).progress == 1)
    }
}
