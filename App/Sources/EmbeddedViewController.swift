import SwiftUI
import UIKit

/// UIKitで作った画面を、SwiftUIの画面の中の1画面として置く。
struct EmbeddedViewController: UIViewControllerRepresentable {
    let make: @MainActor () -> UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        make()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {}
}
