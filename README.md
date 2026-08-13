# CodexBoard

CodexBoard 是一个本地优先的 macOS 项目管理看板。它从本机 Codex 的 app-server 读取项目历史，把项目按 Git 根目录或规范化工作目录聚合，并让每张任务卡在同一个 Codex thread/session 中依次完成：

1. 只读规划
2. 人工确认，或在全自动模式下自动排队
3. 项目目录内执行
4. 保存结果与会话标识

主窗口关闭后，CodexBoard 会继续驻留在 macOS 状态栏。状态栏小窗口会列出所有
“规划中”和“执行中”的任务，显示所属项目与实时进度，并可一键回到任务或停止任务。

## 安全边界

- 不读取或复制 `~/.codex/auth.json`；应用启动本机 `codex app-server`，自然复用 Codex 当前登录和配置。
- 项目扫描使用 `thread/list` 的 state DB 快速路径，不扫描或保存历史提示词、回复正文与 rollout JSONL。
- 规划阶段只读；执行阶段默认只能写入所选项目目录，网络访问由设置控制。
- “全自动”只跳过方案确认，不扩大文件系统权限。
- 看板数据仅保存在 `~/Library/Application Support/CodexBoard/board.json`，目录权限为 `0700`，文件权限为 `0600`。

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
