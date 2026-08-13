import SwiftUI

struct SettingsView: View {
    let store: BoardStore

    var body: some View {
        TabView {
            Form {
                Toggle("新任务默认全自动", isOn: binding(\.defaultAutoRun))
                Stepper(
                    "最多同时执行 \(store.preferences.maxConcurrentExecutions) 个任务",
                    value: binding(\.maxConcurrentExecutions),
                    in: 1...4
                )
                Toggle("执行阶段允许网络访问", isOn: binding(\.allowNetworkAccess))
                Toggle("显示目录已丢失的历史项目", isOn: binding(\.showMissingProjects))
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                TextField("新任务默认模型（留空使用本机默认）", text: binding(\.modelOverride))
                Picker("新任务默认推理强度", selection: binding(\.planningEffort)) {
                    ForEach(ReasoningEffort.standardCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }
                LabeledContent("规划权限", value: "只读，无网络")
                LabeledContent("执行权限", value: "仅项目目录可写")
            }
            .formStyle(.grouped)
            .tabItem { Label("Codex", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 330)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<BoardPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in store.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }
}
