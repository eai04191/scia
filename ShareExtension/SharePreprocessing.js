// Safariの共有ボタンでSciaを選んだとき、共有する前にページの中で動き、ページのタイトルとURLと選んでいる文を共有拡張に渡す。
// 共有拡張のInfo.plistのNSExtensionJavaScriptPreprocessingFileで指す。Safariは、ExtensionPreprocessingJSという名前のオブジェクトのrunを呼ぶ。
// @ts-check
var ExtensionPreprocessingJS = {
    /** @param {{ completionFunction: (results: { title: string, url: string, selection: string }) => void }} args */
    run: function (args) {
        args.completionFunction({ title: document.title, url: document.URL, selection: String(window.getSelection() ?? "") });
    },
};
