# CodexBoard

CodexBoard 是一个本地优先的 macOS 项目管理看板。它从本机 Codex 的 app-server 读取项目历史，把项目按 Git 根目录或规范化工作目录聚合，并让每张任务卡在同一个 Codex thread/session 中依次完成：

1. 只读规划
2. 人工确认，或在全自动模式下自动排队
3. 项目目录内执行
4. 汇总改动文件、验证命令、测试结果与残留风险
5. 人工验收，或带着明确反馈进入下一次执行

规划和执行的每次尝试都会保存为独立 Run。执行完成后任务先进入“待验收”，不会
直接标记完成；验收人可以确认交付，也可以提交修改要求，让同一任务保留完整的
实施—评审—修正历史。任务模型已预留独立 Worktree、分支和基准分支配置，后续可
在不改变验收流程的前提下加入同仓库安全并发。

创建任务时可以从本机 Codex 的实时模型目录中选择模型与推理强度，并决定是否启用
Fast。所选运行配置会随任务保存，后续规划、确认执行或恢复任务时保持不变。

主窗口关闭后，CodexBoard 会继续驻留在 macOS 状态栏。状态栏小窗口会列出所有
“规划中”和“执行中”的任务，显示所属项目与实时进度，并可一键回到任务或停止任务。

## 安全边界

- 不读取或复制 `~/.codex/auth.json`；应用启动本机 `codex app-server`，自然复用 Codex 当前登录和配置。
- 项目扫描使用 `thread/list` 的 state DB 快速路径，不扫描或保存历史提示词、回复正文与 rollout JSONL。
- 规划阶段只读；执行阶段默认只能写入所选项目目录，网络访问由设置控制。
- “全自动”只跳过方案确认，不扩大文件系统权限。
- 看板数据保存在 `~/Library/Application Support/CodexBoard/board.json`，其中只记录用户所选文件的本地路径，不会复制或改写源文件。
- 从剪贴板粘贴的截图由应用保存在 `~/Library/Application Support/CodexBoard/attachments/<task-id>/`，删除任务时会一并清理。数据目录权限为 `0700`，文件权限为 `0600`。

## 开发

```bash
swift test
./script/build_and_run.sh --verify
```

可分发产物位于 `dist/CodexBoard-macOS.zip`。构建脚本会在非 File Provider
目录中完成临时签名与严格校验，再从隔离的临时运行目录启动；这样可避免桌面同步
服务自动附加的 Finder 元数据破坏应用签名。当前产物为本机 ad-hoc 签名，未做
Developer ID 签名或 Apple 公证。

Codex 桌面应用可读取 `.codex/environments/environment.toml` 中的 Run 动作。
