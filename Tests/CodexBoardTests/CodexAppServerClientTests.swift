import XCTest
@testable import CodexBoard

@MainActor
final class CodexAppServerClientTests: XCTestCase {
    func testParseModelPreservesCatalogMetadataAndOpenReasoningEfforts() throws {
        let model = try XCTUnwrap(CodexAppServerClient.parseModel(.object([
            "id": .string("catalog-gpt-5.6-sol"),
            "model": .string("gpt-5.6-sol"),
            "displayName": .string("GPT-5.6 Sol"),
            "description": .string("Frontier coding model"),
            "isDefault": .bool(true),
            "defaultReasoningEffort": .string("ultra"),
            "supportedReasoningEfforts": .array([
                .object([
                    "reasoningEffort": .string("max"),
                    "description": .string("Maximum reasoning")
                ]),
                .object([
                    "reasoningEffort": .string("future-effort"),
                    "description": .string("A future server value")
                ])
            ]),
            "serviceTiers": .array([
                .object([
                    "id": .string("priority"),
                    "name": .string("Fast"),
                    "description": .string("Faster responses")
                ])
            ])
        ])))

        XCTAssertEqual(model.id, "catalog-gpt-5.6-sol")
        XCTAssertEqual(model.model, "gpt-5.6-sol")
        XCTAssertEqual(model.displayName, "GPT-5.6 Sol")
        XCTAssertEqual(model.description, "Frontier coding model")
        XCTAssertTrue(model.isDefault)
        XCTAssertEqual(model.defaultReasoningEffort.rawValue, "ultra")
        XCTAssertEqual(model.supportedReasoningEfforts.map(\.effort.rawValue), ["max", "future-effort"])
        XCTAssertEqual(model.supportedReasoningEfforts.map(\.description), ["Maximum reasoning", "A future server value"])
        XCTAssertEqual(model.serviceTiers, [
            CodexModelServiceTier(id: "priority", name: "Fast", description: "Faster responses")
        ])
        XCTAssertTrue(model.supportsFast)
    }

    func testParseModelDefaultsOptionalServiceTiersToEmpty() throws {
        let model = try XCTUnwrap(CodexAppServerClient.parseModel(.object([
            "id": .string("catalog-model"),
            "model": .string("model"),
            "displayName": .string("Model"),
            "description": .string("Description"),
            "isDefault": .bool(false),
            "defaultReasoningEffort": .string("medium"),
            "supportedReasoningEfforts": .array([])
        ])))

        XCTAssertEqual(model.serviceTiers, [])
        XCTAssertFalse(model.supportsFast)
    }

    func testParseModelRecognizesLegacyFastCapability() throws {
        let model = try XCTUnwrap(CodexAppServerClient.parseModel(.object([
            "id": .string("legacy-catalog-model"),
            "model": .string("legacy-model"),
            "displayName": .string("Legacy Model"),
            "description": .string("Uses the legacy speed capability field"),
            "isDefault": .bool(false),
            "defaultReasoningEffort": .string("medium"),
            "supportedReasoningEfforts": .array([]),
            "additionalSpeedTiers": .array([.string("fast")])
        ])))

        XCTAssertTrue(model.supportsFast)
        XCTAssertEqual(model.serviceTiers.map(\.id), [CodexServiceTier.fast])
    }

    func testParseModelRejectsMissingRequiredCatalogFields() {
        XCTAssertNil(CodexAppServerClient.parseModel(.object([
            "id": .string("catalog-model"),
            "model": .string("model")
        ])))
    }

    func testThreadStartParamsIncludeCamelCaseServiceTierAndSafetySettings() throws {
        let params = try XCTUnwrap(CodexAppServerClient.makeThreadStartParams(
            cwd: "/project",
            model: "gpt-5.6-sol",
            serviceTier: CodexServiceTier.fast
        ).objectValue)

        XCTAssertEqual(params["cwd"], .string("/project"))
        XCTAssertEqual(params["model"], .string("gpt-5.6-sol"))
        XCTAssertEqual(params["serviceTier"], .string("priority"))
        XCTAssertNil(params["service_tier"])
        XCTAssertEqual(params["approvalPolicy"], .string("never"))
        XCTAssertEqual(params["sandbox"], .string("read-only"))
        XCTAssertEqual(params["personality"], .string("pragmatic"))
        XCTAssertEqual(params["serviceName"], .string("codex_board"))
        XCTAssertEqual(params["ephemeral"], .bool(false))
        XCTAssertEqual(params["runtimeWorkspaceRoots"], .array([.string("/project")]))
    }

    func testThreadStartParamsOmitEmptyOptionalWireValues() throws {
        let params = try XCTUnwrap(CodexAppServerClient.makeThreadStartParams(
            cwd: "/project",
            model: "",
            serviceTier: ""
        ).objectValue)

        XCTAssertNil(params["model"])
        XCTAssertNil(params["serviceTier"])
    }

    func testPlanningTurnParamsSendExplicitStandardTierAndReadOnlySandbox() throws {
        let sandbox: JSONValue = .object([
            "type": .string("readOnly"),
            "networkAccess": .bool(false)
        ])
        let params = try XCTUnwrap(CodexAppServerClient.makeTurnStartParams(
            threadID: "thread-1",
            cwd: "/project",
            input: [.text("Plan this")],
            model: "gpt-5.6-sol",
            effort: .ultra,
            serviceTier: CodexServiceTier.standard,
            mode: "plan",
            sandboxPolicy: sandbox,
            approvalPolicy: "never"
        ).objectValue)

        XCTAssertEqual(params["threadId"], .string("thread-1"))
        XCTAssertEqual(params["input"], .array([.object([
            "type": .string("text"),
            "text": .string("Plan this")
        ])]))
        XCTAssertEqual(params["cwd"], .string("/project"))
        XCTAssertEqual(params["model"], .string("gpt-5.6-sol"))
        XCTAssertEqual(params["effort"], .string("ultra"))
        XCTAssertEqual(params["serviceTier"], .string("default"))
        XCTAssertNil(params["service_tier"])
        XCTAssertEqual(params["approvalPolicy"], .string("never"))
        XCTAssertEqual(params["sandboxPolicy"], sandbox)
        XCTAssertEqual(params["runtimeWorkspaceRoots"], .array([.string("/project")]))
        XCTAssertEqual(params["summary"], .string("concise"))
        XCTAssertEqual(params["personality"], .string("pragmatic"))
        XCTAssertEqual(params["collaborationMode"]?["mode"], .string("plan"))
        XCTAssertEqual(params["collaborationMode"]?["settings"]?["reasoning_effort"], .string("ultra"))
    }

    func testExecutionTurnParamsSendFastTierAndWorkspaceWriteSandbox() throws {
        let sandbox: JSONValue = .object([
            "type": .string("workspaceWrite"),
            "writableRoots": .array([.string("/project")]),
            "networkAccess": .bool(true),
            "excludeTmpdirEnvVar": .bool(true),
            "excludeSlashTmp": .bool(true)
        ])
        let params = try XCTUnwrap(CodexAppServerClient.makeTurnStartParams(
            threadID: "thread-1",
            cwd: "/project",
            input: [.localImage(path: "/project/image.png")],
            model: "gpt-5.6-sol",
            effort: .high,
            serviceTier: CodexServiceTier.fast,
            mode: "default",
            sandboxPolicy: sandbox,
            approvalPolicy: "never"
        ).objectValue)

        XCTAssertEqual(params["serviceTier"], .string("priority"))
        XCTAssertEqual(params["sandboxPolicy"], sandbox)
        XCTAssertEqual(params["collaborationMode"]?["mode"], .string("default"))
        XCTAssertEqual(params["input"], .array([.object([
            "type": .string("localImage"),
            "path": .string("/project/image.png")
        ])]))
    }

    func testTurnStartParamsOmitEmptyServiceTier() throws {
        let params = try XCTUnwrap(CodexAppServerClient.makeTurnStartParams(
            threadID: "thread-1",
            cwd: "/project",
            input: [.text("Execute")],
            model: "model",
            effort: .medium,
            serviceTier: "",
            mode: "default",
            sandboxPolicy: .object(["type": .string("readOnly")]),
            approvalPolicy: "never"
        ).objectValue)

        XCTAssertNil(params["serviceTier"])
    }

    func testConfigWarningMapsToNonBlockingConfigurationEvent() throws {
        let event = try XCTUnwrap(CodexAppServerClient.warningEvent(
            method: "configWarning",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "message": .string("Skills were shortened")
            ])
        ))

        guard case let .configurationWarning(threadID, turnID, message) = event else {
            return XCTFail("configWarning must map to configurationWarning")
        }
        XCTAssertEqual(threadID, "thread-1")
        XCTAssertEqual(turnID, "turn-1")
        XCTAssertEqual(message, "Skills were shortened")
    }

    func testRuntimeWarningsRemainBlockingWarningEvents() throws {
        for method in ["warning", "guardianWarning"] {
            let event = try XCTUnwrap(CodexAppServerClient.warningEvent(
                method: method,
                params: .object(["message": .string("Runtime warning")])
            ))

            guard case let .warning(threadID, turnID, message) = event else {
                return XCTFail("\(method) must remain a warning")
            }
            XCTAssertNil(threadID)
            XCTAssertNil(turnID)
            XCTAssertEqual(message, "Runtime warning")
        }
    }

    func testUnrelatedNotificationDoesNotMapToWarning() {
        XCTAssertNil(CodexAppServerClient.warningEvent(
            method: "turn/completed",
            params: .object([:])
        ))
    }
}
