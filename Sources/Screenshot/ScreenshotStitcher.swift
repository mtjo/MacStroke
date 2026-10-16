//
//  ScreenshotStitcher.swift
//
//  长截图的拼接数学：把「滚动之后又抓了一帧」接回已经攒好的那张长图上。
//
//  为什么不能按注入的滚动量硬算：我们确实知道自己让滚轮走了多少（滚动条事件是按像素
//  发的），但落到被截的那个 App 里就不一定了 —— 网页有惯性、列表有一页一页跳、到底了
//  还会不动。所以滚动量只当**先验**（先在它附近找），真正认账的是画面自己。
//
//  认法：给每一行算一条「行指纹」（这一行横向压成 columns 列的 RGB），然后找一个位移 s，
//  使新帧的前 (h-s) 行和旧帧的后 (h-s) 行逐行对得上 —— 对上了就说明页面往下走了 s 个像素，
//  新帧最后那 s 行是没拼进去的新内容。这套在纯色/大图背景上会出现「谁都对得上」的歧义，
//  所以候选是有顺序的：先验附近 → 粗扫 → 精修，并要求重合段够长。
//
//  已知会让它认输的画面（认输=停止拼接、把已经拿到的部分出图，不硬拼）：
//  - 吸顶/吸底工具栏：那一块每帧都一样，会把整段的行指纹拉平；
//  - 内容本身在动（视频、跑马灯）：两帧的同一行永远对不上；
//  - 一次滚超过一屏：重合不足 minOverlap，判「对不上」。
//  同类工具（QQ/钉钉）在这几种画面上一样的表现，不是这里的额外缺陷。
//

import CoreGraphics
import Foundation

/// 一帧画面的逐行指纹：高度按原样保留（一行 = 一个像素行），宽度压成 `columns` 列。
///
/// 压宽度而不是压高度是必须的：位移要以**像素行**为单位算，高度一比一才数得准；
/// 宽度只是用来描述「这一行长什么样」，64 列足够区分了。
struct ScreenshotRowPrint {
    let columns: Int
    let rows: Int
    /// rows × columns × 3（RGB，逐行逐列铺开）。
    let bytes: [UInt8]

    /// 把一帧画进 `columns × rows` 的位图再读字节。插值取 `.medium`：降采样要的是
    /// 这一行的平均色，取 `.none` 就变成随机抽一列，字体的抗锯齿边缘会把指纹抖散。
    static func capture(_ image: CGImage, columns: Int = 64) -> ScreenshotRowPrint? {
        let width = max(1, min(columns, image.width))
        let height = image.height
        guard height > 0, width > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        // 不用翻 y：位图缓冲的第 0 行就是画面的顶行（实测：往缓冲第 0 行写红，
        // 再 makeImage 出来 `cropping(to: y=0)` 读回的还是红）。所以读回来的行序和
        // 帧自己的行序同向，位移 s 的符号才和「页面往下走」一致。
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let source = data.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        for index in 0..<(width * height) {
            rgb.append(source[index * 4])
            rgb.append(source[index * 4 + 1])
            rgb.append(source[index * 4 + 2])
        }
        return ScreenshotRowPrint(columns: width, rows: height, bytes: rgb)
    }

    /// 两行指纹的平均绝对差（0…255）。同一列同同一通道各比一次，再取平均。
    func meanDifference(atRow row: Int, to other: ScreenshotRowPrint, atRow otherRow: Int) -> Double {
        guard columns == other.columns,
              row >= 0, row < rows, otherRow >= 0, otherRow < other.rows else { return 255 }
        let width = columns * 3
        let a = row * width
        let b = otherRow * width
        var sum = 0
        for column in 0..<width {
            sum += abs(Int(bytes[a + column]) - Int(other.bytes[b + column]))
        }
        return Double(sum) / Double(width)
    }
}

enum ScreenshotStitcher {
    /// 重合段至少要这么多行对得上，否则「对上了」这件事本身没有说服力（两张只重合
    /// 三行的图，随便什么噪声都能凑出一次假命中）。
    static let minOverlap: Int = 40
    /// 两行指纹的平均绝对差低于这个值才算同一行。取值来自合成图的实测：同一行 0，
    /// 隔一行差几十，字体边缘的抗锯齿抖动落在个位数。
    static let tolerance: Double = 6
    /// 先验（注入的滚动量）附近精搜的范围。
    static let priorWindow: Int = 12
    /// 粗扫的行采样步长：一帧一千多行，逐行比会白烧几十倍 CPU。
    static let screenStride: Int = 4

    /// 新帧相对旧帧向下滚了多少像素。
    ///
    /// - Parameter expected: 我们注入的滚动量（像素），只当先验：先在它附近找，
    ///   找不到再全表粗扫 + 精修。传 nil 就是直接全表找。
    /// - Returns: 0 = 画面没动（到底了）；nil = 对不上，别硬拼。
    static func shift(previous: ScreenshotRowPrint, next: ScreenshotRowPrint,
                      expected: Int?, tolerance: Double = tolerance,
                      minOverlap: Int = minOverlap) -> Int? {
        guard previous.columns == next.columns, previous.rows == next.rows else { return nil }
        let height = previous.rows
        // 一帧都没动：整帧逐行对得上。放在最前面，因为这是停止条件而不是拼接量。
        if meanDifference(previous: previous, next: next, shift: 0, stride: screenStride) <= tolerance {
            return 0
        }
        let maxShift = max(0, height - minOverlap)
        guard maxShift > 0 else { return nil }

        // 1) 先验附近逐候选精搜：注入量大概率是对的，这条路最便宜也最准。
        if let expected, expected > 0, expected <= maxShift {
            let low = max(1, expected - priorWindow)
            let high = min(maxShift, expected + priorWindow)
            var best: (shift: Int, mean: Double)?
            for candidate in low...high {
                let mean = meanDifference(previous: previous, next: next, shift: candidate, stride: 1)
                if mean <= tolerance { return candidate }
                if best == nil || mean < best!.mean { best = (candidate, mean) }
            }
            if let best, best.mean <= tolerance { return best.shift }
        }

        // 2) 全表粗扫挑最小，3) 在它左右逐行精修。粗扫必须**每个位移都试**：
        // 画面是逐行的离散内容，错位一行的平均差是几十，按步长跳过候选会把真答案漏掉
        // （滚 30 行却只扫 1、5、9…29、33 的话，最小值落在噪声上，精修也找不回来）。
        // 省 CPU 靠的是每个候选只抽样比对 `screenStride` 行，不是少试几个候选。
        var best: (shift: Int, mean: Double)?
        var candidate = 1
        while candidate <= maxShift {
            let mean = meanDifference(previous: previous, next: next, shift: candidate, stride: screenStride)
            if best == nil || mean < best!.mean { best = (candidate, mean) }
            candidate += 1
        }
        guard let coarse = best else { return nil }
        let low = max(1, coarse.shift - screenStride)
        let high = min(maxShift, coarse.shift + screenStride)
        var refined: (shift: Int, mean: Double)?
        for candidate in low...high {
            let mean = meanDifference(previous: previous, next: next, shift: candidate, stride: 1)
            if refined == nil || mean < refined!.mean { refined = (candidate, mean) }
        }
        guard let fine = refined, fine.mean <= tolerance else { return nil }
        return fine.shift
    }

    /// 位移 s 下的平均行差：新帧第 j 行对旧帧第 (j+s) 行，j 从 0 走到 (h-s-minOverlap)。
    static func meanDifference(previous: ScreenshotRowPrint, next: ScreenshotRowPrint,
                               shift: Int, stride: Int) -> Double {
        guard previous.columns == next.columns, previous.rows == next.rows else { return 255 }
        let height = previous.rows
        let last = height - shift
        guard last > 0 else { return 255 }
        var sum = 0.0
        var count = 0
        var row = 0
        while row < last {
            sum += next.meanDifference(atRow: row, to: previous, atRow: row + shift)
            count += 1
            row += max(1, stride)
        }
        guard count > 0 else { return 255 }
        return sum / Double(count)
    }

    /// 把各帧按它们在长图里的**顶行行号**铺成一张图。
    ///
    /// `top` 是这一帧第一行落在长图上的行号（0 = 最上面那行内容）。坐标在上下文里要翻
    /// 一次：CG 的位图上下文是左下原点，而帧行序是左上原点。
    static func compose(_ frames: [(image: CGImage, top: Int)], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        for entry in frames {
            let image = entry.image
            guard image.width > 0, image.height > 0 else { continue }
            let y = height - entry.top - image.height
            context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
        }
        return context.makeImage()
    }
}
