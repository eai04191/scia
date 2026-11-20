import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.scratch, .failureState)
struct UserAvatarGeneratorTests {
    @Test(arguments: UserAvatarSymbol.allCases)
    func producesOpaqueSquareWithWhiteSymbol(_ symbol: UserAvatarSymbol) throws {
        let image = try UserAvatarGenerator.image(symbol: symbol, color: .gray)
        let data = try #require(image.pngData())
        let decoded = try #require(UIImage(data: data)?.cgImage)
        #expect(decoded.width == 512)
        #expect(decoded.height == 512)
        var pixels = [UInt8](repeating: 0, count: decoded.width * decoded.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: decoded.width, height: decoded.height, bitsPerComponent: 8, bytesPerRow: decoded.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        }
        #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
        let whiteCount = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 250 && pixels[$0 + 1] > 250 && pixels[$0 + 2] > 250 }.count
        #expect(whiteCount > 1000, "白いシンボルが描かれていること: \(symbol)")
    }

    @Test func generatedBackgroundHasNoRim() throws {
        let image = try #require(UserAvatarGenerator.image(symbol: .person, color: .gray).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let pairs = [(0, 256, 32, 256), (511, 256, 479, 256), (32, 0, 32, 16), (32, 511, 32, 495)]
        for (edgeX, edgeY, innerX, innerY) in pairs {
            for channel in 0..<3 {
                let edge = Int(pixels[(edgeY * image.width + edgeX) * 4 + channel])
                let inner = Int(pixels[(innerY * image.width + innerX) * 4 + channel])
                #expect(abs(edge - inner) <= 3, "端と内側の背景色: (\(edgeX), \(edgeY)) = \(edge), (\(innerX), \(innerY)) = \(inner)")
            }
        }
    }

    @Test func keepsTheSettingsIconsBackgroundShading() throws {
        let image = try #require(UserAvatarGenerator.image(symbol: .person, color: .gray).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let upper = pixels[(64 * image.width + 32) * 4]
        let lower = pixels[(448 * image.width + 32) * 4]
        #expect(abs(Int(upper) - Int(lower)) > 5, "設定アイコンと同じ背景の明暗差があること: \(upper), \(lower)")
    }

    @Test(arguments: AccentColorChoice.allCases.filter { $0 != .monochrome })
    func livePreviewKeepsTheSavedColorWhenContrastChanges(_ color: AccentColorChoice) {
        let content = UserAvatarContent(symbol: .person, color: color)
        let highContrast = UITraitCollection { $0.userInterfaceStyle = .dark; $0.accessibilityContrast = .high }
        #expect(content.backgroundColor.resolvedColor(with: highContrast) == color.uiColor.resolvedColor(with: UserAvatarGenerator.colorTraits))
    }

    @Test func generatedImageSurvivesSavingAndReloading() throws {
        let defaults = TestScratch.defaults("generated-avatar")
        let directory = TestScratch.url("generated-avatar")
        let settings = AppSettings(store: SettingsStore(defaults: defaults, userDisplayImageDirectory: directory), target: .scope(.app))
        let account = Account(id: "1", username: "person", acct: "person@example.com", displayName: "Person", avatar: nil)
        let data = try #require(UserAvatarGenerator.image(symbol: .cat, color: .blue).pngData())
        let other = try #require(UserAvatarGenerator.image(symbol: .cat, color: .orange).pngData())
        #expect(data != other)
        try settings.userDisplays.save(.init(), for: account, in: settings, imageData: data)
        let reloaded = AppSettings(store: SettingsStore(defaults: defaults, userDisplayImageDirectory: directory), target: .scope(.app))
        let url = try #require(reloaded.userDisplays.display(of: account, in: reloaded).avatarStatic)
        #expect(try Data(contentsOf: url) == data)
        #expect(UIImage(contentsOfFile: url.path)?.size == CGSize(width: 512, height: 512))
    }

    @Test func openingSymbolChoicesKeepsTheExistingPreviewCell() throws {
        let account = Account(id: "1", username: "person", acct: "person@example.com", displayName: "Person", avatar: nil)
        let tasks = TaskScope()
        defer { tasks.close() }
        let controller = UserDisplayViewController(account: account, settings: .isolated(), tasks: tasks)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        let table = try #require(controller.tableView)
        let index = IndexPath(row: 0, section: 2)
        table.scrollToRow(at: index, at: .top, animated: false)
        table.layoutIfNeeded()
        let preview = try #require(table.cellForRow(at: index))
        UIView.performWithoutAnimation {
            controller.tableView(table, didSelectRowAt: IndexPath(row: 2, section: 2))
            table.layoutIfNeeded()
        }
        #expect(table.cellForRow(at: index) === preview)
        let choicesIndex = IndexPath(row: 3, section: 2)
        let choices = try #require(table.cellForRow(at: choicesIndex))
        for symbol in UserAvatarSymbol.allCases { controller.symbolSelection.symbol = symbol }
        controller.symbolSelection.symbol = .cat
        controller.symbolSelection.color = .green
        #expect(table.cellForRow(at: index) === preview)
        #expect(table.cellForRow(at: choicesIndex) === choices)
        #expect(controller.stateDump().contains("rasterizedImage: false"))
        let savedData = try controller.imageDataForSaving()
        let data = try #require(savedData)
        let expected = try #require(UserAvatarGenerator.image(symbol: .cat, color: .green).pngData())
        #expect(data == expected)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 5, section: 2))
        #expect(choices.isHidden || choices.superview == nil, "削除中の選択肢が後続の行に重ならないこと")
        #expect(table.cellForRow(at: index) === preview)
    }

    @Test func choosingAndResettingSymbolOnlyChangesTheDraft() throws {
        let settings = AppSettings.isolated()
        let account = Account(id: "1", username: "person", acct: "person@example.com", displayName: "Person", avatar: nil)
        let tasks = TaskScope()
        defer { tasks.close() }
        let controller = UserDisplayViewController(account: account, settings: settings, tasks: tasks)
        controller.loadViewIfNeeded()
        let table = try #require(controller.tableView)
        table.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        table.layoutIfNeeded()
        #expect(controller.tableView(table, numberOfRowsInSection: 2) == 3)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 2, section: 2))
        #expect(controller.tableView(table, numberOfRowsInSection: 2) == 6)
        #expect(controller.stateDump().contains("hasImage: true"))
        #expect(settings.userDisplays.display(of: account, in: settings).rule.isEmpty)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 5, section: 2))
        #expect(controller.tableView(table, numberOfRowsInSection: 2) == 3)
        #expect(controller.stateDump().contains("hasImage: false"))
        #expect(settings.userDisplays.display(of: account, in: settings).rule.isEmpty)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 2, section: 2))
        #expect(controller.tableView(table, numberOfRowsInSection: 2) == 6)
    }
}
