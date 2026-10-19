import Testing
@testable import SciaCore

struct MediaDynamicRangeTests {
    /// HDRの札は、開くと一覧より明るくなるときだけ出す。
    @Test(arguments: [
        (MediaDynamicRange.standard, MediaDynamicRange.constrainedHigh, true),
        (.standard, .high, true),
        (.constrainedHigh, .high, true),
        (.standard, .standard, false),
        (.constrainedHigh, .constrainedHigh, false),
        (.high, .high, false),
        (.high, .standard, false),
        (.constrainedHigh, .standard, false),
    ])
    func marksHDRWhenViewerIsBrighter(list: MediaDynamicRange, viewer: MediaDynamicRange, marks: Bool) {
        #expect(MediaDynamicRange.marksHDR(list: list, viewer: viewer) == marks)
    }
}
