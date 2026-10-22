# 会话管家

<p align="center">
  <img src="ClaudeSessionManager-icon-preview.png" width="180" alt="会话管家图标">
</p>

轻量的 macOS 原生应用，用于盘点、搜索、整理、导出本地编程代理会话。Claude 会话可以整理和安全删除；Codex、Grok、OpenCode 会话只读查看。

> 这不是聊天客户端。应用不调用 Claude API、不读取账号凭证，默认不发起网络请求。

## 当前状态

- 当前版本：**v0.2.0**
- 平台：macOS 14+
- 技术栈：Swift 5.9、SwiftUI、SQLite/FTS5、XcodeGen
- 应用形态：普通主窗口应用，不在菜单栏常驻
- 分发状态：目前以源码构建为主，仓库暂未提供签名、公证后的 Release 安装包

## 功能

- 自动检测 `~/.claude`、`Application Support/Claude` 和 `Claude-3p`
- 只读扫描 Codex `~/.codex/sessions`、Grok `~/.grok/sessions`、OpenCode `opencode.db`
- 扫描并合并 Desktop `local_*.json` 与 Claude Code `*.jsonl`
- 标题、路径快速搜索，以及可选的会话正文全文搜索
- 按项目、归档状态和文件大小筛选，支持多种排序方式
- 消息摘要预览、收藏、重命名、归档和批量操作
- 导出 Markdown、JSON，或将原始 meta/transcript 打包为 Zip
- 复制恢复命令、Terminal 打开、Finder 显示。Claude 用 `claude --resume`，Codex 用 `codex resume`，Grok 用 `grok --resume`，OpenCode 用 `opencode -s`
- 应用内回收站，默认保留 14 天

## 删除安全机制

删除只处理 Claude 的会话元数据和 transcript，不会删除项目源码目录，也不会删除 Codex、Grok、OpenCode 的会话文件。

- 项目以**标准化完整路径**区分；即使文件夹同名，也不会跨路径执行项目级操作
- 删除前先把全部源文件复制到临时暂存区并逐文件校验
- 校验成功后才提交回收站目录并移除源文件；中途失败会回滚
- 最近 2 分钟内仍有活动的会话默认跳过，强制删除需要第二次确认
- 恢复时如果原路径已经出现新文件，会停止恢复，不会覆盖新数据
- 本地操作写入 `~/Library/Application Support/ClaudeSessionManager/audit.log`

任何本地文件工具都无法替代备份。执行批量操作前，仍建议确认会话范围并保留重要数据副本。

## 数据范围

应用主要读取：

```text
~/.claude/projects/**/*.jsonl
~/Library/Application Support/Claude-3p/**/local_*.json
~/Library/Application Support/Claude/**/local_*.json
~/.codex/sessions/**/rollout-*.jsonl
~/.codex/archived_sessions/**/rollout-*.jsonl
~/.grok/sessions/<工作目录>/<会话>/summary.json
~/.local/share/opencode/opencode.db
```

Codex、Grok、OpenCode 只读。扫描不会读取这些目录里的凭证、`auth.json` 或 OpenCode 的 `credential` 表。压缩的 Codex `.jsonl.zst` 需要本机有 `zstd` 才能解析标题和预览；没有 `zstd` 时仍会列出文件。

应用自己的设置、索引、覆盖信息和回收站保存在：

```text
~/Library/Application Support/ClaudeSessionManager/
```

全文搜索开启时，会话中的可搜索文本会写入该目录下的本地 SQLite FTS 索引。应用不会读取或管理 Keychain、Cookie、主机凭证、MCP 密钥等敏感数据。

标准 Claude Desktop 云端聊天历史不一定完整保存在本机，因此本项目不承诺管理未导出的云端对话。

## 构建与运行

需要：

- macOS 14+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

安装 XcodeGen：

```bash
brew install xcodegen
```

Release 构建：

```bash
./scripts/build.sh
open "ClaudeSessionManager/build/Build/Products/Release/会话管家.app"
```

Debug 构建：

```bash
./scripts/build.sh Debug
open "ClaudeSessionManager/build/Build/Products/Debug/会话管家.app"
```

构建脚本会根据 `ClaudeSessionManager/project.yml` 重新生成 Xcode 工程，因此 `.xcodeproj` 和 `build/` 不纳入版本控制。

## 测试

```bash
cd ClaudeSessionManager
xcodegen generate
xcodebuild \
  -scheme ClaudeSessionManager \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  test
```

当前安全回归测试覆盖：同名项目隔离、回收站移动/恢复内容一致性、恢复目标冲突保护，以及 Codex / Grok / OpenCode 的只读扫描。测试使用系统临时目录，不读取真实会话。

## 使用提示

| 操作 | 方式 |
|---|---|
| 切换项目或筛选 | 点击侧边栏整行；项目名下方显示完整路径摘要 |
| 项目批量操作 | 右键项目 → 导出、归档或删除该路径下的全部会话 |
| 多选会话 | ⌘ 点击追加，⇧ 点击范围 |
| 批量导出或删除 | 使用列表底部批量栏或工具栏 |
| 恢复会话 | 打开回收站，右键会话并选择“恢复” |

如果使用了自定义 `CLAUDE_CONFIG_DIR` 或其他存储位置，可在“设置”中手动选择路径。

## 已知限制

- Claude、Codex、Grok、OpenCode 的本地数据格式都不是稳定公开接口，上游升级后可能需要适配
- Codex、Grok、OpenCode 目前只读，不能在本应用里重命名、归档或删除
- 压缩 Codex rollout 的全文索引会跳过，避免每次刷新都解压全部历史；标题、路径和打开后的预览仍然可用
- 当前扫描和 FTS 索引仍以全量重建为主，超大数据集会花费更长时间
- 暂无文件系统实时监听、菜单栏入口、全局快捷键和签名公证的安装包
- “登录时启动”和 Dock 图标相关设置尚未接入系统行为
- 项目目前主要针对中文界面，尚未完成本地化

## Roadmap

- 增量索引与 FSEvents 实时刷新
- 磁盘占用统计和清理策略模板
- 工具调用折叠、搜索命中高亮和更完整的消息预览
- 标签、备注和智能集合 UI
- iTerm、Ghostty、Warp、VS Code、Cursor 等可配置动作
- 菜单栏快捷搜索、全局快捷键和 Shortcuts 集成
- Developer ID 签名、公证及 GitHub Releases

更完整的产品边界和规划见 [产品文档](docs/PRODUCT.md)，版本变化见 [CHANGELOG](CHANGELOG.md)。

## 开源与免责声明

会话管家不是 Claude、Codex、Grok 或 OpenCode 的官方产品。它会按用户操作读写本机会话文件；删除和归档只作用于 Claude。请自行评估并备份重要数据。

仓库目前尚未添加开源许可证；在许可证明确前，请勿假定可自由再分发或商用。
