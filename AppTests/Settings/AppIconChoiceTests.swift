import Testing
import UIKit
@testable import Scia

struct AppIconChoiceTests {
    /// 絵はビルドの手順で描き出すため、描き出しが抜けたり名前がずれたりすると、行に絵が出なくなる。
    @Test(arguments: AppIconChoice.allCases)
    func previewImageIsBundled(choice: AppIconChoice) throws {
        let image = try #require(choice.previewImage)
        #expect(image.size == CGSize(width: 60, height: 60))
    }
}
