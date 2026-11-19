import Foundation
import XCTest
@testable import Pers

@MainActor
final class SessionQueueTests: XCTestCase {
    private func event(parent: String?) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "parent_tool_use_id": parent.map { $0 as Any } ?? NSNull(),
            "message": ["role": "assistant", "content": [["type": "text", "text": "working"]]],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A background agent keeps talking after the turn's result; that mustn't hold new messages in the queue.
    func testSubagentEventsDontMakeTheTabBusy() {
        let session = Session(directory: NSTemporaryDirectory())
        _ = session.handle(line: event(parent: "toolu_background_agent"))
        XCTAssertFalse(session.isBusy)
    }

    /// A message sent with SEND NOW after Claude's last step gets a turn of its own, which starts with a fresh init.
    func testInitMakesTheTabBusy() {
        let session = Session(directory: NSTemporaryDirectory())
        _ = session.handle(line: #"{"type":"system","subtype":"init","session_id":"abc"}"#)
        XCTAssertTrue(session.isBusy)
    }

    func testTopLevelEventsMakeTheTabBusy() {
        let session = Session(directory: NSTemporaryDirectory())
        _ = session.handle(line: event(parent: nil))
        XCTAssertTrue(session.isBusy)
    }
}
