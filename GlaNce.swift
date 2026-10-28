import SwiftUI
import AVFoundation
import AppKit
import CoreImage
import CoreLocation
import CoreText

// 미리보기 및 저장 사진 비율 (가로:세로), 팝오버 크기
let previewAspect: CGFloat = 16.0 / 9.0
let popoverWidth: CGFloat = 336                      // 이전 480의 70%
let popoverHeight: CGFloat = popoverWidth / previewAspect

let sharedCamera = CameraModel()

// MARK: - Camera

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, CLLocationManagerDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "glance.camera")
    private var configured = false
    private var wanted = false
    private var statusClear: DispatchWorkItem?

    // 워터마크용 위치
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var placeName: String?          // main thread
    private var capturePlace: String?       // 촬영 시점 스냅샷 (camera queue)

    // 저장 위치 (변경 가능, 앱을 다시 켜도 유지)
    static let defaultDir: URL = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GlaNce", isDirectory: true)
    private static let saveDirKey = "saveDir"
    @Published private(set) var saveDir: URL
    private var captureDir: URL               // 촬영 시점 스냅샷 (camera queue)

    override init() {
        let dir = UserDefaults.standard.url(forKey: CameraModel.saveDirKey) ?? CameraModel.defaultDir
        saveDir = dir
        captureDir = dir
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    @Published var status = ""

    func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "사진을 저장할 폴더를 선택하세요"
        panel.directoryURL = saveDir
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSaveDir(url)
    }

    func resetSaveDir() {
        UserDefaults.standard.removeObject(forKey: CameraModel.saveDirKey)
        setSaveDir(CameraModel.defaultDir, remember: false)
    }

    private func setSaveDir(_ url: URL, remember: Bool = true) {
        saveDir = url
        if remember { UserDefaults.standard.set(url, forKey: CameraModel.saveDirKey) }
        setStatus("저장 위치: \(url.lastPathComponent)")
    }

    func start() {
        wanted = true
        if placeName == nil { requestPlace() }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok && self.wanted { self.start() }
                }
            }
        default:
            setStatus("카메라 권한 없음: 시스템 설정 > 개인정보 보호 및 보안 > 카메라", sticky: true)
        }
    }

    func stop() {
        wanted = false
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        configured = true
    }

    func capture() {
        let place = placeName
        let dir = saveDir
        queue.async {
            guard self.session.isRunning else { return }
            self.capturePlace = place
            self.captureDir = dir
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              var image = CIImage(data: data) else {
            setStatus("촬영 실패")
            return
        }

        // 미리보기와 같은 16:9 영역으로 가운데 크롭
        let e = image.extent
        var crop = e
        if e.width / e.height > previewAspect {
            let w = e.height * previewAspect
            crop = CGRect(x: e.minX + (e.width - w) / 2, y: e.minY, width: w, height: e.height)
        } else {
            let h = e.width / previewAspect
            crop = CGRect(x: e.minX, y: e.minY + (e.height - h) / 2, width: e.width, height: h)
        }
        image = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        // 거울처럼 좌우반전 (미리보기와 동일)
        let w = image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))

        // 좌하단 워터마크: 날짜 + 위치
        let df = DateFormatter()
        df.dateFormat = "yyyy.MM.dd"
        var mark = df.string(from: Date())
        if let p = capturePlace { mark += "   \(p.uppercased())" }

        guard let marked = addWatermark(to: image, text: mark),
              let jpg = NSBitmapImageRep(cgImage: marked)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            setStatus("변환 실패")
            return
        }
        do {
            try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd_HHmmss"
            let url = captureDir.appendingPathComponent("GlaNce_\(f.string(from: Date())).jpg")
            try jpg.write(to: url)
            setStatus("저장됨")
        } catch {
            setStatus("저장 실패", sticky: true)
        }
    }

    // MARK: Watermark

    private func addWatermark(to image: CIImage, text: String) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let size = CGFloat(h) * 0.03                      // 글자 크기: 사진 높이의 3%
        let font = NSFont(name: "AvenirNext-UltraLight", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .ultraLight)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = size * 0.2
        shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: size * 0.22,                             // 자간: 글자 크기의 22%
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),   // 불투명도
            .shadow: shadow
        ]
        let margin = CGFloat(h) * 0.035

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: NSPoint(x: margin, y: margin), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    // MARK: Location

    private func requestPlace() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            locationManager.requestLocation()
        default:
            break   // 거부 시 날짜만 표시
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        if s == .authorizedAlways || s == .authorized { manager.requestLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "en_US")) { marks, _ in
            guard let m = marks?.first else { return }
            let name = m.locality ?? m.administrativeArea ?? m.country
            DispatchQueue.main.async { self.placeName = name }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func setStatus(_ s: String, sticky: Bool = false) {
        DispatchQueue.main.async {
            self.statusClear?.cancel()
            self.status = s
            guard !sticky else { return }
            let item = DispatchWorkItem { [weak self] in self?.status = "" }
            self.statusClear = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveDir)
    }
}

// MARK: - Preview

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private var startObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)

        // 카메라가 실제로 켜진 뒤에야 connection이 생기므로 그때 반전 적용
        startObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyMirror()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let o = startObserver { NotificationCenter.default.removeObserver(o) }
    }

    // 영상 부분을 잡고 끌면 팝오버 분리 / 창 이동
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        applyMirror()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMirror()
    }

    func applyMirror() {
        guard let c = previewLayer.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = true
    }
}

struct CameraPreview: NSViewRepresentable {
    let camera: CameraModel

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = camera.session
        return v
    }

    func updateNSView(_ v: PreviewView, context: Context) {
        v.applyMirror()
    }
}

// MARK: - Popover content (버튼 전부 영상 위에 배치)

struct GlaNceView: View {
    @ObservedObject var camera: CameraModel
    let close: () -> Void

    var body: some View {
        ZStack {
            CameraPreview(camera: camera)

            VStack {
                HStack {
                    overlayButton("xmark.circle.fill", size: 18, action: close)
                    Spacer()
                    overlayButton("power.circle.fill", size: 18) { NSApp.terminate(nil) }
                }
                Spacer()
                HStack(alignment: .center) {
                    if !camera.status.isEmpty {
                        Text(camera.status)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    overlayButton("folder.circle.fill", size: 22) { showFolderMenu(camera) }
                    overlayButton("camera.circle.fill", size: 30) { camera.capture() }
                        .keyboardShortcut(.space, modifiers: [])
                }
            }
            .padding(8)
        }
        .frame(width: popoverWidth, height: popoverHeight)
    }

    private func overlayButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Folder menu (폴더 버튼: 열기 / 저장 위치 변경 / 기본 위치)

final class MenuActions: NSObject {
    static let shared = MenuActions()
    private var handlers: [Int: () -> Void] = [:]

    func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let tag = handlers.count
        handlers[tag] = handler
        let it = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        it.target = self
        it.tag = tag
        return it
    }

    func reset() { handlers.removeAll() }

    @objc private func run(_ sender: NSMenuItem) { handlers[sender.tag]?() }
}

func showFolderMenu(_ camera: CameraModel) {
    let actions = MenuActions.shared
    actions.reset()
    let menu = NSMenu()

    let path = camera.saveDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    let info = NSMenuItem(title: "저장 위치: \(path)", action: nil, keyEquivalent: "")
    info.isEnabled = false
    menu.addItem(info)
    menu.addItem(.separator())
    menu.addItem(actions.item("폴더 열기") { camera.openFolder() })
    menu.addItem(actions.item("저장 위치 변경…") {
        // 메뉴가 닫힌 뒤에 패널을 띄워야 안정적
        DispatchQueue.main.async { camera.chooseSaveDir() }
    })
    if camera.saveDir != CameraModel.defaultDir {
        menu.addItem(actions.item("기본 위치로 되돌리기") { camera.resetSaveDir() })
    }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

// MARK: - Menu bar icon (반사된 g, 템플릿 이미지라 다크/라이트 모드 자동 대응)

func makeMenuBarIcon() -> NSImage {
    let size = NSSize(width: 22, height: 18)
    let img = NSImage(size: size, flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let cx = rect.midX

        // 거울 축
        NSColor.black.withAlphaComponent(0.4).setFill()
        NSBezierPath(rect: NSRect(x: cx - 0.5, y: 1.5, width: 1, height: 15)).fill()

        // 메뉴바 크기에선 Ultra Light가 너무 얇아서 Regular 사용
        let font = NSFont(name: "AvenirNext-Regular", size: 15) ?? NSFont.systemFont(ofSize: 15)
        func line(_ alpha: CGFloat) -> CTLine {
            let s = NSAttributedString(string: "g", attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    NSColor.black.withAlphaComponent(alpha).cgColor
            ])
            return CTLineCreateWithAttributedString(s)
        }
        let solid = line(1.0)
        let faint = line(0.45)
        let b = CTLineGetImageBounds(solid, ctx)
        let x = cx - 1.5 - (b.origin.x + b.width)
        let y = rect.midY - (b.origin.y + b.height / 2)

        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(solid, ctx)

        ctx.saveGState()
        ctx.translateBy(x: 2 * cx, y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(faint, ctx)
        ctx.restoreGState()
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "GlaNce"
    return img
}

// MARK: - Menu bar item + popover

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = makeMenuBarIcon()
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.behavior = .transient          // 바깥 클릭하면 닫힘 (분리된 창은 유지)
        popover.animates = true                // 말풍선처럼 커지며 나타나는 기본 애니메이션
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: GlaNceView(camera: sharedCamera) { [weak self] in
                self?.popover.performClose(nil)
            }
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // 팝오버가 보이는 동안만 카메라 사용
    func popoverWillShow(_ notification: Notification) { sharedCamera.start() }
    func popoverDidClose(_ notification: Notification) { sharedCamera.stop() }

    // 팝오버를 잡고 끌어내리면 떠 있는 창으로 분리
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidDetach(_ popover: NSPopover) {
        popover.contentViewController?.view.window?.level = .floating
    }
}

@main
enum GlaNceMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
