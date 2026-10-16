//
//  ScreenshotRecorder.swift
//
//  录屏：把选中的那块区域录成一段 MP4。
//
//  为什么用 AVCaptureScreenInput 而不是 ScreenCaptureKit：
//  - SCK 的区域裁剪走 `SCStreamConfiguration.sourceRect`，本机 SDK 的头文件只说
//    「in points in the display's logical coordinate system」，**没写原点在哪一角**；
//    而 AVCaptureScreenInput 的 `cropRect` 在同一个 SDK 里写得明明白白：「defines a
//    smaller section of the screen in the screen's coordinate system. The origin (0,0)
//    is the bottom-left corner of the screen」。坐标原点是这类功能最容易错、又最难在
//    屏幕上看出来的地方（错了我自己不知道，用户拿到的是一段框错位置的录像），
//    所以挑写清楚的那一个。
//  - SCK 还要先异步取 `SCShareableContent`、每台设备维持一条代理链，为了录一块矩形
//    不值当（和 RemoteScreenCapture 那份「不用 SCK」的判断同源）。
//
//  编码路线：AVCaptureVideoDataOutput 出帧 → AVAssetWriter + H.264 写 MP4。
//  没走 AVCaptureMovieFileOutput 是因为它出 .mov，而用户接下来要把录像发进微信/钉钉 ——
//  mp4 才是那些接收方都认的容器。
//
//  没有声音是这一期的明确取舍：AVFoundation 这条路在 macOS 13 上只能录麦克风，录不到
//  系统内部音；要内音得换 SCK 的 capturesAudio（13.0+）或者装虚拟声卡。挂麦克风还会多
//  弹一次「允许 MacStroke 使用麦克风」—— 那和截图本身的授权是两回事，会把这条链子的
//  上手成本抬高一档。所以先出无声的画。
//
//  权限沿用截图那一套（屏幕录制）。没授权时抓屏只会给一张干净壁纸，所以门在控制器那边，
//  这里不重复问。
//

import AVFoundation
import AppKit
import CoreMedia
import Storage

/// 一次录屏的结局。
enum ScreenshotRecordOutcome {
    case saved(url: URL, seconds: TimeInterval)
    /// 一帧都没录到（区域所在屏被拔掉、会话起不来）：控制器按「取消」处理。
    case empty
    case failed(reason: String)
}

/// 一帧喂进编码器的结果。分成三档是因为「这一帧没收」和「这一场废了」是两件事：
/// 编码器忙时丢一帧是设计内的（`alwaysDiscardsLateVideoFrames` 也开着），
/// 而 writer 起不来/已经失败，再喂多少帧都是白费，得立刻报错收场。
enum ScreenshotIngest: Equatable {
    /// 进了片，`seconds` 是这一帧在成片里的时刻（胶囊读数用它）。
    case appended(seconds: TimeInterval)
    case dropped
    case broken
}

final class ScreenshotRecorder: NSObject {
    /// 帧率。默认 30，真机取值来自偏好（`ScreenshotSettings.recordFrameRate`，
    /// 读的时候已经夹进 5…120）。再高对网页/文档滚动没意义，文件却大一截。
    var frameRate: Int32 = 30
    /// 最长录多久（秒）：防止用户忘了停止把盘写满。同样由控制器按偏好灌进来。
    var maxSeconds: TimeInterval = 600
    /// 鼠标指针进不进画面。做操作演示要开，录内容本身开着只会挡字。
    var capturesCursor = true

    /// 每录满一秒回一次时长（胶囊上的读数用它）。已经在主线程。
    var onTick: ((TimeInterval) -> Void)?
    /// 录制**中途**编码器废掉时报这一条。这时候 `stop` 的 completion 还没交进来，
    /// 不给单独一条出口，浮层会一直挂在屏幕上等一个永远不会来的停止。
    var onFailure: ((String) -> Void)?
    private(set) var isRunning = false

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "net.mtjo.macstroke.screenshot.record")
    private var url: URL?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var encodedSize = CGSize.zero
    /// 出帧尺寸和编码尺寸对不上时用的中转缓冲（H.264 只吃偶数边长，见 `even(_:)`）。
    private var scratch: CVPixelBuffer?
    private var lastSeconds: TimeInterval = 0
    private var lastReported: TimeInterval = -1
    /// 真进了片的帧数。收带时用它判断「这一场到底有没有东西可写」：
    /// 一个样本都没收过的 input 状态还是 unknown，对它调 `markAsFinished` 会抛
    /// NSInvalidArgumentException（探针实测，Swift 拦不住 = 当场崩）。
    private var appendedCount = 0
    /// 停止流程只许走一次：点停止、再按快捷键、录满上限这三条路可能挤在同几毫秒里。
    private var finishing = false
    private var onFinish: ((ScreenshotRecordOutcome) -> Void)?

    /// 开始录制。`cropRect` 是**这块屏自己**的 AppKit 坐标（原点在该屏左下角，单位点），
    /// 由 `cropRect(viewRect:screenHeight:)` 从视图坐标换算出来。
    func start(displayID: CGDirectDisplayID, cropRect: CGRect, url: URL,
               completion: @escaping (String?) -> Void) {
        guard !isRunning else { completion(L("Screenshot record busy")); return }
        guard cropRect.width >= 2, cropRect.height >= 2 else {
            completion(L("Screenshot record too small")); return
        }
        guard let screenInput = AVCaptureScreenInput(displayID: displayID) else {
            completion(L("Screenshot record no display")); return
        }
        screenInput.cropRect = cropRect
        screenInput.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        screenInput.capturesCursor = capturesCursor
        guard session.canAddInput(screenInput) else {
            completion(L("Screenshot record no display")); return
        }
        session.addInput(screenInput)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            completion(L("Screenshot record no display")); return
        }
        session.addOutput(output)

        beginFile(at: url)
        NSLog("%@", "[ScreenshotRecord] 起录：屏 \(displayID) 区域 \(cropRect.integral) "
            + "\(frameRate)fps，指针\(capturesCursor ? "进" : "不进")画面")
        // startRunning 是阻塞调用，Apple 明确要求别在主线程上头跑。
        queue.async { [weak self] in
            guard let self else { return }
            self.session.startRunning()
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// 把出片路径摆好（编码器要到第一帧才知道宽高，所以这里只记 URL）。
    ///
    /// 真链路在 `start()` 里调；单测直接调它再喂合成帧 —— `AVCaptureScreenInput` 要
    /// 抓屏授权（测试进程永远拿不到），而 `AVAssetWriter` 什么授权都不要，于是
    /// `add(input)`、adaptor 的建法、时间戳、收带这几件事能在 `swift test` 里验完。
    func beginFile(at target: URL) {
        url = target
        isRunning = true
    }

    /// 停止并落盘。文件写完才回结局（收尾要几毫秒到几百毫秒，所以这条路是异步的）。
    func stop(completion: @escaping (ScreenshotRecordOutcome) -> Void) {
        guard isRunning else { completion(.empty); return }
        guard !finishing else { completion(.empty); return }
        finishing = true
        onFinish = completion
        NSLog("%@", "[ScreenshotRecord] 收带：已进片 \(appendedCount) 帧、"
            + String(format: "%.1f", lastSeconds) + " 秒")
        // 这里**必须**强引用 self，不能 `[weak self]`：
        // `setSampleBufferDelegate` 不持有代理，控制器一撒手（`self.recorder = nil`）
        // 唯一那根强引用就断了，而收带是异步的 —— 对象当场释放，writer 死在
        // `.writing` 状态，盘上留下一个只有 mdat、没有 moov 的 mp4（Finder 报
        // 「此媒体可能已损坏」、AVAsset 报 -11829 Cannot Open），completion 也永远不来。
        // 用户拿到的正是这一段：录了 20 秒、点停止、文件打不开。
        queue.async {
            // 会话压根没起过（编码器那一帧就废了、或单测直接喂帧）就别去停它。
            if !self.session.inputs.isEmpty { self.session.stopRunning() }
            self.finishWriting()
        }
    }

    /// 收带。一帧都没进片就 `cancelWriting()`：它会把那个 0 字节的空文件一起收掉，
    /// 否则用户桌面上会攒一排打不开的 mp4（这正是修复前留下的现场）。
    func finishWriting() {
        guard let writer, let videoInput else {
            reportEmpty()
            return
        }
        guard writer.status == .writing, appendedCount > 0 else {
            if writer.status == .writing { writer.cancelWriting() }
            reportEmpty()
            return
        }
        videoInput.markAsFinished()
        // 同样强引用 self：收带回调要几百毫秒才回来，期间控制器已经撒手，
        // weak 版会让这个对象在写 moov 之前就消失（上面 `stop` 的注释里有完整现场）。
        // 回调里 `reset()` 会把 writer 置 nil，这一圈临时引用随即断开。
        writer.finishWriting {
            self.isRunning = false
            let made = self.writer?.status == .completed
            let error = self.writer?.error?.localizedDescription
            let url = self.url
            let seconds = self.lastSeconds
            let frames = self.appendedCount
            self.reset()
            NSLog("%@", "[ScreenshotRecord] 收带完成：\(made ? "成片" : "失败") \(frames) 帧、"
                + String(format: "%.1f", seconds) + " 秒 → \(url?.lastPathComponent ?? "-")"
                + (error.map { "，error=\($0)" } ?? ""))
            DispatchQueue.main.async {
                if made, let url {
                    self.onFinish?(.saved(url: url, seconds: seconds))
                } else if let error, !error.isEmpty {
                    // 修复前这一支把 writer 的错误吞成了「一帧都没录到」，用户和我都看不到真因。
                    self.onFinish?(.failed(reason: error))
                } else {
                    self.onFinish?(.empty)
                }
            }
        }
    }

    private func reportEmpty() {
        // 这条日志不是可选项：走到这里的原因有好几种（writer 没建起来、状态是 failed、
        // 一帧都没进片），而「没有东西可写」对用户和我都是同一个词。真因只有 writer 自己
        // 知道，不打出来就只能靠猜 —— 修复前这里一句话都不说。
        NSLog("%@", "[ScreenshotRecord] 空场收带：writer=\(writer.map { "\($0.status.rawValue)" } ?? "无")"
            + " error=\(writer?.error?.localizedDescription ?? "-") 进片 \(appendedCount) 帧")
        isRunning = false
        reset()
        DispatchQueue.main.async { self.onFinish?(.empty) }
    }

    private func reset() {
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        writer = nil
        videoInput = nil
        adaptor = nil
        startTime = nil
        scratch = nil
        encodedSize = .zero
        lastSeconds = 0
        lastReported = -1
        appendedCount = 0
        finishing = false
    }

    /// 区域从视图坐标（flipped，原点该屏**左上**）换到该屏 AppKit 坐标（原点左下）。
    /// 只翻 y、x 不动；`screenHeight` 由调用方给，单测不用真找一块屏。
    static func cropRect(viewRect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: viewRect.minX.rounded(.down), y: (screenHeight - viewRect.maxY).rounded(.down),
               width: viewRect.width.rounded(.down), height: viewRect.height.rounded(.down))
    }

    /// 编码码率。经验值：每像素每帧约 0.1 bit，再夹进一个不会把盘写爆的区间。
    static func bitrate(width: Int, height: Int, frameRate: Int32) -> Int {
        let raw = Double(width * height) * Double(frameRate) * 0.1
        return Int(min(max(raw, 2_000_000), 40_000_000))
    }

    /// H.264 只吃偶数边长，奇数会让 `startWriting` 直接失败（实测过的那类 -11800 错）。
    static func even(_ value: Int) -> Int { value % 2 == 0 ? value : value - 1 }

    /// 到第一帧才建 writer：宽高取**实际出帧**的尺寸，而不是自己按 scale 推算。
    /// Retina、缩放分辨率、奇数边长这三种情况都在这一步被真实值兜住。
    private func setupWriter(with buffer: CVPixelBuffer, at pts: CMTime) -> Bool {
        guard let url else { return false }
        let width = Self.even(CVPixelBufferGetWidth(buffer))
        let height = Self.even(CVPixelBufferGetHeight(buffer))
        guard width >= 2, height >= 2 else { return false }
        guard let made = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitrate(width: width, height: height,
                                                       frameRate: frameRate),
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate) * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        // 下面三步的顺序是硬的，错一步就是一条**静默**的坏路（都在探针上实测过）：
        // ① `add(input)` 不能漏。只 `canAdd` 不 `add`，writer 就没有轨道，
        //    `isReadyForMoreMediaData` 永远 false → 一帧都进不去 → 时长不走、
        //    停止后盘上是个 0 字节文件（用户报的就是这个）。
        // ② adaptor 必须在 `startWriting()` **之前**建。之后建会抛
        //    NSInvalidArgumentException（"input has already started writing"），
        //    Swift 拦不住 ObjC 异常 = 当场崩。①没修的时候这条不响，修了①才会撞上。
        // ③ `startSession` 的起点用第一帧的 PTS，喂帧时也必须用原始 PTS，见 `ingest`。
        guard made.canAdd(input) else { return false }
        made.add(input)
        let madeAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard made.startWriting() else { return false }
        made.startSession(atSourceTime: pts)
        self.writer = made
        self.videoInput = input
        self.adaptor = madeAdaptor
        self.encodedSize = CGSize(width: width, height: height)
        self.startTime = pts
        self.lastSeconds = 0
        NSLog("%@", "[ScreenshotRecord] 编码器起来：\(width)×\(height) → \(url.lastPathComponent)")
        return true
    }

    /// 喂一帧进编码器，第一帧顺便把 writer 建起来。`captureOutput` 和单测都走这里。
    func ingest(_ raw: CVPixelBuffer, at pts: CMTime) -> ScreenshotIngest {
        guard isRunning, !finishing else { return .dropped }
        if writer == nil, !setupWriter(with: raw, at: pts) { return .broken }
        guard let adaptor, videoInput?.isReadyForMoreMediaData == true else { return .dropped }
        guard let buffer = normalized(buffer: raw) else { return .dropped }
        // 时间戳用采集给的那个**原值**，不要重算成「从 0 起的相对时间」：
        // `startSession(atSourceTime:)` 的起点就是第一帧的 PTS（mach 绝对时间，几万秒量级），
        // 比它早的样本会被 writer 整个丢掉 —— 探针实测同一批 30 帧，重算到 0 出来的是
        // 「时长 0.0 秒、只读回 2 帧」的坏片，原始 PTS 才是 1.0 秒。
        guard adaptor.append(buffer, withPresentationTime: pts) else { return .dropped }
        appendedCount += 1
        guard let base = startTime else { return .appended(seconds: 0) }
        var seconds = CMTimeGetSeconds(CMTimeSubtract(pts, base))
        if seconds.isNaN || seconds < 0 { seconds = lastSeconds }
        lastSeconds = seconds
        // 读数一秒回一次就够：胶囊上的数字是给人眼看的，逐帧刷只会让字跳。
        if Int(seconds) > Int(lastReported) {
            lastReported = seconds
            DispatchQueue.main.async { self.onTick?(seconds) }
        }
        return .appended(seconds: seconds)
    }

    /// 出帧尺寸和编码尺寸不一致（奇数被削掉一列/一行）时，把画面左上角原样搬进一块
    /// 固定尺寸的中转缓冲。只在这条少见的路上走，成本是一次逐行 memcpy。
    private func normalized(buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let target = encodedSize
        if CVPixelBufferGetWidth(buffer) == Int(target.width),
           CVPixelBufferGetHeight(buffer) == Int(target.height) { return buffer }
        if scratch == nil {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(target.width), Int(target.height),
                                kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
            scratch = made
        }
        guard let scratch else { return nil }
        let copyWidth = min(Int(target.width), CVPixelBufferGetWidth(buffer))
        let copyHeight = min(Int(target.height), CVPixelBufferGetHeight(buffer))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(scratch, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(scratch, [])
        }
        guard let source = CVPixelBufferGetBaseAddress(buffer),
              let destination = CVPixelBufferGetBaseAddress(scratch) else { return nil }
        let sourceRow = CVPixelBufferGetBytesPerRow(buffer)
        let destinationRow = CVPixelBufferGetBytesPerRow(scratch)
        for row in 0..<copyHeight {
            memcpy(destination + row * destinationRow, source + row * sourceRow, copyWidth * 4)
        }
        return scratch
    }
}

extension ScreenshotRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 丢帧不报：`alwaysDiscardsLateVideoFrames` 开着，编码跟不上时丢几帧是设计内。
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunning, !finishing,
              let raw = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        switch ingest(raw, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) {
        case .broken:
            failEncoder()
        case .dropped:
            break                       // 编码器忙：丢这一帧，下一帧再来
        case .appended(let seconds):
            // 读数由 `ingest` 报（它一秒回一次），这里只管录满上限自动收带。
            if seconds >= maxSeconds {
                finishing = true
                session.stopRunning()
                finishWriting()
            }
        }
    }

    /// 编码器这条路废了：停会话、把半成品文件收掉，再报出去。
    /// 还没人按停止时走 `onFailure`（`onFinish` 这时是 nil），否则浮层会永远挂着。
    private func failEncoder() {
        isRunning = false
        finishing = true
        session.stopRunning()
        if writer?.status == .writing { writer?.cancelWriting() }
        let reason = writer?.error?.localizedDescription ?? L("Screenshot record encoder failed")
        NSLog("%@", "[ScreenshotRecord] 编码器起不来/中途废掉：\(reason)")
        let completion = onFinish
        let failure = onFailure
        onFinish = nil
        onFailure = nil
        reset()
        DispatchQueue.main.async {
            if let completion {
                completion(.failed(reason: reason))
            } else {
                failure?(reason)
            }
        }
    }
}
