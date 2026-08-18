import Foundation
import XCTest
@testable import CodexBoard

@MainActor
final class CodexThreadReadTests: XCTestCase {
    func testParsesThreadReadResponseWithTurnsAndRecoverableFinalText() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "thread": {
            "id": "thread-1",
            "sessionId": "session-1",
            "cwd": "/srv/project",
            "name": "Remote task",
            "createdAt": 1700000000,
            "updatedAt": 1700000030,
            "status": {"type": "active"},
            "source": {"appServer": {}},
            "turns": [
              {
                "id": "turn-plan",
                "status": "completed",
                "startedAt": 1700000001,
                "completedAt": 1700000003,
                "durationMs": 2000,
                "items": [
                  {"id": "item-plan", "type": "plan", "text": "1. Inspect\n2. Implement"}
                ]
              },
              {
                "id": "turn-run",
                "status": "failed",
                "error": {"message": "remote process stopped"},
                "items": [
                  {"id": "item-command", "type": "commandExecution", "status": "failed"},
                  {"id": "item-agent", "type": "agentMessage", "text": "Partial result"}
                ]
              }
            ]
          }
        }
        """#.utf8))

        let detail = try CodexAppServerClient.parseThreadReadResponse(value)

        XCTAssertEqual(detail.summary.id, "thread-1")
        XCTAssertEqual(detail.summary.cwd, "/srv/project")
        XCTAssertEqual(detail.summary.statusType, "active")
        XCTAssertEqual(detail.summary.sourceKind, "appServer")
        XCTAssertEqual(detail.turns.count, 2)
        XCTAssertEqual(detail.turns[0].status, "completed")
        XCTAssertEqual(detail.turns[0].durationMilliseconds, 2_000)
        XCTAssertEqual(detail.turns[0].items.first?.text, "1. Inspect\n2. Implement")
        XCTAssertEqual(detail.turns[1].error, "remote process stopped")
        XCTAssertEqual(detail.turns[1].items.last?.type, "agentMessage")
        XCTAssertEqual(detail.turns[1].items.last?.text, "Partial result")
    }

    func testRejectsMalformedTurnInsteadOfSilentlyDroppingIt() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "thread": {
            "id": "thread-1",
            "sessionId": "session-1",
            "cwd": "/srv/project",
            "createdAt": 1700000000,
            "updatedAt": 1700000030,
            "status": {"type": "idle"},
            "source": "appServer",
            "turns": [{"id": "turn-1", "status": "completed", "items": [{"type": "plan"}]}]
          }
        }
        """#.utf8))

        XCTAssertThrowsError(try CodexAppServerClient.parseThreadReadResponse(value)) { error in
            XCTAssertEqual(error as? CodexClientError, .invalidResponse("thread/read 包含无效 turn"))
        }
    }

    func testRejectsMissingTurnsForFailClosedRecovery() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "thread": {
            "id": "thread-1",
            "sessionId": "session-1",
            "cwd": "/srv/project",
            "createdAt": 1700000000,
            "updatedAt": 1700000030,
            "status": {"type": "idle"},
            "source": "appServer"
          }
        }
        """#.utf8))

        XCTAssertThrowsError(try CodexAppServerClient.parseThreadReadResponse(value)) { error in
            XCTAssertEqual(error as? CodexClientError, .invalidResponse("thread/read 缺少 turns"))
        }
    }
}
