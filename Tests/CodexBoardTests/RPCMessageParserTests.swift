import XCTest
@testable import CodexBoard

final class RPCMessageParserTests: XCTestCase {
    func testParsesResponseWithoutJSONRPCHeader() throws {
        let message = try RPCMessageParser().parse(Data(#"{"id":7,"result":{"ok":true}}"#.utf8))
        XCTAssertEqual(message.id?.intValue, 7)
        XCTAssertEqual(message.result?["ok"]?.boolValue, true)
        XCTAssertNil(message.method)
    }

    func testParsesStreamingNotification() throws {
        let data = Data(#"{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"u","delta":"hello"}}"#.utf8)
        let message = try RPCMessageParser().parse(data)
        XCTAssertEqual(message.method, "item/agentMessage/delta")
        XCTAssertEqual(message.params?["delta"]?.stringValue, "hello")
    }
}
