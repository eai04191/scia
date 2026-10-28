import Testing
@testable import SciaCore

struct UserHeadingTests {
    @Test("ほかのサーバーのユーザーは、名前とサーバー名に分ける")
    func remote() {
        let heading = UserHeading(acct: "alice@example.social")
        #expect(heading.title == "@alice")
        #expect(heading.subtitle == "example.social")
    }

    @Test("自分のサーバーのユーザーは、サブタイトルなしの1行にする")
    func local() {
        let heading = UserHeading(acct: "alice")
        #expect(heading.title == "@alice")
        #expect(heading.subtitle == nil)
    }
}
