# Claude Session Manager（macOS）

轻量级会话管理工具，面向 Claude Desktop 与 Claude Code。  
目标：把侧边栏里越堆越多、难找、难清的会话管起来，而不是再做一个聊天客户端。

| 项 | 说明 |
|---|---|
| 平台 | macOS 14+（Apple Silicon 优先，Intel 兼容） |
| 形态 | 原生 Swift + SwiftUI 菜单栏 / 轻量窗口应用 |
| 原则 | 本地只读为主、可选写操作需确认；零账号、无云同步、无遥测 |
| 包体目标 | < 15 MB（Release，不含自带运行时） |
| 内存目标 | 空闲 < 40 MB；扫描上千会话时峰值 < 150 MB |
| 启动目标 | 冷启动到可交互 < 1 s |

---

## 1. 背景与问题

Claude Desktop 左侧会话列表会随使用持续增长，内置能力偏弱：

- 难按项目 / 时间 / 体积筛选与批量清理
- 本地有数据，但没有统一的「会话管家」视图
- Claude Code 会话按项目目录散落在 `~/.claude/projects/`，跨项目查找成本高
- 删除后难以确认磁盘是否真正回收；大 transcript 会悄悄占满空间

本工具只做**会话资产的盘点、检索、整理、归档、删除与导出**，不替代 Claude 本身对话。

---

## 2. 本机数据实勘（当前环境）

以下路径来自本机实测与官方文档对照，实现时以可配置路径为准。

### 2.1 你当前主要在用：Claude Desktop 3P + Claude Code

| 来源 | 路径 | 本机现状（约） | 角色 |
|---|---|---|---|
| Desktop 3P 应用数据 | `~/Library/Application Support/Claude-3p/` | ~798 MB | Desktop UI 状态、Code 会话元数据、缓存等 |
| Desktop Code 会话元数据 | `…/Claude-3p/claude-code-sessions/<org>/<account>/local_*.json` | 约 36 个活跃 + 34 个 deleted 标记 | 标题、cwd、模型、归档标记、与 CLI session 的映射 |
| Claude Code 正文 | `~/.claude/projects/<project-slug>/<session-id>.jsonl` | 约 68 个 jsonl，~153 MB 级 | 完整 transcript（消息 / 工具调用） |
| 提示历史 | `~/.claude/history.jsonl` | 较小 | 跨会话输入历史 |
| 标准 Claude Desktop | `~/Library/Application Support/Claude/` | 几乎空 | 云端账号模式；会话主存服务端 |

### 2.2 会话关联关系（关键）

```
Desktop 侧边栏条目
  local_<uuid>.json          ← 元数据（title / cwd / model / isArchived / lastActivityAt）
       │
       │ cliSessionId
       ▼
  ~/.claude/projects/<slug>/<cliSessionId>.jsonl   ← 正文
```

删除策略必须同时考虑：

1. 元数据文件 `local_*.json`（或 `deleted_*` 标记）
2. 对应 `jsonl` transcript
3. 可能存在的 session 工作目录 / uploads / outputs（若有）
4. **绝不**默认触碰：Keychain 凭证、`host-creds-*.json`、`ccd-session-secrets/`、MCP 配置、Cookies

### 2.3 元数据字段（可索引）

`local_*.json` 已观测字段（节选）：

- `sessionId`, `cliSessionId`
- `title`, `titleSource`（如 `auto`）
- `cwd`, `originCwd`
- `createdAt`, `lastActivityAt`, `lastFocusedAt`（毫秒时间戳）
- `model`, `effort`, `permissionMode`
- `isArchived`, `completedTurns`
- `writtenBranches` 等扩展字段

`jsonl` 行级字段（节选）：`type`, `sessionId`, `timestamp`, `cwd`, `gitBranch`, `message`, `customTitle`, `uuid`, `parentUuid` …

> 注意：jsonl 内部格式随 Claude Code 版本变化，**解析必须容错**；标题优先读 Desktop 元数据，其次 `customTitle`，再次首条用户消息摘要。

### 2.4 标准云端 Claude Desktop 的边界

标准登录模式的对话历史主要在 Anthropic 服务端，本机多为缓存 / 草稿 / UI 状态。  
**v1 不承诺**完整管理云端 Chat 历史；可选后续通过官方数据导出包导入，或只做缓存清理提示。

---

## 3. 产品定位

**一句话**：macOS 上的 Claude 会话「文件管理器 + 检索器 + 安全回收站」。

### 3.1 做

- 统一列出 Desktop / Code 会话
- 按项目、时间、模型、体积、归档状态筛选
- 全文检索（标题 + 消息正文，可选）
- 重命名、归档、收藏、打标签（应用侧元数据）
- 安全删除 / 批量清理 / 导出 Markdown·JSON
- 磁盘占用洞察与一键清理建议
- 菜单栏快捷入口 + 全局搜索快捷键

### 3.2 不做（刻意轻量）

- 不内嵌聊天、不调用 Claude API 继续对话
- 不自动改写 transcript 内容
- 不做账号系统、云同步、协作
- 不做完整 MCP / 插件管理（可后续只读展示）
- 不破解、不读取、不展示推理凭证与 Cookie
- 不伪装成官方功能；数据格式变更时降级而不是硬崩

---

## 4. 用户场景

| 场景 | 用户行为 | 期望结果 |
|---|---|---|
| 侧边栏爆炸 | 打开 App → 按「7 天未活动」筛选 | 一键归档或移入回收站 |
| 找旧方案 | ⌘K 搜「静音 菜单栏」 | 命中会话，预览摘要，Reveal in Finder / 复制路径 |
| 项目收尾 | 选中某 cwd 下全部会话 | 导出 zip + 删除本地副本 |
| 磁盘报警 | 看占用排行 | 发现 12MB+ 的巨型 jsonl，确认后删除 |
| 误删恢复 | 打开回收站 | 14 天内可还原元数据与文件 |
| 继续工作 | 选中 Code 会话 → 「在终端 Resume」 | 复制或执行 `claude --resume <id>`（cwd 正确） |

---

## 5. 功能清单

优先级：`P0` 必须有 · `P1` 强烈建议 · `P2` 增强 · `P3` 以后再说

### 5.1 发现与索引（P0）

| ID | 功能 | 说明 |
|---|---|---|
| F-01 | 多源扫描 | 扫描 Desktop 3P `claude-code-sessions`、可选 `local-agent-mode-sessions`、`~/.claude/projects/**/*.jsonl` |
| F-02 | 会话合并视图 | 用 `cliSessionId` / `sessionId` 把元数据与 jsonl 合并成统一 `SessionRecord` |
| F-03 | 增量索引 | 基于 mtime + 文件大小；启动只扫索引库，后台刷新 |
| F-04 | 路径可配置 | 支持自定义 `CLAUDE_CONFIG_DIR`、Claude-3p 路径；预设「本机检测」 |
| F-05 | 文件监视 | `DispatchSource` / FSEvents 监听目录变化，列表自动更新（可关） |

### 5.2 浏览与组织（P0 / P1）

| ID | 功能 | 优先级 | 说明 |
|---|---|---|---|
| F-10 | 会话列表 | P0 | 虚拟列表；列：标题、项目(cwd)、模型、消息量/轮次、体积、最近活动、来源 |
| F-11 | 分组 | P0 | 按 Project / 时间（今天/本周/更早）/ 来源（Desktop/Code） |
| F-12 | 排序 | P0 | 最近活动、创建时间、体积、标题 |
| F-13 | 筛选 | P0 | 归档、有/无 jsonl、最小体积、时间范围、模型、关键词 |
| F-14 | 重命名 | P0 | 写回 Desktop `title`（若存在）；否则写入 App 侧 overlay 元数据 |
| F-15 | 归档 / 取消归档 | P0 | 优先写 `isArchived`；无元数据时用 overlay |
| F-16 | 标签 / 收藏 / 颜色 | P1 | 仅存 App 数据库，不污染官方文件 |
| F-17 | 固定置顶 | P1 | overlay |
| F-18 | 智能智能分组 | P2 | 例如「巨型会话」「孤儿 jsonl」「仅元数据无正文」 |

### 5.3 搜索（P0 / P1）

| ID | 功能 | 优先级 | 说明 |
|---|---|---|---|
| F-20 | 标题 / 路径快搜 | P0 | 默认只搜索引字段，瞬时响应 |
| F-21 | 正文全文检索 | P1 | 后台建 SQLite FTS5；可暂停；大文件抽样或分段 |
| F-22 | 命令面板 ⌘K | P0 | 搜索会话 + 执行动作（归档、删除、导出、Reveal） |
| F-23 | 正则 / 大小写 | P2 | 高级搜索 |

### 5.4 预览与详情（P0 / P1）

| ID | 功能 | 优先级 | 说明 |
|---|---|---|---|
| F-30 | 侧栏摘要 | P0 | 标题、路径、时间、模型、体积、轮次、git 分支 |
| F-31 | 消息预览 | P1 | 只读渲染 user/assistant 文本；工具调用可折叠；不执行任何工具 |
| F-32 | 跳转原文 | P0 | Finder 中显示 jsonl / meta；复制绝对路径 |
| F-33 | 统计 | P1 | 消息数、工具调用数、估算 token（粗）、附件数 |

### 5.5 清理与生命周期（P0）

| ID | 功能 | 说明 |
|---|---|---|
| F-40 | 安全删除 | 移入 App 回收站（拷贝或标记 + 暂存），可设置保留 N 天 |
| F-41 | 批量删除 | 多选 + 二次确认；展示将释放空间 |
| F-42 | 清理策略模板 | 「30 天未活动」「>5MB」「已归档超过 14 天」「无标题且轮次≤1」 |
| F-43 | 孤儿清理 | 只有 deleted 标记、或 meta 与 jsonl 失联的项 |
| F-44 | 空会话 / 草稿 | 识别几乎无用户消息的会话 |
| F-45 | 直接永久删除 | 高级选项；默认关闭；需输入确认词 |
| F-46 | 磁盘洞察 | 按项目汇总占用；Top N 最大会话；Claude-3p 缓存体积只读提示 |

> 删除安全规则见 §7。

### 5.6 导出与备份（P1）

| ID | 功能 | 说明 |
|---|---|---|
| F-50 | 导出 Markdown | 可读 transcript（类 `/export`） |
| F-51 | 导出 JSON / JSONL | 原始或规范化结构 |
| F-52 | 批量打包 | 选中会话 → zip（含 meta + transcript） |
| F-53 | 定时备份 | 可选：将索引 + 收藏会话同步到用户指定文件夹（本地） |
| F-54 | 导入官方 Export | P2：解析 claude.ai 数据导出包（若用户提供） |

### 5.7 与 Claude 工作流衔接（P1）

| ID | 功能 | 说明 |
|---|---|---|
| F-60 | Resume 命令 | 生成 `cd <cwd> && claude --resume <cliSessionId>`，一键复制 |
| F-61 | 终端打开 | 用 Terminal / iTerm / Ghostty（可配）执行 resume |
| F-62 | 在 Cursor / VS Code 打开项目 | `open -a ... <cwd>` |
| F-63 | 服务菜单 / 分享扩展 | P2 |
| F-64 | URL Scheme | P2：`claude-session://open?id=` |

### 5.8 菜单栏与快捷体验（P0 / P1）

| ID | 功能 | 优先级 | 说明 |
|---|---|---|---|
| F-70 | 菜单栏图标 | P0 | 点击弹出精简列表 + 搜索框 |
| F-71 | 主窗口 | P0 | 完整管理界面；可仅菜单栏模式运行 |
| F-72 | 全局快捷键 | P1 | 默认 ⌥Space 或 ⌘⇧Space 呼出搜索（可改） |
| F-73 | 通知 | P2 | 索引完成、清理完成、巨大会话提醒 |
| F-74 | Launch at Login | P1 | 可选 |

### 5.9 设置与隐私（P0）

| ID | 功能 | 说明 |
|---|---|---|
| F-80 | 数据源开关 | 逐项启用 Desktop 3P / Code /（未来）标准 Desktop |
| F-81 | 权限说明 | 清晰解释需要的文件夹访问；支持安全作用域书签 |
| F-82 | 隐私模式 | 标题打码、预览禁用、截图时隐藏内容（`NSPrivacy…` 相关体验） |
| F-83 | 无网络声明 | App 默认不发起网络请求；若未来检查更新需显式开关 |
| F-84 | 卸载清理 | 设置页一键删除 App 索引库与回收站（不动 Claude 数据） |

### 5.10 明确不做 / 延后（P3）

- 编辑并写回官方 jsonl 消息流
- 跨设备 iCloud 同步会话正文
- 会话内 AI 自动摘要（可后续可选调用本地模型）
- Windows / Linux
- 管理 Claude 网页版未导出历史

---

## 6. 信息架构与 UI

### 6.1 布局（主窗口）

```
┌──────────────┬───────────────────────────┬────────────────────┐
│ Sidebar      │ Session List              │ Detail / Preview   │
│              │                           │                    │
│ · 全部       │ [Search]  [Filters]       │ Title / meta       │
│ · 今天       │ ☑ Mac mute menu bar  …    │ Path, model, size  │
│ · 本周       │ ☐ Project features   …    │ ─────────────────  │
│ · 已归档     │ ☐ …                       │ Message preview    │
│ · 回收站     │                           │ [Resume] [Export]  │
│ · 按项目 ▸   │                           │ [Archive] [Delete] │
│ · 标签 ▸     │                           │                    │
│              │ Status: 68 sessions · 42MB│                    │
└──────────────┴───────────────────────────┴────────────────────┘
```

菜单栏 Popover：单栏列表 + 搜索，动作菜单精简为「打开主窗口 / Resume / 归档 / 删除」。

### 6.2 视觉与交互原则

- 跟随系统外观（Light / Dark）
- 系统字体、标准间距；避免花哨动画
- 破坏性操作：红色 + 确认表单；批量操作显示影响文件数与 MB
- 列表虚拟化（LazyVStack / Table）保证千级会话流畅
- 空状态文案告诉用户「去哪开权限 / 为什么列表为空」

### 6.3 关键

| 快捷键 | 动作 |
|---|---|
| ⌘K / ⌘F | 搜索 / 命令面板 |
| ⌘R | 刷新索引 |
| ⌘⇧A | 归档 |
| ⌘⌫ | 移入回收站 |
| ⌘O | Reveal in Finder |
| ⌘↵ | Resume（复制或执行） |
| Space | 快速预览 |

---

## 7. 安全与数据策略

### 7.1 权限

- 使用 **Security-Scoped Bookmarks** 访问 `Application Support/Claude-3p` 与 `~/.claude`
- 首次启动分步授权；拒绝时降级为「仅已授权路径」
- 不申请完全磁盘访问，除非用户主动选择受保护路径

### 7.2 读写边界

| 操作 | 官方文件 | App 自有库 |
|---|---|---|
| 扫描 / 预览 | 只读 | — |
| 重命名 / 归档（Desktop meta） | 可选写 `local_*.json` 字段 | 同时写 overlay 备份 |
| 标签 / 收藏 | 不写 | 只写 App DB |
| 删除 | 经回收站中转后再删 | 记录 tombstone |
| 凭证 / Cookie / Keychain | **禁止读展示、禁止删** | — |

### 7.3 删除流水线

1. 计算影响文件列表与总大小  
2. 用户确认（显示路径样本）  
3. 移入 `~/Library/Application Support/ClaudeSessionManager/Trash/<id>/`  
4. 官方位置删除或写入兼容的 `deleted_*` 标记（与 Desktop 行为对齐时需再验证）  
5. 回收站保留 `trashRetentionDays`（默认 14）后自动永久删除  
6. 所有步骤写入 App 审计日志（本地）

### 7.4 并发与锁

- Claude Desktop / CLI 可能同时写 jsonl  
- 删除前检测文件是否最近 N 秒仍在更新；活跃会话默认跳过或强提示  
- 写 meta 使用原子替换（写临时文件 → `rename`）

### 7.5 格式变更

- 解析失败不崩溃：标记 `parseError`，仍展示文件名与路径  
- 版本探测：记录 `version` 字段分布，便于日后适配

---

## 8. 技术架构（轻量）

### 8.1 技术选型

| 层 | 选择 | 理由 |
|---|---|---|
| UI | SwiftUI + AppKit 少量桥接 | 原生、体积小 |
| 架构 | 单 Target，MV + 轻量 Store | 避免重型框架 |
| 索引库 | SQLite（GRDB.swift 或 SQLite.swift） | FTS5、可靠、可拷贝 |
| 并发 | Swift Concurrentce / actor | 扫描不阻塞 UI |
| 打包 | 标准 .app；可选 Sparkle 自动更新（默认关） | — |

**不引入**：Electron、本地 HTTP 服务、常驻重型 agent、云 SDK。

### 8.2 模块

```
App
├── Scanner          # 目录遍历、格式探测
├── Parser           # local_*.json / jsonl 容错解析
├── IndexStore       # SQLite + FTS
├── OverlayStore     # 标签、收藏、重命名覆盖
├── TrashService     # 回收站
├── ExportService    # MD / JSON / zip
├── ActionRunner     # Resume / Open Terminal / Reveal
├── FSWatcher        # 可选监视
└── UI
    ├── MenuBarExtra
    ├── MainWindow
    └── Settings
```

### 8.3 核心模型（示意）

```swift
struct SessionRecord: Identifiable, Hashable {
    var id: String                 // 稳定 ID：cliSessionId ?? sessionId ?? file path hash
    var source: SessionSource      // desktopCodeMeta / codeJsonl / cowork / ...
    var title: String
    var cwd: String?
    var model: String?
    var createdAt: Date?
    var lastActivityAt: Date?
    var byteSize: Int64
    var messageCount: Int?
    var isArchived: Bool
    var metaURL: URL?
    var transcriptURL: URL?
    var gitBranch: String?
    var parseError: String?
}
```

### 8.4 App 自有数据位置

```
~/Library/Application Support/ClaudeSessionManager/
  index.sqlite
  overlays.json          # 或并入 sqlite
  Trash/
  logs/audit.log
  bookmarks/             # security-scoped bookmarks
```

---

## 9. 性能预算

| 操作 | 目标 |
|---|---|
| 首次全量扫描 100 会话 | < 2 s（仅 meta + 文件 stat） |
| 首次全量扫描 + 正文 FTS（68 个 jsonl，约百 MB） | 后台 < 30 s，可取消 |
| 列表滚动 | 60 fps |
| 标题搜索 | < 50 ms |
| 正文搜索 | 首屏结果 < 300 ms（已索引时） |
| 空闲 CPU | ~0%；监视开启时可忽略 |

策略：

- 列表不读全文；预览时流式读前 N 条消息  
- 大 jsonl（如 > 5 MB）FTS 限速 / 分块  
- 索引落盘，二次启动秒开  

---

## 10. 版本规划

### 已确认产品决策（2026-08-12）

- UI：**菜单栏 + 主窗口**
- v0.1 **包含** 搜索（标题/路径快搜 + 正文 FTS）与导出（Markdown / JSON / 批量 zip）
- 写回：允许更新 Desktop `local_*.json` 的 `title` / `isArchived`，App overlay 同步备份

### v0.1 — MVP

- [x] 文档与功能定义（本文）
- [x] 扫描 Desktop `local_*.json` + Code `jsonl` 并合并
- [x] 主窗口列表 + 筛选排序 + 详情摘要
- [x] 菜单栏入口
- [x] 标题/路径搜索 + 正文 FTS 搜索
- [x] 导出 Markdown / JSON / 批量 zip
- [x] 安全删除（回收站）+ 归档/重命名（meta 或 overlay）
- [x] Reveal in Finder + 复制 Resume 命令
- [x] 设置：路径、保留天数
- [x] 可编译运行的 SwiftUI 工程（xcodegen）

### v0.2

- 消息预览增强（工具调用折叠、虚拟滚动）
- 清理策略模板
- 全局快捷键
- FSEvents 实时刷新

### v0.3

- FSEvents 实时刷新
- 磁盘洞察仪表
- Terminal/iTerm 一键 Resume
- 孤儿 / 失联修复向导
- （可选）标准 Desktop 导出包导入

### 以后

- 本地 LLM 自动摘要标题  
- Shortcuts.app 集成  
- 多 profile / 多机器路径预设  

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 官方路径 / 字段变更 | 扫描失败 | 适配层 + 探测 + 失败可见 |
| 误删活跃会话 | 丢数据 | 活跃检测 + 回收站 + 默认不永久删 |
| 写 meta 与 Desktop 冲突 | 标题被覆盖 | 原子写；启动时合并；overlay 保底 |
| jsonl 极大 | 卡顿 / 占内存 | 流式、采样、大小阈值 |
| 用户期望管理云端 Chat | 功能落差 | 安装引导明确「本地会话」范围 |
| TCC 权限被拒 | 列表空 | 引导文案 + 示例路径按钮 |

---

## 12. 成功指标（个人工具向）

- 3 次点击内完成「找出并删除 30 天未用会话」
- 常用会话 5 秒内通过搜索定位
- 连续使用一周无误删投诉（回收站可救回）
- App 自身不被用户觉得「比 Claude 还重」

---

## 13. 开源与命名（建议）

| 项 | 建议 |
|---|---|
| 产品名 | **Claude会话管理** |
| 简称 | Claude会话管理 |
| Bundle ID | `com.local.ClaudeSessionManager`（可改） |
| License | 个人自用优先；若开源建议 MIT |
| 免责 | 非 Anthropic 官方产品；操作本地文件风险自负；破坏性操作前请备份 |

---

## 14. 附录 A — 本机快速统计命令

```bash
# Desktop Code 元数据数量
ls ~/Library/Application\ Support/Claude-3p/claude-code-sessions/*/* /local_*.json 2>/dev/null | wc -l

# Code transcript 数量与体积
find ~/.claude/projects -name '*.jsonl' | wc -l
du -sh ~/.claude/projects

# 应用数据总占用
du -sh ~/Library/Application\ Support/Claude-3p ~/.claude
```

## 附录 B — 参考

- [Claude Code Sessions 文档](https://code.claude.com/docs/en/sessions) — resume / 存储路径 / 导出
- [Claude Desktop 3P 本地数据](https://claude.com/docs/third-party/claude-desktop/data-storage) — `Claude-3p` 目录结构与删除语义
- 本机实勘：`local_*.json` 与 `~/.claude/projects/**/*.jsonl` 通过 `cliSessionId` 关联

---

## 附录 C — MVP 界面文案草案（中文）

- 空状态：`尚未发现会话。请授权访问 Claude-3p 与 ~/.claude 目录。`
- 删除确认：`将把 N 个会话移入回收站（约 X MB）。可在设置中的保留期内恢复。`
- 活跃警告：`该会话在 2 分钟内仍有写入，可能正在使用。仍要继续吗？`
- 菜单栏占位：`Claude会话管理 · N 个会话`

---

**下一步（待你确认）**

1. 确认 v0.1 范围是否接受（尤其：是否允许写回 `local_*.json` 的 title/isArchived）  
2. 确认 UI 形态：仅菜单栏 / 菜单栏+主窗口（推荐后者）  
3. 确认后开始 Swift Package / Xcode 工程脚手架与 Scanner 原型  
