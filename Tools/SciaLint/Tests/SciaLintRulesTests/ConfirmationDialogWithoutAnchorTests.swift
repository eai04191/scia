@testable import SciaLintRules
import Testing

@Suite struct ConfirmationDialogWithoutAnchorTests {
    private func violations(_ source: String, path: String = "App/Sources/Foo.swift") -> Int {
        Linter.lint(source: source, path: path, rules: [.confirmationDialogWithoutAnchor]).count
    }

    @Test(arguments: [
        """
        Form {
            Button("Reset") { confirms = true }
        }
        .navigationTitle("Title")
        .confirmationDialog("Reset?", isPresented: $confirms) {}
        """,
        "content.confirmationDialog(\"Reset?\", isPresented: $confirms) {}",
        "List { row }.confirmationDialog(\"Reset?\", isPresented: $confirms) {}",
        "SwiftUI.Form { row }.confirmationDialog(\"Reset?\", isPresented: $confirms) {}",
    ])
    func flagsDialogOnContainers(_ source: String) {
        #expect(violations(source) == 1)
    }

    @Test(arguments: [
        """
        Button("Reset", role: .destructive) { confirms = true }
            .disabled(!modified)
            .confirmationDialog("Reset?", isPresented: $confirms) {}
        """,
        """
        Button {
            confirms = true
        } label: {
            Text("Remove")
        }
        .confirmationDialog("Remove?", isPresented: $confirms) {}
        """,
        """
        Picker("Policy", selection: $value) {
            ForEach(choices, id: \\.self) { Text($0.title).tag($0) }
        }
        .confirmationDialog("Drop?", isPresented: $confirms) {}
        """,
        "Menu(\"More\") {}.confirmationDialog(\"Delete?\", isPresented: $confirms) {}",
        "Toggle(\"On\", isOn: $isOn).confirmationDialog(\"Off?\", isPresented: $confirms) {}",
        "SwiftUI.Button(\"Reset\") { confirms = true }.confirmationDialog(\"Reset?\", isPresented: $confirms) {}",
        "Form { row }.alert(\"Delete?\", isPresented: $confirms) {}",
    ])
    func allowsDialogOnControls(_ source: String) {
        #expect(violations(source) == 0)
    }

    @Test func checksOnlyApp() {
        #expect(violations("content.confirmationDialog(\"Reset?\", isPresented: $confirms) {}", path: "Packages/SciaCore/Sources/Foo.swift") == 0)
    }
}
