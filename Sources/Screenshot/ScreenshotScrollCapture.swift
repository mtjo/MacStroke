//
//  ScreenshotScrollCapture.swift
//
//  长截图的循环：抓一帧 → 注入一次滚动 → 等画面稳住 → 再抓一帧 → 认出这两帧差了多少行
//  → 把新露出来的那一段接回长图。反复，直到到头、认不上、或者撞上限。
//
//  默认往下接。但用户框住的那一块很可能本来就停在底部（聊天记录、翻到底的网页），这时候
//  往下滚一动没动，而上面还有几屏内容没接 —— 所以第一下滚不动就翻成往上接，长图朝顶上长
//  （第一帧从长图的顶变成它的底，全局行号会出现负数，见 `canvasTop`）。只翻一次，且只在
//  一段都还没接上时翻：往下接过几段再翻回去，翻出来的是已经接过的内容。
//
//  为什么这一路不能像普通截图那样扣着一张定格帧：要的是**内容自己在动**，遮罩底下那张死图
//  滚不动。所以滚动截图（和录屏一样）得把遮罩收掉、屏幕还给被截的那个 App，只留一圈描边和
//  控制胶囊。代价就是那两扇必须 `sharingType = .none` —— 描边每帧都出现在同一位置，会被
//  当成吸顶栏拼进长图（见 `ScreenshotLivePanel` 文件头）。
//
//  抓帧走整屏 `CGDisplayCreateImage` + 视图坐标裁剪，而不是 `CGDisplayCreateImageForRegion`：
//  后者那个 rect 到底以「这块屏的左上」还是「主屏的左上」为原点，文档语焉不详；前者用的正是
//  `ScreenshotFrame` 里已被单测锁死的那套换算（flipped 视图和位图同为左上原点，连 y 都不翻）。
//  多抓一次全屏是几毫秒的事，换掉一个会静默偏移的坐标坑。
//
//  接进长图的每一段都会画进一块新位图再留着（`isolated`）：`cropping(to:)` 是惰性的，留着
//  几十张裁剪图等于留着几十张全屏原图，2x 屏上轻松吃掉几个 G。
//

import AppKit
import CoreGraphics
import Storage

/// 一次滚动截图的结局。
enum ScreenshotScrollOutcome {
    /// 拼出来的长图，尺寸就在图上。`appended` = 在第一帧之外接上了几段：
    /// **0 段就意味着这一场压根没滚起来**，出图等同于一张普通截图，必须另报。
    case composed(image: CGImage, appended: Int)
    case failed(reason: String)
}

final class ScreenshotScrollCapture {
    /// 一次注入滚多少**点**。默认 100，真机取值来自偏好「每次滚动的量」
    /// （`ScreenshotSettings.scrollStep`，读的时候已经夹进 20…400）。取小步而不是
    /// 「一屏」：一页一跳的列表会整页跳，重合太少会让拼接认不上；小步滚虽然帧数多，
    /// 但每帧重合够长，判据才站得住。
    var pointsPerStep: CGFloat = 100
    /// 滚完到再抓一帧之间的等待。惯性滚动（网页、相册）要半秒才停，抢在停下之前抓，
    /// 两帧的同一行永远对不上。
    static let settleInterval: TimeInterval = 0.45
    /// 最多接「几屏」：按框住那块的实际高度换算成像素上限（第一帧抓到才知道一屏多高）。
    var maxScreens: Int = 10
    /// 滚了多少次都不嫌多的兜底：万一内容每次只挪两三行（步长 20 点配上慢速滚动），
    /// 光靠高度上限要跑上一万轮。收在这个次数上，一次长截图最多多花一分半。
    static let maxSteps: Int = 200

    /// 每接上一段回一次读数（当前长图尺寸），主线程。
    var onReadout: ((String) -> Void)?
    var onOutcome: ((ScreenshotScrollOutcome) -> Void)?

    /// 取帧的接缝：nil = 走真抓屏。单测把滚动条画在内存里喂进来，整条循环（比对、裁段、
    /// 拼长图、收场）就能在没有抓屏权限、没有辅助功能授权的进程里跑通。
    var frameSource: (() -> ScreenshotFrame?)?
    /// 滚动的接缝：nil = 走 CGEvent 注入。参数是「这一档要滚多少**点**」。
    var scrollInjector: ((CGFloat) -> Void)?

    private let screen: NSScreen
    /// 采集区域，遮罩那套**视图坐标**（flipped，原点在这块屏的左上角）。
    private let region: CGRect
    private let queue = DispatchQueue(label: "net.mtjo.macstroke.screenshot.scroll")

    private var timer: Timer?
    private var previous: ScreenshotRowPrint?
    private var entries: [(image: CGImage, top: Int)] = []
    /// 已收集内容在**全局行号**上占的区间 `[canvasTop, canvasBottom)`。
    /// 往上接的时候 `canvasTop` 会变成负数 —— 第一帧就不再是长图的顶，而是它的底。
    private var canvasTop = 0
    private var canvasBottom = 0
    private var canvasHeight: Int { canvasBottom - canvasTop }
    /// 往哪个方向滚。默认向下；第一下就滚不动时翻成向上（见 `receive` 里的 `.up` 分支）。
    private var direction: Direction = .down
    /// 只翻一次：翻过去还是不动，那就是这块内容压根不吃滚轮，别再翻回来白滚一趟。
    private var flipped = false
    private enum Direction { case down, up }
    /// 这一场的像素上限：第一帧抓到手之后按「一帧高 × maxScreens」算出来。
    private var maxHeight = 0
    private var width = 0
    private var scale: CGFloat = 1
    private var steps = 0
    /// 一帧正在后台抓：滚动是定时的，抓帧慢了不能叠第二份上去。
    private var busy = false
    /// 现场（锁屏/安全输入/指针/点上是哪扇窗）只报一次，见 `postScroll`。
    private var reportedEnvironment = false
    private var isFinished = false

    init(screen: NSScreen, region: CGRect) {
        self.screen = screen
        self.region = region
    }

    /// 摆好第一帧就开始滚。第一帧不进循环：它没有「上一帧」可比，只负责铺底和取指纹。
    func start() {
        guard !isFinished, let shot = grab() else {
            onOutcome?(.failed(reason: L("Screenshot scroll grab failed")))
            return
        }
        scale = shot.scale
        width = shot.image.width
        // 上限按这一帧的实际高度算：用户框的是半屏还是全屏，「十屏」差出一倍。
        maxHeight = shot.image.height * Swift.max(1, maxScreens)
        guard let rows = ScreenshotRowPrint.capture(shot.image) else {
            onOutcome?(.failed(reason: L("Screenshot scroll grab failed")))
            return
        }
        previous = rows
        entries = [(Self.isolated(shot.image) ?? shot.image, 0)]
        canvasTop = 0
        canvasBottom = shot.image.height
        NSLog("%@", "[ScreenshotScroll] 起场：选区 \(Int(region.width))×\(Int(region.height)) 点 → "
            + "帧 \(width)×\(shot.image.height) 像素，每步 \(Int(pointsPerStep.rounded())) 点，"
            + "上限 \(maxHeight) 行")
        report()
        timer = Timer.scheduledTimer(withTimeInterval: Self.settleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 滚动策略是「先滚再等再抓」，所以第一下不等 timer，立刻滚。
        postScroll()
    }

    /// 用户按停止：把已经拼好的部分出图（哪怕只有一屏）。
    func stop() {
        end(reason: nil)
    }

    /// 取消：丢掉这一场，什么都不出。
    func cancel() {
        timer?.invalidate()
        timer = nil
        isFinished = true
        restoreCursor()
        entries.removeAll()
        previous = nil
    }

    // MARK: - 循环

    private func tick() {
        guard !isFinished, !busy else { return }
        guard steps < Self.maxSteps, canvasHeight < maxHeight else {
            end(reason: nil)   // 撞了次数或高度上限：见上面两个常量的注释
            return
        }
        busy = true
        // 抓帧放后台（一次全屏抓取十几毫秒，压在定时器上会让滚动手感发涩），
        // 但状态只在主线程动 —— 循环、读数、收场都串行在这一头。
        queue.async { [weak self] in
            guard let self else { return }
            let shot = self.grab()
            DispatchQueue.main.async {
                guard !self.isFinished else { return }
                self.busy = false
                guard let shot else {
                    // 屏被拔掉/休眠：前面拼好的照样出图，理由见 `end(reason:)`。
                    self.end(reason: nil)
                    return
                }
                self.receive(shot.image)
            }
        }
    }

    private func receive(_ image: CGImage) {
        guard let rows = ScreenshotRowPrint.capture(image) else {
            end(reason: nil)
            return
        }
        guard let last = previous else { end(reason: nil); return }
        // 先验 = 注入量换算成像素行，只用来给拼接缩小搜索范围（见 `ScreenshotStitcher`）。
        let expected = Self.expectedShift(points: pointsPerStep, scale: scale)
        // 往上滚的时候两个参数要反过来传：位移的定义是「`next` 第 j 行 == `previous` 第
        // (j+s) 行」。向下滚 = 新帧在旧帧下面（新帧顶行对旧帧第 s 行）；向上滚 = 新帧在旧帧
        // 上面（旧帧顶行对新帧第 s 行）。比对那套一个字不用改，换的只是谁当 previous。
        let shift = direction == .down
            ? ScreenshotStitcher.shift(previous: last, next: rows, expected: expected)
            : ScreenshotStitcher.shift(previous: rows, next: last, expected: expected)
        switch shift {
        case 0:
            // 画面一动没动。三种成因在画面上长得一模一样：内容到头了、这块压根不吃滚轮、
            // 滚轮没落到底下那扇窗上（没授权 / 指针被抢走 / 上面盖了别的窗），只有现场日志
            // 能分辨。但其中一种**是能救的**：用户框的这块本来就停在底部（聊天记录、已经
            // 翻到底的网页、自动贴底的列表），往下滚当然滚不动，而上面还有整整几屏没接。
            // 只在一段都没接过时翻：已经往下接了几段再往上翻，翻出来的是刚才接过的内容，
            // 往长图顶上再铺一遍就是重复段。
            if !flipped, steps == 0 {
                flipped = true
                direction = .up
                NSLog("%@", "[ScreenshotScroll] 向下滚不动（大概本来就停在底部），翻成向上接；"
                    + "现场：\(Self.environmentReport(at: regionCenterInCG))")
                postScroll()
                return
            }
            NSLog("%@", "[ScreenshotScroll] 画面一动没动，收场（已接 \(entries.count - 1) 段，"
                + "方向\(direction == .down ? "向下" : "向上")）；"
                + "现场：\(Self.environmentReport(at: regionCenterInCG))")
            end(reason: nil)                      // 画面一动没动 = 到头了
        case let moved? where moved > 0:
            guard let segment = direction == .down
                ? Self.segment(from: image, shift: moved, canvasHeight: canvasBottom)
                : Self.upwardSegment(from: image, shift: moved, canvasTop: canvasTop) else {
                NSLog("%@", "[ScreenshotScroll] 位移 \(moved) 行裁不出段，收场")
                end(reason: nil)
                return
            }
            steps += 1
            entries.append(segment)
            if direction == .down {
                canvasBottom = segment.top + segment.image.height
            } else {
                canvasTop = segment.top
            }
            previous = rows
            report()
            NSLog("%@", "[ScreenshotScroll] 接上第 \(steps) 段（向\(direction == .down ? "下" : "上")）："
                + "走 \(moved) 行，长图 \(width)×\(canvasHeight)")
            if canvasHeight >= maxHeight { end(reason: nil); return }
            postScroll()
        default:
            // 认不上（吸顶栏、动个不停的内容、一次跳超过一屏）：不猜位移，直接收场。
            // 猜错的长图比短的长图糟得多 —— 中间会凭空多出一段重复内容。
            NSLog("%@", "[ScreenshotScroll] 认不出位移（先验 \(expected) 行），收场保留 \(entries.count - 1) 段")
            end(reason: nil)
        }
    }

    /// 收场：把攒下的各段铺成一张长图交出去。
    ///
    /// `reason == nil` 是「正常收场」，半途抓不到帧、认不上行、撞了上限都走这一支：
    /// **已经拼好的那部分是用户滚出来的成果**，为了最后一段没滚成就把前面全丢掉，等于
    /// 让用户白等一场。只有一帧也照样出图（那就是张普通截图，不是失败，用户框的这一块
    /// 本来就只有一屏）。真失败（连第一帧都没有、长图铺不出来）才传 reason 进来。
    private func end(reason: String?) {
        guard !isFinished else { return }
        timer?.invalidate()
        timer = nil
        isFinished = true
        restoreCursor()
        if let reason {
            onOutcome?(.failed(reason: reason))
            return
        }
        // 各段的 `top` 是**全局行号**，往上接的那些是负数；铺图前整体平移，让最上面那段落在 0。
        let laid = entries.map { (image: $0.image, top: $0.top - canvasTop) }
        guard let image = ScreenshotStitcher.compose(laid, width: width, height: canvasHeight) else {
            onOutcome?(.failed(reason: L("Screenshot scroll compose failed")))
            return
        }
        onOutcome?(.composed(image: image, appended: entries.count - 1))
    }

    private func report() {
        onReadout?("\(width)×\(canvasHeight)")
    }

    private func grab() -> ScreenshotFrame? {
        if let frameSource { return frameSource() }
        guard let shot = ScreenshotGrabber.grab(screen: screen),
              let cut = shot.crop(viewRect: region) else { return nil }
        return ScreenshotFrame(image: cut.image, pointSize: region.size)
    }

    /// 注入一次滚动（方向由 `direction` 定，向下为正）。
    ///
    /// 先把指针请到选区中心再投：滚轮事件是按**指针底下的窗口**路由的，`location` 只填
    /// 事件字段不改指针（`CGWarpMouseCursorPosition` 也不产生移动事件，得补一发
    /// mouseMoved 让窗口服务认下新位置）。这一场里指针被借走，收尾时放回原位。
    private func postScroll() {
        let points = direction == .down ? pointsPerStep : -pointsPerStep
        if let scrollInjector {
            scrollInjector(points)
            return
        }
        placeCursorInRegion()
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -Self.wheelUnits(points: points),
                                  wheel2: 0, wheel3: 0) else { return }
        let target = regionCenterInCG
        event.location = target
        event.post(tap: .cgSessionEventTap)
        NSLog("%@", "[ScreenshotScroll] 注入滚轮 \(Int(points.rounded())) 点 到 "
            + "\(Int(target.x)),\(Int(target.y))")
        // 只在第一下报现场：每一步都报会把日志淹掉，而「注入没落地」这件事第一下就成立。
        if !reportedEnvironment {
            reportedEnvironment = true
            NSLog("%@", "[ScreenshotScroll] 现场：\(Self.environmentReport(at: target))")
        }
    }

    /// 「画面一动没动」有两种完全不同的成因，画面上长得一模一样，只能靠这条日志分辨：
    /// 内容到底了（正常收场），还是滚轮压根没落到那个窗口上（锁屏 / 安全输入 / 指针没请过去 /
    /// 框住的这块里没有可滚的窗）。所以起场和收场各报一次现场。
    static func environmentReport(at point: CGPoint) -> String {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let locked = (session["CGSSessionScreenIsLocked"] as? Int) == 1
        let secureInput = session["CGSSessionSecureInputPID"] as? Int ?? 0
        let cursor = CGEvent(source: CGEventSource(stateID: .hidSystemState))?.location ?? .zero
        let landed = abs(cursor.x - point.x) < 2 && abs(cursor.y - point.y) < 2
        return "锁屏=\(locked ? "是" : "否") 安全输入=\(secureInput) "
            + "指针\(landed ? "到位" : "没请过去（实测 \(Int(cursor.x)),\(Int(cursor.y))）") "
            + "点上是「\(windowOwner(at: point) ?? "没有窗口")」"
    }

    /// 这个点最上面那扇普通窗是谁的（layer 0 = 应用窗口，状态栏/浮层那些层不算）。
    private static func windowOwner(at point: CGPoint) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            return (info[kCGWindowOwnerName as String] as? String ?? "?")
                + " " + (info[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }

    // MARK: - 指针

    /// 选区中心在全局 CG 坐标（原点主屏左上）里的位置 —— 滚轮事件要的那个。
    private var regionCenterInCG: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        return Self.cgPoint(viewPoint: CGPoint(x: region.midX, y: region.midY),
                            screenFrame: screen.frame, primaryHeight: primaryHeight)
    }

    /// 会话开始时的指针位置，收场时还回去。nil = 这一场没借过指针。
    private var cursorReturn: CGPoint?

    private func placeCursorInRegion() {
        let target = regionCenterInCG
        if cursorReturn == nil {
            cursorReturn = CGEvent(source: CGEventSource(stateID: .hidSystemState))?.location
        }
        guard CGWarpMouseCursorPosition(target) == .success else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target,
                mouseButton: .left)?.post(tap: .cgSessionEventTap)
    }

    /// 把指针还给用户。只在这确实借过指针时才动它：压根没注入过的场次（抓帧就失败了）
    /// 把用户手边的光标挪一下再挪回去，等于凭空抖一次。
    private func restoreCursor() {
        guard let cursorReturn else { return }
        self.cursorReturn = nil
        CGWarpMouseCursorPosition(cursorReturn)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: - 纯计算

    /// 视图坐标（flipped，原点在这块屏左上）→ 滚轮事件要的全局 CG 坐标（原点在主屏左上）。
    /// 先翻回 AppKit 的左下原点，再按主屏高度翻一次；单测自己喂 `primaryHeight`。
    static func cgPoint(viewPoint: CGPoint, screenFrame: NSRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: viewPoint.x + screenFrame.minX,
                y: primaryHeight - (screenFrame.maxY - viewPoint.y))
    }

    /// 滚轮事件里那个数值 = 要滚的**点**数，负号是往下翻。
    ///
    /// 关键是这里**不乘屏幕倍率**：`units: .pixel` 的「像素」是 AppKit 的点，不是位图里的
    /// 像素行。工程里量过的证据是 `RemoteClickExecutor.scrollBy` 那条实测 —— dy=+100 连发
    /// 三条，内容原点走 300，一一对应的是点。乘了倍率会让「每次滚动的量」这个设置项在 2x
    /// 屏上实际滚两倍：选区矮的时候一次跳过一整屏，重合不足 40 行，拼接直接认不上，
    /// 用户看到的就是「长截图没反应」。方向同理照抄那条实测。
    static func wheelUnits(points: CGFloat) -> Int32 { Int32(points.rounded()) }

    /// 注入的滚动量（点）在这一帧里对应多少像素行 —— 拼接的先验。
    static func expectedShift(points: CGFloat, scale: CGFloat) -> Int {
        Int((points * scale).rounded())
    }

    /// 新帧相对旧帧向下走了 `shift` 行时，这一帧该往长图上接哪一段。
    ///
    /// 新内容就是新帧最底下那 `shift` 行（顶上那些旧帧里已经有了）。接的位置是当前的
    /// 长图底边，所以 `top` = 底边行号；行数钳到新帧实际高度，防止 `shift` 大于帧高时
    /// 裁出空图。
    static func segment(from frame: CGImage, shift: Int, canvasHeight: Int)
        -> (image: CGImage, top: Int)? {
        guard shift > 0, canvasHeight >= 0 else { return nil }
        let rows = min(shift, frame.height)
        let top = frame.height - rows
        guard let cut = frame.cropping(to: CGRect(x: 0, y: top, width: frame.width, height: rows)),
              let isolated = isolated(cut) else { return nil }
        return (isolated, canvasHeight)
    }

    /// 反过来：新帧相对旧帧**向上**走了 `shift` 行时该接哪一段。
    ///
    /// 新内容是新帧最上面那 `shift` 行，它们在全局行号上落在当前长图顶边**之上**，所以
    /// `top = canvasTop - shift` 是个负数 —— 第一帧这时候成了长图的底而不是顶。
    static func upwardSegment(from frame: CGImage, shift: Int, canvasTop: Int)
        -> (image: CGImage, top: Int)? {
        guard shift > 0, frame.height > 0 else { return nil }
        let rows = min(shift, frame.height)
        guard let cut = frame.cropping(to: CGRect(x: 0, y: 0, width: frame.width, height: rows)),
              let isolated = isolated(cut) else { return nil }
        return (isolated, canvasTop - rows)
    }

    /// 把（可能是惰性的）裁剪图重画成一块自有像素的位图，好让全屏原图能被马上释放。
    static func isolated(_ image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
