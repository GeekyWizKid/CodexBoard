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
            "source": "appServer",
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

    func testThreadReadPreservesParentAndCollaborationForRecovery() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "thread": {
            "id": "child-1",
            "sessionId": "root-1",
            "parentThreadId": "root-1",
            "agentNickname": "Popper",
            "agentRole": "explorer",
            "cwd": "/srv/project",
            "createdAt": 1700000000,
            "updatedAt": 1700000030,
            "status": {"type": "idle"},
            "source": {
              "subAgent": {
                "thread_spawn": {
                  "parent_thread_id": "root-1",
                  "depth": 1,
                  "agent_path": "/root/protocol_events",
                  "agent_nickname": "Popper",
                  "agent_role": "explorer"
                }
              }
            },
            "turns": [
              {
                "id": "turn-1",
                "status": "completed",
                "items": [
                  {
                    "type": "collabAgentToolCall",
                    "id": "call-1",
                    "tool": "spawnAgent",
                    "status": "completed",
                    "senderThreadId": "root-1",
                    "receiverThreadIds": ["child-1"],
                    "prompt": "Audit protocol events",
                    "model": null,
                    "reasoningEffort": null,
                    "agentsStates": {
                      "child-1": {"status": "completed", "message": "done"}
                    }
                  },
                  {
                    "type": "subAgentActivity",
                    "id": "activity-1",
                    "agentThreadId": "child-1",
                    "agentPath": "/root/protocol_events",
                    "kind": "interrupted"
                  }
                ]
              }
            ]
          }
        }
        """#.utf8))

        let detail = try CodexAppServerClient.parseThreadReadResponse(value)

        XCTAssertEqual(detail.summary.parentThreadID, "root-1")
        XCTAssertEqual(detail.summary.agentNickname, "Popper")
        XCTAssertEqual(detail.summary.agentRole, "explorer")
        XCTAssertEqual(detail.summary.sourceKind, "subAgent")
        let collaboration = try XCTUnwrap(detail.turns.first?.items.first?.collaboration)
        XCTAssertEqual(collaboration.senderThreadID, "root-1")
        XCTAssertEqual(collaboration.receiverThreadIDs, ["child-1"])
        XCTAssertEqual(collaboration.agentStates["child-1"]?.status, "completed")
        XCTAssertEqual(collaboration.agentStates["child-1"]?.message, "done")
        let activity = try XCTUnwrap(detail.turns.first?.items.last?.subAgentActivity)
        XCTAssertEqual(activity.id, "activity-1")
        XCTAssertEqual(activity.agentThreadID, "child-1")
        XCTAssertEqual(activity.agentPath, "/root/protocol_events")
        XCTAssertEqual(activity.kind, "interrupted")
    }

    func testThreadReadRejectsMalformedCollaborationForFailClosedRecovery() throws {
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
            "turns": [
              {
                "id": "turn-1",
                "status": "completed",
                "items": [
                  {
                    "type": "collabAgentToolCall",
                    "id": "call-1",
                    "tool": "spawnAgent",
                    "status": "completed",
                    "senderThreadId": "thread-1",
                    "receiverThreadIds": ["child-1"]
                  }
                ]
              }
            ]
          }
        }
        """#.utf8))

        XCTAssertThrowsError(try CodexAppServerClient.parseThreadReadResponse(value)) { error in
            XCTAssertEqual(error as? CodexClientError, .invalidResponse("thread/read 包含无效 turn"))
        }
    }

    func testThreadReadRejectsMalformedParentThreadIDForFailClosedRecovery() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "thread": {
            "id": "thread-1",
            "sessionId": "session-1",
            "parentThreadId": 42,
            "cwd": "/srv/project",
            "createdAt": 1700000000,
            "updatedAt": 1700000030,
            "status": {"type": "idle"},
            "source": "appServer",
            "turns": []
          }
        }
        """#.utf8))

        XCTAssertThrowsError(try CodexAppServerClient.parseThreadReadResponse(value)) { error in
            XCTAssertEqual(error as? CodexClientError, .invalidResponse("thread/read 缺少有效 thread"))
        }
    }

    func testThreadReadRejectsMalformedSubAgentActivityForFailClosedRecovery() throws {
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
            "turns": [
              {
                "id": "turn-1",
                "status": "completed",
                "items": [
                  {
                    "type": "subAgentActivity",
                    "id": "activity-1",
                    "agentThreadId": "child-1",
                    "kind": "started"
                  }
                ]
              }
            ]
          }
        }
        """#.utf8))

        XCTAssertThrowsError(try CodexAppServerClient.parseThreadReadResponse(value)) { error in
            XCTAssertEqual(error as? CodexClientError, .invalidResponse("thread/read 包含无效 turn"))
        }
    }
}
