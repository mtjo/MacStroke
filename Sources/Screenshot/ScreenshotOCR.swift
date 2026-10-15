//
//  ScreenshotOCR.swift
//  MacStroke
//
//  「提取文字」：把选区里本来就有的字认出来，按行交回上层（上层写进剪贴板、弹一条提示）。
//  参照 QQ 条子上那枚虚线框 A，但只做薄的一层：不建结果面板 —— 那要另起一扇窗，而
//  「认出这些字」本身不需要 UI。
//
//  引擎是系统框架 Vision：本地推理、不联网、不引第三方依赖。识别的是**合成之后**的那张图
//  （和绿✓复制出去的同一张），所以用户自己写的文字注解也一起能被认出来。
//
//  部署水位线 macOS 13 之下，`VNRecognizeTextRequest`（10.15+）、`revision3`（13.0+）、
//  `recognitionLanguages` 里的 zh-Hans（11.0+）全都够用，所以整份代码不需要 availability
//  判断 —— 这点是「现在接代价很小」的主要理由。
//

import AppKit
import Vision

/// 一次识别的三种下场。「这块没字」和「压根没跑成」要分开：合并成一句的话，用户对着
/// 一张纯图按按钮和引擎真挂了，看到的反馈一模一样，就没法判断该换个选区还是该报 bug。
public enum ScreenshotTextOutcome {
    /// 认出来的行，自上而下。
    case lines([String])
    case nothing
    case failed(reason: String)
}

enum ScreenshotOCR {
    /// 中英混排这两路，Vision 按顺序自己挑，不用先判语言。
    static let languages = ["zh-Hans", "en-US"]

    /// 同步认一张图：会占住调用线程几百毫秒（整屏那一档到一秒上下），所以只给后台队列
    /// 和单测用，界面上走 `recognize`。
    static func text(from image: CGImage) -> ScreenshotTextOutcome {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        guard let observations = request.results else { return .nothing }
        // 归一化坐标原点在左下，所以 minY 越大越靠上。剪贴板里的行序是这张图交给用户的
        // 承诺，这里自己排一次，不靠上游返回的顺序。
        let ordered = observations.sorted {
            $0.boundingBox.minY != $1.boundingBox.minY
                ? $0.boundingBox.minY > $1.boundingBox.minY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        let lines = ordered.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? .nothing : .lines(lines)
    }

    /// 丢后台跑，回主线程交结果 —— 遮罩这期间还摊在屏幕上，不能冻住它。
    static func recognize(_ image: CGImage, completion: @escaping (ScreenshotTextOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = text(from: image)
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
