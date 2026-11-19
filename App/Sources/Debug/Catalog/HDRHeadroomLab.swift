import CoreImage
import ImageIO
import PhotosUI
import SciaCore
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// 画面の今の明るさの余地（`currentEDRHeadroom`）を、どの描き方のHDRなら保てるかを、1つずつ出して見比べる。
/// 写真アプリはHDRの写真を出している間、余地を保つが、Sciaは光でもビューアの写真でも、時間がたつと余地が1.2倍ほどまで下がった。
/// 一方、ビューアでHLGのPNGの絵文字を黒地に出すと、余地は4.93倍まで上がった。
/// どの描き方、画像の持ち方、背景なら余地を保てるかで、原因を切り分ける。
/// シミュレーターはHDRの画像を展開せず、ゲインマップ付きのHEICも書き出せず、余地も1倍なので、実機で見る。
final class HDRHeadroomLabViewController: UIViewController {
    private enum Mode: Int, CaseIterable {
        case decoded
        case contentsOfFile
        case solidLayer
        case gradientLayer
        case gradientWithHeadroom
        case maskedSolid
        case none

        var title: String {
            switch self {
            case .decoded: "IO"
            case .contentsOfFile: "UI"
            case .solidLayer: "単色"
            case .gradientLayer: "グラデ"
            case .gradientWithHeadroom: "余地"
            case .maskedSolid: "マスク"
            case .none: "なし"
            }
        }

        var detail: String {
            switch self {
            case .decoded: "ImageIOでHDRに展開（ビューアと同じ）→ UIImageView（HDR）"
            case .contentsOfFile: "UIImage(contentsOfFile:) → UIImageView（HDR）"
            case .solidLayer: "層のbackgroundColorに白の4倍の色（preferredDynamicRange = .high）"
            case .gradientLayer: "CAGradientLayerに白の4倍の色（光と同じ描き方）"
            case .gradientWithHeadroom: "グラデと同じ層に contentsHeadroom = 4"
            case .maskedSolid: "白の4倍の単色の層に、透明度のグラデーションをマスクとして掛ける"
            case .none: "HDRの内容なし（比べる元）"
            }
        }

        var usesImage: Bool { self == .decoded || self == .contentsOfFile }
    }

    /// 画像の描き方で出す画像。
    private enum Sample: Int, CaseIterable {
        /// iPhoneの写真やスクリーンショットと同じ、ISOのゲインマップ付きのHEIC。
        case gainMap
        /// 余地が4.93倍まで上がったHDRの絵文字と同じ、HLGのPNG。
        case hlg
        case picked

        var title: String {
            switch self {
            case .gainMap: "ゲインマップ"
            case .hlg: "HLG"
            case .picked: "写真"
            }
        }
    }

    private let content = UIView()
    private let imageView = UIImageView()
    private let solidLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let headroomGradientLayer = CAGradientLayer()
    private let maskedLayer = CALayer()
    private let alphaMask = CAGradientLayer()
    private let panel = UIStackView()
    private let modeControl = UISegmentedControl(items: Mode.allCases.map(\.title))
    private let sampleControl = UISegmentedControl(items: Sample.allCases.map(\.title))
    private let backgroundControl = UISegmentedControl(items: ["白地", "黒地"])
    /// 投稿欄のビューアは、位置情報を除いて書き直したコピーを出す。その書き直しで余地が落ちるかを見る。
    private let locationControl = UISegmentedControl(items: ["元のまま", "位置情報を除く"])
    /// ビューアは、画像の明るさの幅を`UIImageView`に直接ではなく、画面のtraitで指定する。その違いで余地が落ちるかを見る。
    private let rangeControl = UISegmentedControl(items: ["直接", "trait"])
    /// ビューアは、画像のビューにテキスト認識を付け、画像を置くたびに解析結果を渡す。それで余地が落ちるかを見る。
    private let liveTextControl = UISegmentedControl(items: ["Live Textなし", "Live Text"])
    /// ビューアはダークモードで出す。それで余地が落ちるかを見る。
    private let styleControl = UISegmentedControl(items: ["ライト", "ダーク"])
    /// 投稿欄の添付のサムネイルは、画像を小さく展開する。その大きさで余地が落ちるかを見る。
    private let sizeControl = UISegmentedControl(items: ["ビューアの大きさ", "投稿欄のサムネイル"])
    private let liveText = ImageAnalysisInteraction()
    private static let analyzer = ImageAnalyzer()
    private var analysisTask: Task<Void, Never>?
    private let detailLabel = UILabel()
    private let readout = UILabel()
    private var timer: Timer?
    private var imageInfo: String?
    /// 出している画像の、位置情報を除いて書き直したコピー。
    private var shownCopy: URL?
    /// 写真から選んだファイル。
    private var pickedFile: URL?
    /// 写真を読み込めなかった理由。
    private var pickFailure: String?
    /// 選んだ写真を、ピッカーがどの形式で渡せるか（並び順）と、受け取った形式。投稿欄は、サーバーが処理できなかった形式を避けて受け取る。
    private var pickedTypes: String?
    /// 描き方や画像を選び直すたびに増やし、前の選択の展開が後から届いても使わない。
    private var generation = 0
    /// 写真を選び直すたびに増やし、前に選んだ写真の読み込みが後から届いても使わない。
    private var pickGeneration = 0
    private lazy var gainMapFile: URL? = Self.writeGainMapSample()
    private lazy var hlgFile: URL? = Self.writeHLGSample()

    private var mode: Mode { Mode(rawValue: modeControl.selectedSegmentIndex) ?? .none }
    private var sample: Sample { Sample(rawValue: sampleControl.selectedSegmentIndex) ?? .gainMap }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "HDRの余地"

        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        imageView.contentMode = .scaleAspectFit
        imageView.preferredImageDynamicRange = .high
        imageView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(imageView)
        let bright = UIColor(red: 1, green: 1, blue: 1, alpha: 1, linearExposure: 4).cgColor
        solidLayer.backgroundColor = bright
        solidLayer.preferredDynamicRange = .high
        content.layer.addSublayer(solidLayer)
        gradientLayer.colors = [UIColor.white.cgColor, bright, UIColor.white.cgColor]
        gradientLayer.preferredDynamicRange = .high
        content.layer.addSublayer(gradientLayer)
        headroomGradientLayer.preferredDynamicRange = .high
        headroomGradientLayer.contentsHeadroom = 4
        content.layer.addSublayer(headroomGradientLayer)
        maskedLayer.backgroundColor = bright
        maskedLayer.preferredDynamicRange = .high
        alphaMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        maskedLayer.mask = alphaMask
        content.layer.addSublayer(maskedLayer)
        // 内容をタップすると、バーと操作の欄を隠す。重ねたものが余地を下げているかを見る。
        content.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleChrome)))

        modeControl.selectedSegmentIndex = Mode.decoded.rawValue
        modeControl.addAction(UIAction { [weak self] _ in self?.apply() }, for: .valueChanged)
        sampleControl.selectedSegmentIndex = Sample.gainMap.rawValue
        sampleControl.addAction(UIAction { [weak self] _ in self?.sampleChanged() }, for: .valueChanged)
        backgroundControl.selectedSegmentIndex = 0
        backgroundControl.addAction(UIAction { [weak self] _ in self?.applyBackground() }, for: .valueChanged)
        locationControl.selectedSegmentIndex = 0
        locationControl.addAction(UIAction { [weak self] _ in self?.apply() }, for: .valueChanged)
        rangeControl.selectedSegmentIndex = 0
        rangeControl.addAction(UIAction { [weak self] _ in self?.applyRange() }, for: .valueChanged)
        liveTextControl.selectedSegmentIndex = 0
        liveTextControl.addAction(UIAction { [weak self] _ in self?.applyLiveText() }, for: .valueChanged)
        styleControl.selectedSegmentIndex = 0
        sizeControl.selectedSegmentIndex = 0
        sizeControl.addAction(UIAction { [weak self] _ in self?.apply() }, for: .valueChanged)
        overrideUserInterfaceStyle = .light
        styleControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.overrideUserInterfaceStyle = self.styleControl.selectedSegmentIndex == 1 ? .dark : .light
            self.updateReadout()
        }, for: .valueChanged)
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.numberOfLines = 0
        panel.axis = .vertical
        panel.spacing = 8
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        panel.backgroundColor = .systemBackground
        panel.translatesAutoresizingMaskIntoConstraints = false
        for control in [modeControl, sampleControl, backgroundControl, locationControl, rangeControl, liveTextControl, styleControl, sizeControl, detailLabel] {
            panel.addArrangedSubview(control)
        }
        view.addSubview(panel)

        readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        readout.textColor = .white
        readout.backgroundColor = .black
        readout.numberOfLines = 0
        readout.lineBreakMode = .byCharWrapping
        readout.isUserInteractionEnabled = false
        readout.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(readout)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            readout.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            readout.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            readout.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
        applyBackground()
        apply()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let band = CGRect(x: 0, y: content.bounds.midY - 100, width: content.bounds.width, height: 200)
        solidLayer.frame = band
        gradientLayer.frame = band
        headroomGradientLayer.frame = band
        maskedLayer.frame = band
        alphaMask.frame = maskedLayer.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReadout() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    @objc private func toggleChrome() {
        let hides = !panel.isHidden
        panel.isHidden = hides
        navigationController?.setNavigationBarHidden(hides, animated: false)
    }

    private func applyBackground() {
        let isBlack = backgroundControl.selectedSegmentIndex == 1
        view.backgroundColor = isBlack ? .black : .white
        content.backgroundColor = view.backgroundColor
        let base = (isBlack ? UIColor.black : UIColor.white).cgColor
        gradientLayer.colors = [base, UIColor(red: 1, green: 1, blue: 1, alpha: 1, linearExposure: 4).cgColor, base]
        headroomGradientLayer.colors = gradientLayer.colors
    }

    private func applyRange() {
        if rangeControl.selectedSegmentIndex == 1 {
            imageView.preferredImageDynamicRange = .unspecified
            traitOverrides.imageDynamicRange = .high
        } else {
            traitOverrides.remove(UITraitImageDynamicRange.self)
            imageView.preferredImageDynamicRange = .high
        }
        updateReadout()
    }

    /// ビューアと同じく、画像のビューにテキスト認識を付けて、出している画像を解析させる。
    private func applyLiveText() {
        analysisTask?.cancel()
        liveText.analysis = nil
        if liveTextControl.selectedSegmentIndex == 1 {
            if liveText.view == nil {
                liveText.preferredInteractionTypes = [.textSelection]
                liveText.isSupplementaryInterfaceHidden = true
                imageView.addInteraction(liveText)
                imageView.isUserInteractionEnabled = true
            }
            if let image = imageView.image, ImageAnalyzer.isSupported {
                analysisTask = Task { [weak self] in
                    let analysis = try? await Self.analyzer.analyze(image, configuration: ImageAnalyzer.Configuration([.text, .machineReadableCode]))
                    guard let self, !Task.isCancelled, self.imageView.image === image else { return }
                    self.liveText.analysis = analysis
                    self.updateReadout()
                }
            }
        } else if liveText.view != nil {
            imageView.removeInteraction(liveText)
            imageView.isUserInteractionEnabled = false
        }
        updateReadout()
    }

    private func sampleChanged() {
        if sample == .picked {
            pickPhoto()
        } else {
            apply()
        }
    }

    /// 選んだ描き方だけを出す。ほかの描き方が画面に残っていると、どれが余地を保ったのか分からなくなるため。
    private func apply() {
        generation += 1
        let mode = mode
        detailLabel.text = mode.detail
        // 大きさを指定して展開するのは「IO」だけ。
        sizeControl.isEnabled = mode == .decoded
        solidLayer.isHidden = mode != .solidLayer
        gradientLayer.isHidden = mode != .gradientLayer
        headroomGradientLayer.isHidden = mode != .gradientWithHeadroom
        maskedLayer.isHidden = mode != .maskedSolid
        imageView.image = nil
        applyLiveText()
        imageInfo = nil
        guard mode.usesImage else {
            updateReadout()
            return
        }
        let file: URL? = switch sample {
        case .gainMap: gainMapFile
        case .hlg: hlgFile
        case .picked: pickedFile
        }
        guard let file else {
            imageInfo = "画像: \(sample.title)の画像がありません（\(sample == .picked ? pickFailure ?? "選んでいない" : "作れなかった")）"
            updateReadout()
            return
        }
        let generation = generation
        let removesLocation = locationControl.selectedSegmentIndex == 1
        let maxPixelSize = sizeControl.selectedSegmentIndex == 1 ? Int(ComposeAttachmentStrip.thumbnailPixelSize) : Int(MediaImagePixelSize.full)
        Task { [weak self] in
            var source = mode == .contentsOfFile ? "UIImage(contentsOfFile:)" : "ImageIO（DecodeToHDR）"
            var shownFile = file
            // 処理ごとに別のファイルに書く。切り替えを繰り返すと、前の処理の書き直しが今の処理のファイルを上書きするため。
            let destination = FileManager.default.temporaryDirectory.appending(fileName: SafeFileName("hdr-headroom-\(UUID().uuidString).\(file.pathExtension)"))
            if removesLocation {
                do {
                    if let removed = try await LocationRemover.removingLocation(fromImage: file, destination: destination) {
                        shownFile = removed
                        source += "・位置情報を除いた"
                    } else {
                        source += "・位置情報なし"
                    }
                } catch {
                    source += "・位置情報を除けなかった: \(error)"
                }
            }
            let image: UIImage? = if mode == .contentsOfFile {
                UIImage(contentsOfFile: shownFile.path)
            } else {
                await ImageDecoder.thumbnail(ofFile: shownFile, maxPixelSize: maxPixelSize, dynamicRange: .high).map { UIImage(cgImage: $0) }
            }
            guard let self, self.generation == generation else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            // 出している画像のファイルは、`UIImage(contentsOfFile:)`が後から読むことがあるので、次の画像に替えるまで残す。
            if let shownCopy = self.shownCopy { try? FileManager.default.removeItem(at: shownCopy) }
            self.shownCopy = destination
            self.show(image, source: source)
        }
    }

    private func show(_ image: UIImage?, source: String) {
        imageView.image = image
        applyLiveText()
        let cgImage = image?.cgImage
        imageInfo = [
            "画像: \(sample.title)・\(source)",
            "isHighDynamicRange: \(image?.isHighDynamicRange.description ?? "nil")",
            "タグの余地: \(cgImage.map { String(format: "%.2f", $0.contentHeadroom) } ?? "-")・中身の余地: \(cgImage.map { String(format: "%.2f", $0.calculatedContentHeadroom) } ?? "-")",
            "色空間: \(cgImage?.colorSpace?.name.map { $0 as String } ?? "-")・\(cgImage?.bitsPerComponent ?? 0)bit・\(cgImage.map { "\($0.width)×\($0.height)" } ?? "-")",
        ].joined(separator: "\n")
        updateReadout()
    }

    private func updateReadout() {
        let screen = view.window?.windowScene?.screen
        let headroom = screen.map { String(format: "今 %.2f / 最大 %.2f", $0.currentEDRHeadroom, $0.potentialEDRHeadroom) } ?? "-"
        let liveTextState = liveText.view == nil ? "Live Textなし" : "Live Text（解析\(liveText.analysis == nil ? "なし" : "済み")）"
        let range = "\(liveTextState)・\(traitCollection.userInterfaceStyle == .dark ? "ダーク" : "ライト")\n明るさの指定: \(rangeControl.selectedSegmentIndex == 1 ? "trait" : "直接")・画像のtrait \(Self.name(of: imageView.traitCollection.imageDynamicRange))・画像の指定 \(Self.name(of: imageView.preferredImageDynamicRange))"
        let types = sample == .picked ? pickedTypes : nil
        readout.text = (["EDRの余地 \(headroom)", range] + [imageInfo, types].compactMap(\.self)).joined(separator: "\n")
    }

    private static func name(of range: UIImage.DynamicRange) -> String {
        switch range {
        case .standard: "standard"
        case .constrainedHigh: "constrainedHigh"
        case .high: "high"
        default: "未指定"
        }
    }

    private func pickPhoto() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// 真ん中に白の4倍の明るさの帯を置いた、拡張したリニアの画像。帯の外は透明にして、背景の色を見せる。
    private static func makeBandImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue
              ),
              let band = CGColor(colorSpace: space, components: [4, 4, 4, 1])
        else { return nil }
        context.setFillColor(band)
        context.fill(CGRect(x: 0, y: height / 2 - height / 12, width: width, height: height / 6))
        return context.makeImage().flatMap { CGImageCreateCopyWithContentHeadroom(4, $0) }
    }

    /// ISOのゲインマップ付きのHEIC。iPhoneのスクリーンショットと同じ持ち方にする。
    private static func writeGainMapSample() -> URL? {
        guard let image = makeBandImage(width: 1200, height: 2400) else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(fileName: SafeFileName("hdr-headroom-gainmap.heic"))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// HLGのPNG。HDRの絵文字のカタログ（`HDREmojiCatalog`）と同じ作り方にする。
    private static func writeHLGSample() -> URL? {
        guard let image = makeBandImage(width: 1200, height: 2400), let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG),
              let data = CIContext().pngRepresentation(of: CIImage(cgImage: image), format: .RGBA16, colorSpace: hlg)
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(fileName: SafeFileName("hdr-headroom-hlg.png"))
        return (try? data.write(to: url)) != nil ? url : nil
    }
}

extension HDRHeadroomLabViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        // 前に選んだ写真を出したまま読み込みを待たないよう、読み込めるまで写真なしにする。
        pickedFile = nil
        pickFailure = results.isEmpty ? nil : "読み込み中"
        apply()
        pickGeneration += 1
        pickedTypes = nil
        guard let provider = results.first?.itemProvider else { return }
        let offered = provider.registeredTypeIdentifiers
        let pickGeneration = pickGeneration
        Task { [weak self] in
            do {
                let file = try await LocalMediaLoader.load(from: provider, avoiding: [])
                guard let self, self.pickGeneration == pickGeneration else { return }
                self.pickedFile = file.url
                self.pickFailure = nil
                self.pickedTypes = "写真の形式: \(offered.joined(separator: "・"))→受け取った\(file.mimeType)"
            } catch {
                guard let self, self.pickGeneration == pickGeneration else { return }
                self.pickFailure = "読み込めなかった: \(error)"
            }
            self?.apply()
        }
    }
}
