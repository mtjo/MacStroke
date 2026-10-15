//
//  ScreenshotRule.swift
//  MacStroke
//
//  截图功能的手势触发（移植版新增，超出原版）：一条动作是「截图」的普通规则，
//  默认挂在 S 预设手势上。走规则这条路是为了复用整套匹配管线 —— 应用过滤、最低分
//  门槛、缩略图、屏幕录制 —— 而不是在偏好层再抄一份 DTW 判定。
//

import Foundation
import GestureEngine

extension RuleStore {
    /// 规则名同时是规则表里的行身份，所以不能跟着界面语言变。
    public static let screenshotRuleName = "Screenshot"

    /// 默认手势的截图规则：画一个 S 弹选区。
    public static func screenshotRule() -> Rule {
        Rule(
            name: screenshotRuleName,
            description: "Take a screenshot",
            template: GestureTemplate(from: PresetGesture.letterS.template, name: "S Shape"),
            minSimilarityScore: 30.0,
            action: .screenshot,
            // 提示气泡留空：遮罩摊开本身就是反馈，再叠一条提示是干扰。
            note: "",
            filter: "*"
        )
    }

    /// 把截图规则放回列表末尾，已存在就不动 —— 升级迁移和截图页的「绘制手势」走的
    /// 是同一条路，两条路进来的位置要一致。
    /// - Returns: true 当本次真的新增了规则。
    @discardableResult
    public func installScreenshotRule() -> Bool {
        guard !rules.contains(where: { $0.name == Self.screenshotRuleName }) else { return false }
        rules.append(Self.screenshotRule())
        save()
        return true
    }

    /// 老用户的 rules.json 里没有这条规则，首次带上截图功能时补一条。只跑一次 ——
    /// 用户之后在规则表里删掉它，下次启动不该复活（要用的话截图页的「绘制手势」
    /// 会重新建一条）。
    /// - Returns: true 当本次真的新增了规则。
    @discardableResult
    public func installScreenshotRuleIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let markerKey = "screenshotGestureRuleInstalled"
        guard !defaults.bool(forKey: markerKey) else { return false }
        defaults.set(true, forKey: markerKey)
        return installScreenshotRule()
    }
}
