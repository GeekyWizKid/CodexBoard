import SwiftUI

struct TaskComposer: View {
    @ObservedObject var store: BoardStore
    @Binding var isPresented: Bool
    @State private var projectID: String
    @State private var title = ""
    @State private var sourceKind: TaskSourceKind = .issue
    @State private var sourceText = ""
    @State private var autoRun: Bool

    init(store: BoardStore, isPresented: Binding<Bool>) {
        self.store = store
        _isPresented = isPresented
        _projectID = State(initialValue: store.selectedProjectID ?? store.visibleProjects.first?.id ?? "")
        _autoRun = State(initialValue: store.preferences.defaultAutoRun)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("创建 Codex 任务")
                        .font(.title2.weight(.semibold))
                    Text("先生成只读方案，再确认执行。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }

            Form {
                Picker("项目", selection: $projectID) {
                    ForEach(store.visibleProjects) { project in
                        Text(project.name).tag(project.id)
                    }
                }

                Picker("输入类型", selection: $sourceKind) {
                    ForEach(TaskSourceKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextField("标题（可留空自动提取）", text: $title)

                VStack(alignment: .leading, spacing: 6) {
                    Text(sourceKind == .issue ? "Issue 内容" : "开发计划")
                        .font(.callout.weight(.medium))
                    TextEditor(text: $sourceText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 190)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            if sourceText.isEmpty {
                                Text(sourceKind == .issue
                                     ? "粘贴 GitHub Issue、缺陷描述或需求…"
                                     : "输入里程碑、功能清单、约束与验收标准…")
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .padding(12)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Toggle(isOn: $autoRun) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全自动模式")
                        Text("规划完成后跳过方案确认并自动进入执行队列；不会扩大项目写入权限。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Label("规划阶段强制只读", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("创建并规划") {
                    guard store.createTask(
                        projectID: projectID,
                        title: title,
                        sourceKind: sourceKind,
                        sourceText: sourceText,
                        autoRun: autoRun
                    ) != nil else { return }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(BoardTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(projectID.isEmpty || sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620, height: 610)
    }
}
