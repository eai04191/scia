import SciaCore
import Testing
@testable import Scia

@MainActor
struct StorageViewTests {
    /// 違和感レポートは、残っていないときは内訳にも消すボタンにも出さない。
    @Test func hidesEmptyDiscomfortReports() {
        #expect(!StorageView.isShown(.discomfortReports, bytes: 0))
        #expect(StorageView.isShown(.discomfortReports, bytes: 1))
        #expect(StorageView.isShown(.discomfortReports, bytes: nil))
    }

    /// ほかの項目は、空でも出す。
    @Test func showsOtherEmptyCategories() {
        #expect(StorageView.isShown(.networkCache, bytes: 0))
    }
}
