//
//  ShortcutMonitorHealthTests.swift
//
//  全局快捷键 tap 被系统停用后的巡检口径。坏掉的那一档是「isMonitoring 还是
//  true，但一个键都收不到」，用户只能重启 App —— 所以判据只能押在「巡检决定
//  该做什么」这张表上，不能靠真 tap（本机测试进程没有输入监控权限）。
//

import XCTest

@testable import EventCapture

final class ShortcutMonitorHealthTests: XCTestCase {

    func testIdleMonitorHealthCheckIsNoOp() {
        let monitor = ShortcutMonitor()
        monitor.checkHealth()
        XCTAssertFalse(monitor.isMonitoring, "没在监听就不该被巡检拉起")
        XCTAssertNil(monitor.keyCode)
    }

    func testStartWithoutShortcutStaysIdle() {
        let monitor = ShortcutMonitor()
        XCTAssertFalse(monitor.start())
        monitor.checkHealth()
        XCTAssertFalse(monitor.isMonitoring)
    }

    // MARK: - 判定表

    func testHealthActionMatrix() {
        XCTAssertEqual(
            ShortcutMonitor.healthAction(hasTap: false, portIsValid: false, tapIsEnabled: false),
            .rebuild, "没有 tap 只能整只重建")
        XCTAssertEqual(
            ShortcutMonitor.healthAction(hasTap: false, portIsValid: true, tapIsEnabled: true),
            .rebuild, "「端口有效但拿不到 tap」不能信，仍按重建走")
        XCTAssertEqual(
            ShortcutMonitor.healthAction(hasTap: true, portIsValid: false, tapIsEnabled: true),
            .rebuild, "端口已废：打开它没用，必须重建")
        XCTAssertEqual(
            ShortcutMonitor.healthAction(hasTap: true, portIsValid: true, tapIsEnabled: false),
            .reEnable, "只被系统关了：原地打开即可，重建会丢掉已有的录制状态")
        XCTAssertEqual(
            ShortcutMonitor.healthAction(hasTap: true, portIsValid: true, tapIsEnabled: true),
            .ok, "健康时巡检不许动 tap")
    }
}
