#if DEBUG
import Foundation
import os
import SciaCore

/// `scia-debug://settings/list`と`scia-debug://settings/set`。設定のキー、設定の画面での場所、今の値を、アプリのDocuments/AgentDump/settings.txtに書き出す。
/// `set`では、1行目に書けたかと書けなかった理由を出す。agentはログを読まずに結果を知るため。
@MainActor
enum SettingsDump {
    static func write(settings: AppSettings, account: String) {
        save(list(settings: settings, account: account))
    }

    static func set(key: String, json: String, settings: AppSettings, account: String) {
        let result: String
        do {
            try settings.setDirectly(PresetValue(json: json), forKey: key, account: account)
            result = "set \(key): ok"
        } catch {
            result = "set \(key): failed \(error)"
        }
        save([result] + list(settings: settings, account: account))
    }

    private static func list(settings: AppSettings, account: String) -> [String] {
        settings.directEntries(account: account).map { entry in
            "\(entry.key)\t\(entry.value?.json ?? "default")\t\(entry.place)"
        }
    }

    private static func save(_ lines: [String]) {
        do {
            let directory = URL.documentsDirectory.appending(path: "AgentDump")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: directory.appending(path: "settings.txt"), options: .atomic)
        } catch {
            SciaLog.logger(category: "debug").error("settings dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
