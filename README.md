# Claude会话管理

轻量 macOS 原生工具，用于整理 **Claude Desktop / Claude Code** 本地会话：盘点、搜索、归档、安全删除、导出、Resume 衔接。

> 不是聊天客户端。不调用 Claude API，不碰凭证。

## 功能（v0.1.2）

- **主窗口应用**（无菜单栏常驻）
- 自动检测本机路径（`~/.claude`、`Application Support/Claude` 或 `Claude-3p`），可用 `~` 保存，**不写死用户名**
- 扫描并合并 Desktop `local_*.json` + Code `*.jsonl`
- 列表：卡片阴影 / 斑马底 / 来源色条；侧边栏整行可点
- **项目右键**：查看、Finder 打开、导出、归档、**删除该项目全部会话**
- **搜索**：标题路径快搜 + 可选正文 FTS
- **多选批量**：⌘ 点选、⇧ 范围选；批量导出 Markdown/JSON/Zip、批量归档/删除
- 重命名、归档、收藏、回收站（默认 14 天）
- 复制 `claude --resume`、终端打开、Finder 显示

## 别人能用吗？

可以。发给同事时：

1. 对方是 **macOS 14+**，本机装过 Claude Desktop 和/或 Claude Code  
2. 把整个仓库给他，或只给编译好的 `.app`  
3. 首次启动会按**对方机器上的 home 目录**自动探测：
   - `~/.claude/projects`
   - `~/Library/Application Support/Claude-3p` 与/或 `Claude`  
4. 若对方自定义了 `CLAUDE_CONFIG_DIR` 或路径不同：打开 **设置 → 自动检测 / 手动选择**

路径保存在 `~/Library/Application Support/ClaudeSessionManager/settings.json`，使用 `~/...` 形式，换用户不会残留你的绝对路径。

**注意**：对方只能管理**自己电脑上**的本地会话，不会读取你的历史；删除只影响本机会话文件，不会删项目源码。

## 要求

- macOS 14+
- 构建需要：Xcode 15+、`xcodegen`（`brew install xcodegen`）

## 构建与运行

```bash
./scripts/build.sh
open "ClaudeSessionManager/build/Build/Products/Release/Claude会话管理.app"
```

Debug：

```bash
./scripts/build.sh Debug
open "ClaudeSessionManager/build/Build/Products/Debug/Claude会话管理.app"
```

## 使用提示

| 操作 | 方式 |
|---|---|
| 切换左侧项目/筛选 | 点击**整行**任意位置 |
| 项目批量操作 | **右键项目名** → 归档 / 删除全部会话 / 导出 |
| 多选会话 | ⌘ 点击追加；⇧ 点击范围 |
| 批量导出/删除 | 选中后底部批量栏，或工具栏 |

应用数据：`~/Library/Application Support/ClaudeSessionManager/`

## 文档

- [产品文档与功能清单](docs/PRODUCT.md)

## 免责

非 Anthropic 官方产品。会读写本机 Claude 相关文件；破坏性操作前请确认。默认不发起网络请求。
