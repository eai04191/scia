#if DEBUG
import Foundation
import os
import SciaCore
import UIKit

extension SessionController {
    /// 確かめるための処理中のチップを、進み具合を少しずつ進めながら`duration`のあいだ出し、済んだら消す。出している途中に呼び直したら、初めから数え直す。
    private func showDebugProgress(for duration: Duration, title: String) {
        debugProgressTask?.cancel()
        let elapsed = stopwatch(on: clock)
        let clock = clock
        // 出し直すたびに別のアプリ内通知にする。しまったあとに出し直しても、出てくるようにするため。
        let id = "debug.progress.\(UUID().uuidString)"
        debugProgressTask = tasks.run(.action) { [weak self] in
            while !Task.isCancelled {
                let fraction = min(elapsed() / duration, 1)
                self?.notices.setPersistent({ _ in
                    Notice(id: id, kind: .progress, title: title, value: Notice.percentText(of: fraction), valueIsProgress: true)
                }, in: .debug)
                guard fraction < 1 else { break }
                try? await clock.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return }
            self?.notices.setPersistent(nil, in: .debug)
        }
    }

    private func replyForDebug(to file: String) {
        let url = URL.documentsDirectory.appending(path: "DebugInject").appending(fileName: SafeFileName(file))
        do {
            guard let status = try MastodonDecoder.make().decode([Status].self, from: Data(contentsOf: url)).first else { return }
            composer.reply(to: status)
        } catch {
            // デバッグ版だけで読むファイルなので、`inject`と同じく失敗を丸ごと残す。
            // scialint:disable:next log_private_value
            logger.error("debug reply failed file=\(file, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Documents/DebugInjectの`file`をAPIの応答と同じ形のJSONとして読み、`tab`のタイムラインに新着として流す。読めなければ流さずにログに残す。
    private func inject(_ file: String, into tab: DebugURL.Tab) {
        let url = URL.documentsDirectory.appending(path: "DebugInject").appending(fileName: SafeFileName(file))
        do {
            let data = try Data(contentsOf: url)
            let decoder = MastodonDecoder.make()
            switch tab {
            case .home: home.inject(try decoder.decode([Status].self, from: data))
            case .local: local.inject(try decoder.decode([Status].self, from: data))
            case .federated: federated.inject(try decoder.decode([Status].self, from: data))
            case .notifications: notifications.inject(try decoder.decode([MastodonNotification].self, from: data))
            case .announcements:
                for announcement in try decoder.decode([Announcement].self, from: data) {
                    announcements.apply(.announcement(announcement))
                }
            case .bookmarks, .favourites, .scheduled:
                // ストリームのないタイムラインなので、新着と同じ経路がない。
                logger.error("debug inject unsupported tab=\(tab.rawValue, privacy: .public)")
            }
        } catch {
            // デバッグ版だけで流すファイルで、どこが読めなかったかを直すため、ログの決まり（docs/logging.md）から外して失敗を丸ごと残す。
            // scialint:disable:next log_private_value
            logger.error("debug inject failed file=\(file, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func handle(_ url: DebugURL) {
        // `scia-debug://reset`の直後に送ったURLは、画面を閉じ終えてから行う。
        rootViewController.afterOngoingDismissal { [weak self] in self?.handleAfterDismissal(url) }
    }

    private func handleAfterDismissal(_ url: DebugURL) {
        switch url {
        case .dummy(let post):
            home.streamDummy(post)
        case .dummySession, .account, .hitAreas:
            // SceneDelegateが、セッションの有無にかかわらず先に受けるため、ここには来ない。
            break
        case .scenario(let event):
            if let action = ScenarioMode.server?.script.actions[event] {
                handle(action)
            } else {
                ScenarioMode.handle(event)
            }
        case .unauthorized:
            DebugFaults.rejectAsUnauthorized()
            reportUnauthorized()
        case .unreadable:
            DebugFaults.corruptListElements()
            feeds.forEach { $0.reloadIfStarted() }
            savedLists.forEach { $0.reloadIfStarted() }
            notifications.start(purpose: .action)
        case .status(let statusCode, let retryAfter, let target):
            DebugFaults.fail(withStatus: statusCode, retryAfter: retryAfter, target: target)
            feeds.forEach { $0.reloadIfStarted() }
            savedLists.forEach { $0.reloadIfStarted() }
            notifications.start(purpose: .action)
        case .statusCleared:
            DebugFaults.fail(withStatus: nil)
        case .unsupported(let feature):
            DebugFaults.makeUnsupported(feature)
            feeds.forEach { $0.reloadIfStarted() }
            savedLists.forEach { $0.reloadIfStarted() }
            notifications.start(purpose: .action)
        case .regenerating(let isOn):
            DebugFaults.setRegeneratingHome(isOn)
        case .streaming(let isOnline):
            DebugFaults.setStreamingOnline(isOnline)
        case .slowDownload(let seconds):
            DebugFaults.slowDownloads(by: seconds.map { .seconds($0) })
        case .slowMenuIcons(let seconds):
            DebugFaults.slowMenuIcons(by: seconds.map { .seconds($0) })
        case .slowLookups(let seconds):
            DebugFaults.slowLookups(by: seconds.map { .seconds($0) })
        case .slowUploads(let seconds):
            DebugFaults.slowUploads(by: seconds.map { .seconds($0) })
        case .progressNotice(let seconds, let title):
            showDebugProgress(for: .seconds(seconds), title: title ?? "確かめるための処理中")
        case .transientNotice(let title, let seconds):
            notices.showTransient(
                Notice(id: "debug.transient", kind: .info, title: title),
                duration: seconds ?? AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration)
            )
        case .mediaLimits(let limits):
            DebugFaults.overrideMediaLimits(limits)
        case .catalog(let component):
            topViewController.presentComponentCatalog(opening: component)
        case .dump:
            AgentScreenDump.write(scene: rootViewController.view.window?.windowScene)
        case .storageProbe:
            StorageProbe.write()
        case .fakeTranslation(let delay):
            DebugStatusTranslator.setFakeDelay(delay)
            AppDependencies.settings.noteAutoTranslationModelInstalled()
        case .translationLanguages(let languages):
            AppDependencies.settings.autoTranslationLanguages = languages
            AppDependencies.settings.isAutoTranslationEnabled = true
        case .translationProbe:
            if #available(iOS 26.4, *) {
                TranslationProbe.start()
            }
        case .textBenchmark:
            TextLayoutBenchmark.write(in: rootViewController.view.window)
        case .browser(let url):
            browser.open(url, from: rootViewController.frontmostPresented)
        case .reset:
            rootViewController.dismissPresentedScreens(animated: false)
            for navigation in tabs.allNavigations {
                navigation.popToRootViewController(animated: false)
            }
            tabs.tabBarController.selectedIndex = 0
        case .tuning:
            rootViewController.frontmostPresented.presentTuningPanel()
        case .profileEdit(let note, let field, let crop):
            presentProfileEditor(debugNote: note, debugField: field, debugCrop: crop)
        case .discomfortReport:
            if let window = rootViewController.view.window {
                DiscomfortReportPresenter.present(in: window)
            }
        case .sheetKeyboard:
            // 書いている途中のキーボードから開いたときの動きも見るため、投稿欄は閉じない。高さはメディアを選ぶシートの決めた高さと同じにする。
            SheetKeyboardExperiment.present(from: rootViewController.frontmostPresented, lowHeight: AppDependencies.tuning.value(of: TuningCatalog.composePickerHeight) - (rootViewController.view.window?.safeAreaInsets.bottom ?? 0))
        case .viewer(let index):
            openTopmostMedia(at: index)
        case .emojiReaction(let statusID, let name, let count, let me):
            applyDebugEmojiReaction(statusID: statusID, name: name, count: count, me: me)
        case .appearance(let json):
            overrideAppearanceChoices(json: json)
        case .autoScroll(let distance, let speed):
            autoScroll(distance: distance, speed: speed)
        case .createList(let title):
            changeTabSourcesForDebug("create") { _ = try await $0.createList(title: title) }
        case .deleteList(let id):
            changeTabSourcesForDebug("delete") { try await $0.deleteList(id) }
        case .followTag(let name):
            followHashtag(name)
        case .unfollowTag(let name):
            unfollowHashtag(name)
        case .statusBarTickerLoop(let isOn):
            statusBarTicker.setLooping(isOn, items: DummyNotifications.samples)
        case .inject(let tab, let file):
            inject(file, into: tab)
        case .crash(let kind, let onNextRow):
            if onNextRow {
                DebugFaults.crashOnNextRow(kind)
            } else {
                DebugFaults.crash(kind)
            }
        case .compose(let text, let mediaCount, let pollOptions):
            composer.beginEditing()
            if let text {
                composer.replaceTextForDebug(text)
            }
            if let pollOptions {
                composer.replacePollForDebug(pollOptions)
            }
            if let draftImages = ScenarioMode.server?.script.draftImages {
                composer.model.addPastedMedia(DummyMedia.pastedImages(Array(draftImages().prefix(mediaCount))))
            } else {
                composer.model.addPastedMedia(DummyMedia.pastedImages(count: mediaCount))
            }
        case .composeClose:
            composer.endEditing()
        case .composeOpen:
            composer.beginEditing()
        case .composeReply(let file):
            replyForDebug(to: file)
        case .holdArrivals(let isOn):
            DebugFaults.setHoldingArrivals(isOn)
            if !isOn {
                for feed in feeds {
                    feed.releaseHeldArrivals()
                }
                notifications.releaseHeldArrivals()
            }
        }
    }

    /// `scia-debug://lists/...`で、サーバーのリストを変えてから読み直し、タブの並びに反映する。
    private func changeTabSourcesForDebug(_ operation: String, _ change: @escaping @Sendable (MastodonClient) async throws -> Void) {
        let client = client
        tasks.run(.action) { [weak self] in
            do {
                try await change(client)
                self?.logger.info("debug \(operation, privacy: .public) done")
                self?.loadTabSources()
            } catch {
                self?.logger.error("debug \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// ストリーミングの`emoji_reaction`のイベントと同じ経路で、リアクションの数を当てる。
    /// 絵文字は、対象の投稿にすでに同じ名前のリアクションがあれば、その画像のURLごと使う。なければUnicodeの絵文字か、画像のないカスタム絵文字になる。
    private func applyDebugEmojiReaction(statusID: String?, name: String, count: Int, me: Bool) {
        guard let target = statusID.map({ id in timelines.allObjects.lazy.compactMap { $0.loadedStatus(id: id) }.first }) ?? topmostVisibleStatus() else {
            logger.error("debug emoji reaction: no target status")
            return
        }
        let shown = target.displayed
        let emoji = shown.emojiReactions.first { $0.emoji.name == name }?.emoji ?? ReactionEmoji(name: name)
        let update = EmojiReactionUpdate(statusID: shown.id, emoji: emoji, count: count, accountIDs: me ? [credential.accountID] : [])
        interactions.apply(update, myAccountID: credential.accountID)
    }

    /// 選んでいるタブで、一番上に見えている投稿。
    private func topmostVisibleStatus() -> Status? {
        guard let view = (rootViewController as? UITabBarController)?.selectedViewController?.view, let window = view.window else { return nil }
        return timelines.allObjects
            .filter { $0.isViewLoaded && $0.view.window === window && $0.view.isDescendant(of: view) }
            .compactMap { $0.topmostVisibleStatus() }
            .min { $0.minY < $1.minY }?
            .status
    }

    /// 選んでいるタブで、画面のいちばん上に見えている添付ファイル付きの投稿を、サムネイルをタップしたのと同じ経路でビューアに開く。
    private func openTopmostMedia(at index: Int) {
        guard let view = (rootViewController as? UITabBarController)?.selectedViewController?.view, let window = view.window else { return }
        let grids = Self.mediaGrids(in: view)
            .filter { grid in
                guard let content = grid.content, !content.isCovered, index < content.attachments.count else { return false }
                return grid.convert(grid.bounds, to: window).intersects(window.bounds)
            }
            .sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
        guard let grid = grids.first else {
            logger.error("debug viewer: no visible media with index=\(index, privacy: .public)")
            return
        }
        grid.onSelect?(index)
    }

    /// 「投稿の見た目」の選ぶ項目のうち、JSONに書いた項目だけを上書きする（`DebugURL.appearance`）。
    /// 読めないJSONや、型の違う値（`"false"`のような文字列、知らない選択肢、`null`）を渡したら、設定を変えない。
    /// 保存した値を読む`AppearanceChoices(stored:)`は、読めない項目を既定値に戻すので使わない。使うと、渡し間違えた項目の今の値が既定値で上書きされるため。
    private func overrideAppearanceChoices(json: String) {
        let settings = AppDependencies.settings
        guard let overrides = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              var choices = (try? JSONSerialization.jsonObject(with: settings.appearance.storedData)) as? [String: Any]
        else {
            logger.error("debug appearance: unreadable json")
            return
        }
        choices.merge(overrides) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: choices),
              let appearance = try? JSONDecoder().decode(AppearanceChoices.self, from: data)
        else {
            logger.error("debug appearance: value of a wrong type")
            return
        }
        settings.appearance = appearance
    }

    /// 選んでいるタブのタイムラインを、一定の速さで動かす。端に着いたら止める。
    /// タブの中には隠れたままのタイムラインもあるので、中身のいちばん長いコレクションビューをタイムラインとみなす。
    /// 動かしている間の落ちたフレームを指のスクロールと同じ仕組みで数え、Documents/DebugAutoscroll.logに1行ずつ書き足す。
    /// 指で操作できない実機ではログを読めないので、`devicectl device copy from`でファイルを取り出して読む。
    private func autoScroll(distance: CGFloat, speed: CGFloat) {
        guard let view = (rootViewController as? UITabBarController)?.selectedViewController?.view,
              let list = Self.collectionViews(in: view).max(by: { $0.contentSize.height < $1.contentSize.height })
        else {
            logger.error("debug autoscroll: no list")
            return
        }
        debugScrollTicker?.stop()
        _ = debugScrollHitches.stop()
        debugScrollHitches.start()
        let startedAt = AppDependencies.mediaTime()
        let settings = AppDependencies.settings
        let label = "\(settings.appearance.mediaArrangement.rawValue) tilts=\(settings.appearance.tiltsStackedPhotos)"
        var remaining = abs(distance)
        let direction: CGFloat = distance < 0 ? -1 : 1
        let ticker = FrameTicker(source: DisplayLinkFrameSource.shared, longestElapsed: nil) { [weak list, weak self] elapsed in
            // 画面を閉じたり、タブを切り替えたりしてタイムラインが画面から外れたら、動かすのも数えるのもやめる。記録は残さない。
            // 選ばれていないタブのタイムラインはウィンドウから外れるので、ウィンドウにあるかで両方を見分ける。
            guard let list, list.window != nil else {
                _ = self?.debugScrollHitches.stop()
                return false
            }
            let step = min(speed * CGFloat(elapsed), remaining)
            remaining -= step
            let inset = list.adjustedContentInset
            let top = -inset.top
            let bottom = max(list.contentSize.height + inset.bottom - list.bounds.height, top)
            let target = min(max(list.contentOffset.y + step * direction, top), bottom)
            list.contentOffset.y = target
            let reachedEnd = direction > 0 ? target >= bottom : target <= top
            let continues = remaining > 0 && !reachedEnd
            if !continues {
                self?.finishAutoScroll(label: label, distance: distance, duration: AppDependencies.mediaTime() - startedAt)
            }
            return continues
        }
        debugScrollTicker = ticker
        ticker.start()
    }

    private func finishAutoScroll(label: String, distance: CGFloat, duration: CFTimeInterval) {
        let hitches = debugScrollHitches.stop()
        // 低電力モード、温度、電池の残りでは端末が処理を遅くすることがあるため、比べる条件として一緒に書く。
        UIDevice.current.isBatteryMonitoringEnabled = true
        let device = String(
            format: "lowPower=%@ thermal=%d battery=%.2f",
            ProcessInfo.processInfo.isLowPowerModeEnabled ? "true" : "false",
            ProcessInfo.processInfo.thermalState.rawValue,
            UIDevice.current.batteryLevel
        )
        let line = String(format: "%@ distance=%.0f duration=%.2f dropped=%d hitch=%.3f %@\n", label, distance, duration, hitches.droppedFrames, hitches.hitchTime, device)
        logger.info("debug autoscroll: \(line, privacy: .public)")
        let file = URL.documentsDirectory.appending(path: "DebugAutoscroll.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    private static func collectionViews(in view: UIView) -> [UICollectionView] {
        guard !view.isHidden else { return [] }
        if let list = view as? UICollectionView { return [list] }
        return view.subviews.flatMap(collectionViews(in:))
    }

    private static func mediaGrids(in view: UIView) -> [MediaGridView] {
        guard !view.isHidden else { return [] }
        if let grid = view as? MediaGridView { return [grid] }
        return view.subviews.flatMap(mediaGrids(in:))
    }
}
#endif
