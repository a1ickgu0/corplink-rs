import XCTest
@testable import corplink_gui

final class DetectTriggerTests: XCTestCase {
    func testDetectTriggerPositive() {
        let line = "[INFO] 请在完成扫码验证后输入 'y' 继续\n"
        XCTAssertTrue(detectTrigger(in: line))
    }

    func testDetectTriggerExactString() {
        XCTAssertTrue(detectTrigger(in: "请在完成扫码验证后输入 'y' 继续"))
    }

    func testDetectTriggerNegative() {
        XCTAssertFalse(detectTrigger(in: "VPN连接成功 IP地址: 10.0.0.1"))
        XCTAssertFalse(detectTrigger(in: ""))
        XCTAssertFalse(detectTrigger(in: "some unrelated log"))
    }

    func testDetectTriggerSubstringOrderMatters() {
        // 缺少哪怕一个字符都不应触发。
        XCTAssertFalse(detectTrigger(in: "请在完成扫码验证后输入 'y'"))
        XCTAssertFalse(detectTrigger(in: "请在完成扫码验证后输入 'Y' 继续"))
    }

    func testDetectConnected() {
        XCTAssertTrue(detectConnected(in: "✅ [VPN连接成功] IP地址: 10.0.0.1"))
        XCTAssertTrue(detectConnected(in: "✅ [内网连接成功] 检测到内网环境"))
        XCTAssertFalse(detectConnected(in: "VPN keep alive failed"))
    }

    func testStatePredicates() {
        XCTAssertTrue(AppState.canConnect(.idle))
        XCTAssertTrue(AppState.canConnect(.error))
        XCTAssertFalse(AppState.canConnect(.connecting))
        XCTAssertFalse(AppState.canConnect(.connected))
        XCTAssertFalse(AppState.canConnect(.waitingScan))

        XCTAssertFalse(AppState.canDisconnect(.idle))
        XCTAssertFalse(AppState.canDisconnect(.error))
        XCTAssertTrue(AppState.canDisconnect(.connecting))
        XCTAssertTrue(AppState.canDisconnect(.connected))
        XCTAssertTrue(AppState.canDisconnect(.waitingScan))
    }
}
