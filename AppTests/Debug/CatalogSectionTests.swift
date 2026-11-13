import Testing
@testable import Scia

/// 部品カタログのリストの、セクション分けと検索。
@Suite(.failureState)
struct CatalogSectionTests {
    /// 足した部品をどのセクションにも入れ忘れると、リストに出なくなる。
    @Test func emptyQueryListsEveryComponentOnce() {
        let listed = CatalogSection.contents(matching: "  ").flatMap(\.components)
        #expect(listed.count == CatalogComponent.allCases.count)
        #expect(Set(listed) == Set(CatalogComponent.allCases))
    }

    @Test func queryMatchesTitleAndURLName() {
        let byTitle = CatalogSection.contents(matching: "アクションバー")
        #expect(byTitle.map(\.section) == [.post])
        #expect(byTitle.flatMap(\.components) == [.postActionBar])

        let byURLName = CatalogSection.contents(matching: "Profile-")
        #expect(byURLName.map(\.section) == [.profile])
        #expect(byURLName.flatMap(\.components) == [.profileHeader, .profileAccent, .profileEdit])
    }

    @Test func queryWithoutMatchLeavesNoSection() {
        #expect(CatalogSection.contents(matching: "該当なしの語").isEmpty)
    }
}
