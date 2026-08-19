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

    func testParseSkillsListUsesInterfaceSummaryAndSafeDefaults() throws {
        let skills = try CodexAppServerClient.parseSkillsListResponse(.object([
            "data": .array([
                .object([
                    "cwd": .string("/project"),
                    "skills": .array([
                        .object([
                            "name": .string("review"),
                            "description": .string("Review changes"),
                            "shortDescription": .string("Legacy summary"),
                            "interface": .object([
                                "shortDescription": .string("Preferred summary")
                            ]),
                            "path": .string("/project/.agents/skills/review/SKILL.md"),
                            "scope": .string("repo"),
                            "enabled": .bool(true),
                            "futureField": .string("ignored")
                        ]),
                        .object([
                            "name": .string("safe-defaults"),
                            "path": .string("/skills/safe-defaults/SKILL.md")
                        ]),
                        .object(["name": .string("missing-path")])
                    ]),
                    "errors": .array([])
                ])
            ])
        ]))

        let projectSkills = try XCTUnwrap(skills["/project"])
        XCTAssertEqual(projectSkills.count, 2)
        XCTAssertEqual(projectSkills[0].name, "review")
        XCTAssertEqual(projectSkills[0].shortDescription, "Preferred summary")
        XCTAssertEqual(projectSkills[0].scope, "repo")
        XCTAssertTrue(projectSkills[0].enabled)
        XCTAssertEqual(projectSkills[1].description, "")
        XCTAssertNil(projectSkills[1].shortDescription)
        XCTAssertEqual(projectSkills[1].scope, "unknown")
        XCTAssertFalse(projectSkills[1].enabled)
    }

    func testCatalogRequestParamsUseExactExperimentalAPIFields() throws {
        XCTAssertEqual(CodexAppServerClient.makeSkillsListParams(
            cwds: ["/one", "/two"],
            forceReload: true
        ), .object([
            "cwds": .array([.string("/one"), .string("/two")]),
            "forceReload": .bool(true)
        ]))

        XCTAssertEqual(CodexAppServerClient.makeAppsListParams(
            cursor: nil,
            forceRefetch: true
        ), .object([
            "limit": .integer(100),
            "forceRefetch": .bool(true)
        ]))
        XCTAssertEqual(CodexAppServerClient.makeAppsListParams(
            cursor: "next-page",
            forceRefetch: false
        ), .object([
            "limit": .integer(100),
            "cursor": .string("next-page")
        ]))
        XCTAssertEqual(CodexAppServerClient.makeAppsInstalledParams(forceRefresh: true), .object([
            "forceRefresh": .bool(true)
        ]))
        XCTAssertEqual(CodexAppServerClient.makeAppsListParams(
            cursor: nil,
            forceRefetch: true,
            threadID: "thread-1"
        ), .object([
            "limit": .integer(100),
            "forceRefetch": .bool(true),
            "threadId": .string("thread-1")
        ]))
        XCTAssertEqual(CodexAppServerClient.makeAppsInstalledParams(
            forceRefresh: true,
            threadID: "thread-1"
        ), .object([
            "forceRefresh": .bool(true),
            "threadId": .string("thread-1")
        ]))
        XCTAssertEqual(CodexAppServerClient.makeAppsReadParams(appIDs: ["app-1"]), .object([
            "appIds": .array([.string("app-1")]),
            "includeTools": .bool(true)
        ]))
    }

    func testAppReadIDsAreBatchedAtProtocolLimit() {
        let appIDs = (0..<205).map { "app-\($0)" }
        let batches = CodexAppServerClient.appIDBatches(appIDs)

        XCTAssertEqual(batches.map(\.count), [100, 100, 5])
        XCTAssertEqual(batches.flatMap { $0 }, appIDs)
        XCTAssertEqual(CodexAppServerClient.appIDBatches([]), [])
    }

    func testAppResponsesMergeCanonicalMetadataAndRuntimeState() throws {
        let listed = try CodexAppServerClient.parseAppListResponse(.object([
            "data": .array([
                .object([
                    "id": .string("app-1"),
                    "name": .string("Catalog Name"),
                    "description": .string("Catalog description"),
                    "isAccessible": .bool(true),
                    "isEnabled": .bool(true)
                ]),
                .object([
                    "id": .string("hidden-app"),
                    "name": .string("Hidden"),
                    "isAccessible": .bool(false)
                ]),
                .object([
                    "id": .string("catalog-only"),
                    "name": .string("Catalog Only"),
                    "isAccessible": .bool(true),
                    "isEnabled": .bool(false)
                ]),
                .object(["id": .string("missing-name")])
            ]),
            "nextCursor": .string("page-2"),
            "futureField": .bool(true)
        ]))
        let installed = try CodexAppServerClient.parseAppsInstalledResponse(.object([
            "apps": .array([
                .object([
                    "id": .string("app-1"),
                    "enabled": .bool(false),
                    "callable": .bool(true),
                    "runtimeName": .string("runtime_app")
                ]),
                .object([
                    "id": .string("safe-runtime-defaults")
                ])
            ])
        ]))
        let metadata = try CodexAppServerClient.parseAppsReadResponse(.object([
            "apps": .array([
                .object([
                    "id": .string("app-1"),
                    "name": .string("Canonical Name"),
                    "description": .string("Canonical description"),
                    "toolSummaries": .array([
                        .object([
                            "name": .string("search"),
                            "title": .string("Search"),
                            "description": .string("Search records"),
                            "isEnabled": .bool(true),
                            "isReadOnly": .bool(true),
                            "disabledReason": .null
                        ]),
                        .object([
                            "name": .string("future-defaults")
                        ]),
                        .object(["description": .string("missing name")])
                    ]),
                    "futureField": .string("ignored")
                ])
            ]),
            "missingAppIds": .array([])
        ]))

        XCTAssertEqual(listed.nextCursor, "page-2")
        XCTAssertEqual(listed.apps.count, 3)
        XCTAssertFalse(installed[1].isEnabled)
        XCTAssertFalse(installed[1].isCallable)

        let apps = CodexAppServerClient.mergeApps(
            listed: listed.apps,
            installed: installed,
            metadata: metadata
        )
        XCTAssertEqual(apps.map(\.id), ["app-1", "catalog-only"])

        let app = apps[0]
        XCTAssertEqual(app.name, "Canonical Name")
        XCTAssertEqual(app.invocationName, "runtime_app")
        XCTAssertEqual(app.description, "Canonical description")
        XCTAssertTrue(app.isAccessible)
        XCTAssertFalse(app.isEnabled)
        XCTAssertTrue(app.isCallable)
        XCTAssertEqual(app.tools.count, 2)
        XCTAssertTrue(app.tools[0].isEnabled)
        XCTAssertTrue(app.tools[0].isReadOnly)
        XCTAssertEqual(app.tools[1].description, "")
        XCTAssertTrue(app.tools[1].isEnabled)
        XCTAssertFalse(app.tools[1].isReadOnly)

        XCTAssertEqual(apps[1].name, "Catalog Only")
        XCTAssertEqual(apps[1].invocationName, "Catalog Only")
        XCTAssertFalse(apps[1].isEnabled)
        XCTAssertFalse(apps[1].isCallable)
        XCTAssertEqual(apps[1].tools, [])
    }

    func testSkillAndMentionInputsUseExactWireShape() {
        XCTAssertEqual(CodexTurnInput.skill(
            name: "review",
            path: "/project/.agents/skills/review/SKILL.md"
        ).wireValue, .object([
            "type": .string("skill"),
            "name": .string("review"),
            "path": .string("/project/.agents/skills/review/SKILL.md")
        ]))
        XCTAssertEqual(CodexTurnInput.mention(
            name: "Linear",
            path: "app://linear"
        ).wireValue, .object([
            "type": .string("mention"),
            "name": .string("Linear"),
            "path": .string("app://linear")
        ]))
    }

    func testInitializeAdvertisesExperimentalAPIAndOpenAIFormExtension() throws {
        let params = try XCTUnwrap(CodexAppServerClient.makeInitializeParams(version: "1.2.3").objectValue)

        XCTAssertEqual(params["clientInfo"]?["name"], .string("codex_board"))
        XCTAssertEqual(params["clientInfo"]?["version"], .string("1.2.3"))
        XCTAssertEqual(params["capabilities"]?["experimentalApi"], .bool(true))
        XCTAssertEqual(params["capabilities"]?["extensions"]?["openai/form"], .object([:]))
    }

    func testRequestIDsPreserveIntegerAndStringWireTypes() {
        XCTAssertEqual(CodexAppServerClient.parseRequestID(.integer(42)), .integer(42))
        XCTAssertEqual(CodexAppServerClient.parseRequestID(.string("request-42")), .string("request-42"))
        XCTAssertNil(CodexAppServerClient.parseRequestID(.number(42)))
        XCTAssertEqual(CodexAppServerClient.wireValue(for: .integer(42)), .integer(42))
        XCTAssertEqual(CodexAppServerClient.wireValue(for: .string("request-42")), .string("request-42"))
    }

    func testCommandApprovalParsesSafeFieldsAndValidatesDecision() throws {
        let request = try XCTUnwrap(CodexAppServerClient.parseInteractionRequest(
            id: .integer(7),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .integer(1_750_000_000_000),
                "command": .string("git status --short"),
                "cwd": .string("/project"),
                "reason": .string("Inspect worktree"),
                "commandActions": .array([.object(["type": .string("unknown")])]),
                "additionalPermissions": .object([
                    "network": .object(["enabled": .bool(true)])
                ]),
                "availableDecisions": .array([.string("accept"), .string("decline")])
            ]),
            receivedAt: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(request.id, .integer(7))
        XCTAssertEqual(request.createdAt, Date(timeIntervalSince1970: 1_750_000_000))
        guard case let .commandApproval(approval) = request.kind else {
            return XCTFail("Expected command approval")
        }
        XCTAssertEqual(approval.command, "git status --short")
        XCTAssertEqual(approval.cwd, "/project")
        XCTAssertEqual(approval.availableDecisions, [.accept, .decline])
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "item/commandExecution/requestApproval",
            request: request,
            response: .approval(.decline)
        ), .object(["decision": .string("decline")]))
        XCTAssertThrowsError(try CodexAppServerClient.makeInteractionResponse(
            method: "item/commandExecution/requestApproval",
            request: request,
            response: .approval(.cancel)
        ))
    }

    func testCommandApprovalParsesAndEncodesCodexSessionAndPolicyChoices() throws {
        let execAmendment = ["git", "status"]
        let networkAmendment = CodexNetworkPolicyAmendment(host: "api.example.com", action: .allow)
        let request = try XCTUnwrap(CodexAppServerClient.parseInteractionRequest(
            id: .string("policy-request"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-policy"),
                "startedAtMs": .integer(3_000),
                "command": .string("git status --short"),
                "cwd": .string("/project"),
                "networkApprovalContext": .object([
                    "host": .string("api.example.com"),
                    "protocol": .string("https")
                ]),
                "proposedExecpolicyAmendment": .array(execAmendment.map(JSONValue.string)),
                "proposedNetworkPolicyAmendments": .array([
                    .object([
                        "host": .string(networkAmendment.host),
                        "action": .string(networkAmendment.action.rawValue)
                    ])
                ]),
                "availableDecisions": .array([
                    .string("accept"),
                    .string("acceptForSession"),
                    .object([
                        "acceptWithExecpolicyAmendment": .object([
                            "execpolicy_amendment": .array(execAmendment.map(JSONValue.string))
                        ])
                    ]),
                    .object([
                        "applyNetworkPolicyAmendment": .object([
                            "network_policy_amendment": .object([
                                "host": .string(networkAmendment.host),
                                "action": .string(networkAmendment.action.rawValue)
                            ])
                        ])
                    ]),
                    .string("decline"),
                    .string("cancel")
                ])
            ])
        ))

        guard case let .commandApproval(approval) = request.kind else {
            return XCTFail("Expected command approval")
        }
        XCTAssertEqual(approval.proposedExecpolicyAmendment, execAmendment)
        XCTAssertEqual(approval.proposedNetworkPolicyAmendments, [networkAmendment])
        XCTAssertEqual(approval.availableDecisions, [
            .accept,
            .acceptForSession,
            .acceptWithExecpolicyAmendment(execAmendment),
            .applyNetworkPolicyAmendment(networkAmendment),
            .decline,
            .cancel
        ])
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "item/commandExecution/requestApproval",
            request: request,
            response: .approval(.acceptWithExecpolicyAmendment(execAmendment))
        ), .object([
            "decision": .object([
                "acceptWithExecpolicyAmendment": .object([
                    "execpolicy_amendment": .array(execAmendment.map(JSONValue.string))
                ])
            ])
        ]))
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "item/commandExecution/requestApproval",
            request: request,
            response: .approval(.applyNetworkPolicyAmendment(networkAmendment))
        ), .object([
            "decision": .object([
                "applyNetworkPolicyAmendment": .object([
                    "network_policy_amendment": .object([
                        "host": .string(networkAmendment.host),
                        "action": .string(networkAmendment.action.rawValue)
                    ])
                ])
            ])
        ]))
    }

    func testFileChangeApprovalParsesAndEncodesDecision() throws {
        let request = try XCTUnwrap(CodexAppServerClient.parseInteractionRequest(
            id: .string("file-request"),
            method: "item/fileChange/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-2"),
                "startedAtMs": .integer(2_000),
                "reason": .string("Write generated file"),
                "grantRoot": .string("/project/generated")
            ])
        ))

        guard case let .fileChangeApproval(approval) = request.kind else {
            return XCTFail("Expected file-change approval")
        }
        XCTAssertEqual(approval.reason, "Write generated file")
        XCTAssertEqual(approval.grantRoot, "/project/generated")
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "item/fileChange/requestApproval",
            request: request,
            response: .approval(.acceptForSession)
        ), .object(["decision": .string("acceptForSession")]))
    }

    func testUserInputParsesSecretMetadataAndRequiresExactAnswerIDs() throws {
        let request = try XCTUnwrap(CodexAppServerClient.parseInteractionRequest(
            id: .integer(8),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-3"),
                "isBlocking": .bool(true),
                "questions": .array([
                    .object([
                        "id": .string("environment"),
                        "header": .string("Target"),
                        "question": .string("Choose environment"),
                        "options": .array([
                            .object([
                                "label": .string("Staging"),
                                "description": .string("Use staging")
                            ])
                        ])
                    ]),
                    .object([
                        "id": .string("token"),
                        "header": .string("Credential"),
                        "question": .string("Enter token"),
                        "isOther": .bool(true),
                        "isSecret": .bool(true),
                        "options": .null
                    ])
                ])
            ])
        ))

        guard case let .userInput(input) = request.kind else {
            return XCTFail("Expected user input")
        }
        XCTAssertTrue(input.isBlocking)
        XCTAssertEqual(input.questions.count, 2)
        XCTAssertTrue(input.questions[1].isSecret)
        XCTAssertNil(input.questions[1].options)

        let answers = [
            "environment": ["Staging"],
            "token": ["user_note: secret-value"]
        ]
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "item/tool/requestUserInput",
            request: request,
            response: .userInput(answers)
        ), .object([
            "answers": .object([
                "environment": .object(["answers": .array([.string("Staging")])]),
                "token": .object(["answers": .array([.string("user_note: secret-value")])])
            ])
        ]))
        XCTAssertThrowsError(try CodexAppServerClient.makeInteractionResponse(
            method: "item/tool/requestUserInput",
            request: request,
            response: .userInput(["environment": ["Staging"]])
        ))
    }

    func testPermissionsApprovalParsesAndEncodesExplicitDenyOrGrant() throws {
        let permissions: JSONValue = .object([
            "network": .object(["enabled": .bool(true)])
        ])
        let request = try XCTUnwrap(CodexAppServerClient.parseInteractionRequest(
            id: .integer(9),
            method: "item/permissions/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-4"),
                "startedAtMs": .integer(4_000),
                "cwd": .string("/project"),
                "reason": .string("Fetch dependency"),
                "permissions": permissions
            ])
        ))

        guard case let .permissionsApproval(approval) = request.kind else {
            return XCTFail("Expected permissions approval")
        }
        XCTAssertEqual(approval.cwd, "/project")
        XCTAssertEqual(approval.permissions, permissions)
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "item/permissions/requestApproval",
            request: request,
            response: .permissions(.deny(scope: .turn))
        ), .object([
            "permissions": .object([:]),
            "scope": .string("turn")
        ]))
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "item/permissions/requestApproval",
            request: request,
            response: .permissions(.grant(permissions: permissions, scope: .session))
        ), .object([
            "permissions": permissions,
            "scope": .string("session")
        ]))
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "item/permissions/requestApproval",
            request: request,
            response: .permissions(.grant(
                permissions: permissions,
                scope: .turn,
                strictAutoReview: true
            ))
        ), .object([
            "permissions": permissions,
            "scope": .string("turn"),
            "strictAutoReview": .bool(true)
        ]))
        XCTAssertThrowsError(try CodexAppServerClient.makeInteractionResponse(
            method: "item/permissions/requestApproval",
            request: request,
            response: .permissions(.grant(permissions: .array([]), scope: .turn))
        ))
    }

    func testMCPElicitationParsesSafeURLAndEncodesActions() throws {
        let request = try XCTUnwrap(CodexAppServerClient.parseInteractionRequest(
            id: .string("elicitation-1"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "serverName": .string("example"),
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "mode": .string("url"),
                "message": .string("Authorize this request"),
                "url": .string("https://example.com/approve"),
                "elicitationId": .string("external-1"),
                "_meta": .object(["source": .string("mcp")])
            ])
        ))

        XCTAssertNil(request.itemID)
        guard case let .mcpElicitation(elicitation) = request.kind else {
            return XCTFail("Expected MCP elicitation")
        }
        XCTAssertEqual(elicitation.serverName, "example")
        XCTAssertEqual(elicitation.mode, .url)
        XCTAssertEqual(elicitation.url?.absoluteString, "https://example.com/approve")
        XCTAssertEqual(elicitation.elicitationID, "external-1")
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "mcpServer/elicitation/request",
            request: request,
            response: .mcpElicitation(.acceptURL)
        ), .object(["action": .string("accept")]))
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "mcpServer/elicitation/request",
            request: request,
            response: .mcpElicitation(.cancel)
        ), .object(["action": .string("cancel")]))
        XCTAssertThrowsError(try CodexAppServerClient.makeInteractionResponse(
            method: "mcpServer/elicitation/request",
            request: request,
            response: .mcpElicitation(.accept(content: .object([:]), metadata: nil))
        ))
        XCTAssertNil(CodexAppServerClient.parseInteractionRequest(
            id: .integer(10),
            method: "mcpServer/elicitation/request",
            params: .object([
                "serverName": .string("example"),
                "threadId": .string("thread-1"),
                "mode": .string("url"),
                "message": .string("Unsafe"),
                "url": .string("file:///tmp/secret"),
                "elicitationId": .string("external-2")
            ])
        ))
    }

    func testMCPFormAcceptsOnlyJSONObjectAndQuestionRequestsAreLimitedToThree() throws {
        let formRequest = try XCTUnwrap(CodexAppServerClient.parseInteractionRequest(
            id: .integer(12),
            method: "mcpServer/elicitation/request",
            params: .object([
                "serverName": .string("example"),
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "mode": .string("form"),
                "message": .string("Choose a value"),
                "requestedSchema": .object(["type": .string("object")])
            ])
        ))
        XCTAssertEqual(try CodexAppServerClient.makeInteractionResponse(
            method: "mcpServer/elicitation/request",
            request: formRequest,
            response: .mcpElicitation(.accept(
                content: .object(["choice": .string("safe")]),
                metadata: nil
            ))
        ), .object([
            "action": .string("accept"),
            "content": .object(["choice": .string("safe")])
        ]))
        XCTAssertThrowsError(try CodexAppServerClient.makeInteractionResponse(
            method: "mcpServer/elicitation/request",
            request: formRequest,
            response: .mcpElicitation(.accept(content: .array([]), metadata: nil))
        ))
        XCTAssertThrowsError(try CodexAppServerClient.makeInteractionResponse(
            method: "mcpServer/elicitation/request",
            request: formRequest,
            response: .mcpElicitation(.acceptURL)
        ))

        let questions = (0..<4).map { index in
            JSONValue.object([
                "id": .string("q-\(index)"),
                "header": .string("Q\(index)"),
                "question": .string("Question \(index)")
            ])
        }
        XCTAssertNil(CodexAppServerClient.parseInteractionRequest(
            id: .integer(13),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-many"),
                "isBlocking": .bool(true),
                "questions": .array(questions)
            ])
        ))
    }

    func testInteractionMethodMismatchIsRejected() throws {
        let request = try XCTUnwrap(CodexAppServerClient.parseInteractionRequest(
            id: .integer(11),
            method: "item/fileChange/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-5"),
                "startedAtMs": .integer(5_000)
            ])
        ))

        XCTAssertThrowsError(try CodexAppServerClient.makeInteractionResponse(
            method: "item/commandExecution/requestApproval",
            request: request,
            response: .approval(.decline)
        ))
        XCTAssertThrowsError(try CodexAppServerClient.makeInteractionResponse(
            method: "item/fileChange/requestApproval",
            request: request,
            response: .userInput([:])
        ))
    }

    func testDuplicateRequestResolvedNotificationAndStaleResponse() async throws {
        let client = CodexAppServerClient()
        let params: JSONValue = .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-6"),
            "startedAtMs": .integer(6_000)
        ])
        client.handleServerRequest(
            id: .string("request-1"),
            method: "item/fileChange/requestApproval",
            params: params
        )
        client.handleServerRequest(
            id: .string("request-1"),
            method: "item/fileChange/requestApproval",
            params: params
        )
        XCTAssertEqual(client.pendingInteractionIDs, [.string("request-1")])

        client.handleNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string("thread-1"),
                "requestId": .string("request-1")
            ])
        )
        XCTAssertEqual(client.pendingInteractionIDs, [])

        do {
            try await client.respond(to: .string("request-1"), with: .approval(.decline))
            XCTFail("Resolved request must reject a stale response")
        } catch let error as CodexClientError {
            guard case .invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func testMCPStatusAndOAuthUseExactMethodsAndWireFields() throws {
        XCTAssertEqual(CodexAppServerClient.mcpServerStatusListMethod, "mcpServerStatus/list")
        XCTAssertEqual(CodexAppServerClient.mcpOAuthLoginMethod, "mcpServer/oauth/login")
        XCTAssertEqual(CodexAppServerClient.mcpOAuthCompletionMethod, "mcpServer/oauthLogin/completed")
        XCTAssertEqual(CodexAppServerClient.makeMCPServerListParams(
            cursor: "next",
            threadID: "thread-1"
        ), .object([
            "limit": .integer(100),
            "detail": .string("toolsAndAuthOnly"),
            "cursor": .string("next"),
            "threadId": .string("thread-1")
        ]))
        XCTAssertEqual(CodexAppServerClient.makeMCPOAuthLoginParams(
            serverName: "github",
            threadID: "thread-1"
        ), .object([
            "name": .string("github"),
            "threadId": .string("thread-1")
        ]))

        let page = try CodexAppServerClient.parseMCPServerListResponse(.object([
            "data": .array([
                .object([
                    "name": .string("github"),
                    "authStatus": .string("oAuth"),
                    "serverInfo": .object([
                        "name": .string("GitHub"),
                        "version": .string("1.0"),
                        "title": .string("GitHub Connector"),
                        "description": .string("Repository tools"),
                        "websiteUrl": .string("https://github.com")
                    ]),
                    "tools": .object([
                        "search": .object([:]),
                        "read": .object([:])
                    ]),
                    "resources": .array([]),
                    "resourceTemplates": .array([])
                ])
            ]),
            "nextCursor": .string("page-2")
        ]))
        XCTAssertEqual(page.nextCursor, "page-2")
        XCTAssertEqual(page.servers.first?.name, "github")
        XCTAssertEqual(page.servers.first?.authStatus, "oAuth")
        XCTAssertEqual(page.servers.first?.toolNames, ["read", "search"])

        XCTAssertEqual(try CodexAppServerClient.parseMCPOAuthLoginResponse(.object([
            "authorizationUrl": .string("https://example.com/oauth")
        ])).absoluteString, "https://example.com/oauth")
        XCTAssertThrowsError(try CodexAppServerClient.parseMCPOAuthLoginResponse(.object([
            "authorizationUrl": .string("javascript:alert(1)")
        ])))

        let completion = try XCTUnwrap(CodexAppServerClient.parseMCPOAuthCompletion(
            method: "mcpServer/oauthLogin/completed",
            params: .object([
                "name": .string("github"),
                "threadId": .string("thread-1"),
                "success": .bool(false),
                "error": .string("denied")
            ])
        ))
        XCTAssertEqual(completion.serverName, "github")
        XCTAssertFalse(completion.success)
        XCTAssertEqual(completion.error, "denied")
        XCTAssertNil(CodexAppServerClient.parseMCPOAuthCompletion(
            method: "mcpServer/oauth/login/completed",
            params: .object([
                "name": .string("github"),
                "success": .bool(true)
            ])
        ))
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

    func testThreadResumeParamsExcludeHistoricalTurns() throws {
        let params = try XCTUnwrap(CodexAppServerClient.makeThreadResumeParams(
            threadID: "thread-1",
            cwd: "/project"
        ).objectValue)

        XCTAssertEqual(params["threadId"], .string("thread-1"))
        XCTAssertEqual(params["cwd"], .string("/project"))
        XCTAssertEqual(params["runtimeWorkspaceRoots"], .array([.string("/project")]))
        XCTAssertEqual(params["excludeTurns"], .bool(true))
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
        XCTAssertEqual(params["approvalsReviewer"], .string("user"))
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
            approvalPolicy: "on-request"
        ).objectValue)

        XCTAssertEqual(params["serviceTier"], .string("priority"))
        XCTAssertEqual(params["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(params["approvalsReviewer"], .string("user"))
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

    func testTurnDiffUpdatedMapsLatestAggregatedDiff() throws {
        let diff = "diff --git a/a.swift b/a.swift\n+a line"
        let event = try XCTUnwrap(CodexAppServerClient.turnDiffEvent(
            method: "turn/diff/updated",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "diff": .string(diff)
            ])
        ))

        guard case let .turnDiffUpdated(threadID, turnID, receivedDiff) = event else {
            return XCTFail("turn/diff/updated must map to a turnDiffUpdated event")
        }
        XCTAssertEqual(threadID, "thread-1")
        XCTAssertEqual(turnID, "turn-1")
        XCTAssertEqual(receivedDiff, diff)
    }

    func testMalformedTurnDiffNotificationIsIgnored() {
        XCTAssertNil(CodexAppServerClient.turnDiffEvent(
            method: "turn/diff/updated",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1")
            ])
        ))
        XCTAssertNil(CodexAppServerClient.turnDiffEvent(
            method: "turn/completed",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "diff": .string("patch")
            ])
        ))
    }

    func testStructuredProtocolEventParsesSubagentThreadStarted() throws {
        let notification = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "method": "thread/started",
          "params": {
            "thread": {
              "id": "child-1",
              "sessionId": "root-1",
              "forkedFromId": null,
              "parentThreadId": "root-1",
              "preview": "",
              "ephemeral": false,
              "section": null,
              "sectionEnteredAt": null,
              "modelProvider": "openai",
              "createdAt": 1770000000,
              "updatedAt": 1770000001,
              "recencyAt": 1770000001,
              "status": {"type": "active", "activeFlags": []},
              "path": null,
              "cwd": "/srv/project",
              "cliVersion": "0.148.0",
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
              "threadSource": null,
              "agentNickname": "Popper",
              "agentRole": "explorer",
              "gitInfo": null,
              "name": null,
              "turns": []
            }
          }
        }
        """#.utf8))
        let method = try XCTUnwrap(notification["method"]?.stringValue)
        let params = try XCTUnwrap(notification["params"])
        let event = try XCTUnwrap(CodexAppServerClient.structuredProtocolEvent(
            method: method,
            params: params
        ))

        guard case let .threadStarted(thread) = event else {
            return XCTFail("thread/started must preserve the nested thread")
        }
        XCTAssertEqual(thread.id, "child-1")
        XCTAssertEqual(thread.sessionID, "root-1")
        XCTAssertEqual(thread.parentThreadID, "root-1")
        XCTAssertEqual(thread.agentNickname, "Popper")
        XCTAssertEqual(thread.agentRole, "explorer")
        XCTAssertEqual(thread.sourceKind, "subAgent")
    }

    func testStructuredProtocolEventPreservesCollabWireStringsAndLifecycle() throws {
        let event = try XCTUnwrap(CodexAppServerClient.structuredProtocolEvent(
            method: "item/started",
            params: .object([
                "threadId": .string("root-1"),
                "turnId": .string("turn-1"),
                "startedAtMs": .integer(1_770_000_000_123),
                "item": .object([
                    "type": .string("collabAgentToolCall"),
                    "id": .string("call-1"),
                    "tool": .string("futureTool"),
                    "status": .string("futureStatus"),
                    "senderThreadId": .string("root-1"),
                    "receiverThreadIds": .array([.string("child-1")]),
                    "prompt": .null,
                    "model": .string("future-model"),
                    "agentsStates": .object([
                        "child-1": .object([
                            "status": .string("futureAgentStatus"),
                            "message": .null
                        ])
                    ])
                ])
            ])
        ))

        guard case let .collabAgentToolCall(threadID, turnID, lifecycle, call) = event else {
            return XCTFail("collab item must map to a structured event")
        }
        XCTAssertEqual(threadID, "root-1")
        XCTAssertEqual(turnID, "turn-1")
        XCTAssertEqual(lifecycle, .started(atMilliseconds: 1_770_000_000_123))
        XCTAssertEqual(call.tool, "futureTool")
        XCTAssertEqual(call.status, "futureStatus")
        XCTAssertEqual(call.receiverThreadIDs, ["child-1"])
        XCTAssertNil(call.prompt)
        XCTAssertEqual(call.model, "future-model")
        XCTAssertNil(call.reasoningEffort)
        XCTAssertEqual(call.agentStates["child-1"]?.status, "futureAgentStatus")
    }

    func testStructuredProtocolEventParsesCompletedCollabLifecycle() throws {
        let event = try XCTUnwrap(CodexAppServerClient.structuredProtocolEvent(
            method: "item/completed",
            params: .object([
                "threadId": .string("root-1"),
                "turnId": .string("turn-1"),
                "completedAtMs": .integer(1_770_000_000_456),
                "item": .object([
                    "type": .string("collabAgentToolCall"),
                    "id": .string("call-1"),
                    "tool": .string("spawnAgent"),
                    "status": .string("completed"),
                    "senderThreadId": .string("root-1"),
                    "receiverThreadIds": .array([.string("child-1")]),
                    "agentsStates": .object([
                        "child-1": .object(["status": .string("completed")])
                    ])
                ])
            ])
        ))

        guard case let .collabAgentToolCall(_, _, lifecycle, call) = event else {
            return XCTFail("completed collab item must preserve its lifecycle timestamp")
        }
        XCTAssertEqual(lifecycle, .completed(atMilliseconds: 1_770_000_000_456))
        XCTAssertEqual(call.status, "completed")
    }

    func testStructuredProtocolEventParsesSubAgentActivity() throws {
        let event = try XCTUnwrap(CodexAppServerClient.structuredProtocolEvent(
            method: "item/started",
            params: .object([
                "threadId": .string("root-1"),
                "turnId": .string("turn-1"),
                "startedAtMs": .integer(1_770_000_000_789),
                "item": .object([
                    "type": .string("subAgentActivity"),
                    "id": .string("activity-1"),
                    "agentThreadId": .string("child-1"),
                    "agentPath": .string("/root/child"),
                    "kind": .string("interacted")
                ])
            ])
        ))

        guard case let .subAgentActivity(threadID, turnID, lifecycle, activity) = event else {
            return XCTFail("sub-agent activity must map to a structured event")
        }
        XCTAssertEqual(threadID, "root-1")
        XCTAssertEqual(turnID, "turn-1")
        XCTAssertEqual(lifecycle, .started(atMilliseconds: 1_770_000_000_789))
        XCTAssertEqual(activity.id, "activity-1")
        XCTAssertEqual(activity.agentThreadID, "child-1")
        XCTAssertEqual(activity.agentPath, "/root/child")
        XCTAssertEqual(activity.kind, "interacted")
    }

    func testStructuredProtocolEventParsesTokenUsageAndDefaultsCacheWrite() throws {
        let event = try XCTUnwrap(CodexAppServerClient.structuredProtocolEvent(
            method: "thread/tokenUsage/updated",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "tokenUsage": .object([
                    "total": .object([
                        "totalTokens": .integer(1_200),
                        "inputTokens": .integer(900),
                        "cachedInputTokens": .integer(300),
                        "cacheWriteInputTokens": .integer(20),
                        "outputTokens": .integer(250),
                        "reasoningOutputTokens": .integer(50)
                    ]),
                    "last": .object([
                        "totalTokens": .integer(240),
                        "inputTokens": .integer(180),
                        "cachedInputTokens": .integer(60),
                        "outputTokens": .integer(50),
                        "reasoningOutputTokens": .integer(10)
                    ]),
                    "modelContextWindow": .integer(353_400)
                ])
            ])
        ))

        guard case let .tokenUsageUpdated(threadID, turnID, usage) = event else {
            return XCTFail("token usage notification must map to a structured event")
        }
        XCTAssertEqual(threadID, "thread-1")
        XCTAssertEqual(turnID, "turn-1")
        XCTAssertEqual(usage.total.cacheWriteInputTokens, 20)
        XCTAssertEqual(usage.last.cacheWriteInputTokens, 0)
        XCTAssertEqual(usage.last.totalTokens, 240)
        XCTAssertEqual(usage.modelContextWindow, 353_400)
    }

    func testMalformedStructuredProtocolNotificationIsIgnored() {
        XCTAssertNil(CodexAppServerClient.structuredProtocolEvent(
            method: "item/started",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "startedAtMs": .integer(1),
                "item": .object([
                    "type": .string("collabAgentToolCall"),
                    "id": .string("call-1"),
                    "tool": .string("spawnAgent"),
                    "status": .string("inProgress"),
                    "senderThreadId": .string("thread-1"),
                    "receiverThreadIds": .array([])
                ])
            ])
        ))
    }
}
