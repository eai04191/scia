import Observation
import os
import SciaCore
import UIKit

/// 相手のプロフィールに書く、自分にしか見えないメモのシート。決まりはdocs/profile.mdの「メモ」にある。
/// サーバーはメモを整形しないので、補完と絵文字のシートは付けない。
final class AccountNoteViewController: UIViewController {
    /// 保存できたら、シートを閉じる前に呼ぶ。
    var onSaved: (Relationship) -> Void = { _ in }
    /// 保存に失敗したら、アラートの見出しと一緒に呼ぶ。書いたものはそのまま残る。
    var onError: (any Error, String) -> Void = { _, _ in }

    let editor: AccountNoteEditor
    private let acct: String
    /// 保存の持ち主。セッションの持ち主の子で、ログアウトやアカウントの切り替えで止まり、前のアカウントのトークンで送り続けない。
    private let tasks: TaskScope
    private let settings: AppSettings
    private let logger = SciaLog.logger(category: "profile")

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let textView = ProfileEditTextView()
    private lazy var inputCell = ProfileEditInputCell(input: textView)
    /// 書いた文字数。上限は手元で決めないので、分母を付けず、赤くもしない。
    private let footer = ProfileEditFooter()
    private var isConfirmingDiscard = false

    init(editor: AccountNoteEditor, acct: String, tasks: TaskScope, settings: AppSettings = AppDependencies.settings) {
        self.editor = editor
        self.acct = acct
        self.tasks = tasks
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// ナビゲーションの中に入れてシートで出す画面を作る。
    func wrappedInNavigation() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.presentationController?.delegate = self
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = "メモ"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        let save = UIBarButtonItem(title: "保存", style: .prominent, target: nil, action: nil)
        save.primaryAction = UIAction(title: "保存") { [weak self] _ in self?.save() }
        navigationItem.rightBarButtonItem = save

        textView.text = editor.text
        textView.placeholder = "メモを追加"
        textView.accessibilityLabel = "メモ"
        textView.followGlyphLanguage(of: settings)
        textView.delegate = self
        textView.updatePlaceholder()

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .interactive
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        observeEditor()
        AppDependencies.stateDumps.register("accountNote", owner: self) { $0.stateDump() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    func stateDump() -> String {
        "saving: \(editor.isSaving) hasChanges: \(editor.hasChanges) canSave: \(editor.canSave) length: \(editor.length)"
    }

    private func observeEditor() {
        withObservationTracking {
            applyEditorState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeEditor() }
        }
    }

    private func applyEditorState() {
        let saving = editor.isSaving
        navigationItem.rightBarButtonItem?.isEnabled = editor.canSave
        navigationItem.leftBarButtonItem?.isEnabled = !saving
        textView.isEditable = !saving
        // 保存している間は、ボタンの場所にインジケーターを出す。
        if saving, !(navigationItem.rightBarButtonItem?.customView is UIActivityIndicatorView) {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            navigationItem.rightBarButtonItem?.customView = indicator
        } else if !saving {
            navigationItem.rightBarButtonItem?.customView = nil
        }
        isModalInPresentation = editor.hasChanges || saving
        footer.setText("\(editor.length)文字", isProblem: false)
    }

    // MARK: - 保存と取りやめ

    private func save() {
        guard editor.canSave else { return }
        tasks.run(key: "save", .skippingWhileRunning) { [weak self] in
            guard let self else { return }
            do {
                let saved = try await editor.save()
                logger.info("account note saved (empty: \(saved.note.isEmpty, privacy: .public))")
                onSaved(saved)
                dismiss(animated: true)
            } catch where HTTPFailure(error) == nil {
                // ログアウトやアカウントの切り替えで止めた。通信の途中なら`URLError(.cancelled)`で届く。シートもセッションと一緒に閉じるので、知らせない。
            } catch {
                logger.error("account note save failed: \(SciaLog.describe(error), privacy: .public)")
                onError(error, "メモを保存できませんでした")
            }
        }
    }

    private func cancel() {
        guard editor.hasChanges else {
            dismiss(animated: true)
            return
        }
        confirmDiscard()
    }

    /// 変えたものがあれば、捨ててよいか確かめる。
    private func confirmDiscard() {
        guard !isConfirmingDiscard, !editor.isSaving else { return }
        isConfirmingDiscard = true
        view.endEditing(true)
        let sheet = UIAlertController(title: nil, message: "変更を保存していません", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "変更を破棄", style: .destructive) { [weak self] _ in
            self?.isConfirmingDiscard = false
            self?.dismiss(animated: true)
        })
        sheet.addAction(UIAlertAction(title: "編集を続ける", style: .cancel) { [weak self] _ in
            self?.isConfirmingDiscard = false
        })
        sheet.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(sheet, animated: true)
    }
}

extension AccountNoteViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        inputCell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "@\(acct)についての、自分にしか見えないメモ"
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        footer
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        false
    }
}

extension AccountNoteViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        editor.text = textView.text
        self.textView.updatePlaceholder()
        // 行が増えたら、表の行の高さを測り直す。
        UIView.performWithoutAnimation {
            tableView.performBatchUpdates(nil)
        }
    }
}

extension AccountNoteViewController: UIAdaptivePresentationControllerDelegate {
    /// 変えたものがあるのに下へスワイプして閉じようとしたら、捨ててよいか確かめる。
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        confirmDiscard()
    }
}
