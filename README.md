# CodexBoard

CodexBoard 是一个本地优先的 macOS 项目管理看板。它可以同时连接本机和多台无图形 SSH 主机上的 Codex app-server，统一读取项目、排队任务和查看执行状态，并让每张任务卡在所属主机的同一个 Codex thread/session 中依次完成：

1. 只读规划
2. 人工确认，或在全自动模式下自动排队
3. 项目目录内执行
4. 保存结果与会话标识

主窗口关闭后，CodexBoard 会继续驻留在 macOS 状态栏。状态栏小窗口会列出所有
“规划中”和“执行中”的任务，显示所属主机、项目与实时进度，并可一键回到任务或停止任务。

## 远程主机

远端需要先安装并登录 Codex CLI，且以下命令应能从 Mac 非交互执行：

```bash
ssh -T your-host-alias 'exec codex app-server --stdio'
```

在“设置 → 主机”中可直接选择 `~/.ssh/config` 里发现的具体 `Host` 别名，也可手动输入；随后可测试连接、启停主机并设置每台主机的执行并发数。远程项目通过以 `/` 开头的绝对路径添加。相同路径位于不同主机时会被视为不同项目。

CodexBoard 只集中管理由它创建或恢复的 app-server 任务，不会接管一个已经在其他终端里交互运行的任意 CLI 进程。当前连接使用 SSH 承载的 stdio；若 Mac 应用退出或 SSH 中断，其他主机不受影响。重新启动或点击“检查后继续执行”时，应用会先用 `thread/read` 核对原 Turn：已完成就直接恢复结果，仍在运行就重新订阅，只有明确失败或中断后才允许启动新 Turn，未知状态一律暂停以避免重复副作用。

## 安全边界

- 不读取或复制本机或远端的 `~/.codex/auth.json`；每台主机上的 app-server 自然复用该主机当前 Codex 登录和配置。
- 远程连接固定调用系统 `/usr/bin/ssh`，复用现有 SSH config/agent；应用不读取或保存私钥，不把 app-server 端口暴露到公网。
- SSH 主机别名作为独立 argv 传入且经过严格校验；远端 stderr 只保留受限长度的尾部用于诊断。
- 项目扫描使用 `thread/list` 的 state DB 快速路径，不扫描或保存历史提示词、回复正文与 rollout JSONL。
- 远程路径从对应主机的 app-server 或用户输入取得，绝不会拿到本机 `FileManager`、Git 或 Finder 中探测。
- 规划阶段只读；执行阶段默认只能写入所选项目目录，网络访问由设置控制。
- “全自动”只跳过方案确认，不扩大文件系统权限。
- 文件系统根目录 `/` 永远不能作为任务工作区；启动远端工作前必须先成功持久化 thread/turn 状态。
- 看板数据（包括 SSH 别名、主机显示名和远程路径，不含凭据）仅保存在 `~/Library/Application Support/CodexBoard/board.json`，目录权限为 `0700`，文件权限为 `0600`。

## 开发

```bash
swift test
./script/build_and_run.sh --verify
```

可分发产物位于 `dist/CodexBoard-macOS.zip`。构建脚本会在非 File Provider
目录中完成临时签名与严格校验；`--verify` 只使用一次性的
`CODEXBOARD_DATA_PATH`，不会打开或改写真实看板。这样也可避免桌面同步服务自动
附加的 Finder 元数据破坏应用签名。当前产物为本机 ad-hoc 签名，未做 Developer
ID 签名或 Apple 公证。

Codex 桌面应用可读取 `.codex/environments/environment.toml` 中的 Run 动作。
