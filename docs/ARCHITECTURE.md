# PKGM 系统架构文档

**版本**: V2.0
**创建日期**: 2026-04-22
**最后更新**: 2026-04-23
**状态**: 现行

---

## 1. 项目概述与定位

**PKGM**（Personal Knowledge Graph Manager）是一个基于 LLM Agent 的个人知识管理系统，核心能力是将离散的知识条目通过**图谱关系**连接起来。

### 1.1 三项目架构

PKGM 采用多租户架构，由三个独立项目组成：

| 项目 | 职责 | 定位 |
|------|------|------|
| **PKGM-Manager** | 多租户管理（创建/删除用户 Agent） | 管理平面 |
| **PKGM-Wiki** | 多租户内容生成技能（知识管线） | 业务逻辑层 |
| **PKGM-Web** | 前端展示页面（渲染/搜索/SSE） | 展示平面 |

### 1.2 核心设计理念

> 每个用户拥有独立的 Agent、独立的内容存储目录、独立的 Wiki 知识库。

---

## 2. 系统架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PKGM-Manager (管理平面)                               │
│                                                                              │
│   新用户登录 → 验证 → 调用 create-agent 技能                                │
│   1. 创建用户目录结构                                                        │
│   2. 初始化 Wiki 骨架 (init_user_wiki.sh)                                   │
│   3. 创建用户专属 Agent (SOUL.md)                                           │
│   4. 注册到 OpenClaw Gateway                                                 │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼ (专属 Agent 已就绪)
┌─────────────────────────────────────────────────────────────────────────────┐
│                      用户专属 Agent (业务逻辑层)                              │
│                                                                              │
│   用户对话 → 调用 PKGM-Wiki 技能                                             │
│   PKGM-Wiki 工作流：                                                         │
│   1. 读取输入素材 (URL/PDF/文本)                                             │
│   2. Ingest → Extract → Link → WikiGen                                      │
│   3. 输出 Markdown 到 content/app/wiki/                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼ (原子写入)
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NAS 共享存储                                         │
│         /mnt/nas/project/PKGM/users/{username}/content/                     │
└─────────────────────────────────────────────────────────────────────────────┘
               ┌─────────────────────┴─────────────────────┐
               ▼                                           ▼
┌─────────────────────────────┐         ┌─────────────────────────────┐
│    PKGM-Web Indexer          │         │   PKGM-Web Next.js          │
│    (索引服务)                │         │    (前端展示)               │
│                             │         │                             │
│  - chokidar 监控 content/   │◄────────│  - HTTP POST /api/events    │
│  - 解析 Frontmatter         │         │    SSE 推送                 │
│  - @node-rs/jieba 分词      │         │  - GET /api/users           │
│  - SQLite FTS5 索引         │         │  - GET /api/doc             │
│  - HTTP API (3004)          │         │  - GET /api/search          │
└─────────────────────────────┘         └─────────────────────────────┘
```

---

## 3. 项目边界与职责

### 3.1 PKGM-Manager（管理平面）

**职责范围**：
- 用户生命周期管理（创建、删除、查询状态）
- 用户专属 Agent 的注册与配置
- 用户目录结构的初始化和清理

**核心技能**：
| 技能 | 说明 |
|------|------|
| `create-agent` | 创建用户 Agent |
| `delete-agent` | 删除用户 Agent |
| `manage-session` | 管理用户会话 |
| `query-status` | 查询系统状态 |

**数据产出**：
- `/workspace/project/PKGM/users/{username}/` - 用户根目录
- `/workspace/project/PKGM/users/{username}/agent-workspace/SOUL.md` - Agent 身份定义
- `/workspace/project/PKGM/users/{username}/content/app/wiki/` - Wiki 骨架

**不负责的领域**：
- ❌ 内容生成逻辑
- ❌ 前端展示
- ❌ 索引服务

---

### 3.2 PKGM-Wiki（业务逻辑层）

**职责范围**：
- 接收用户输入的素材（URL/PDF/文本）
- 执行 PKGM 知识管线（Ingest → Extract → Link → WikiGen）
- 输出符合 Schema 的 Markdown Wiki 页面

**核心管线流程**：
```
触发（手动 / URL / Cron）
        │
        ▼
Phase 1: pkgm-ingest（粗咀嚼）
        │
        ▼
Phase 2: pkgm-extract（两阶段抽取）
        │
        ▼
Phase 3: pkgm-link（关联）
        │
        ▼
Phase 4: pkgm-wiki-gen（Wiki 生成）
        │
        ▼
Phase 5: pkgm-lint（质量门控）
        │
        ▼
管线报告输出
```

**数据产出**：
- `/workspace/project/PKGM/users/{username}/content/app/wiki/01_Wiki/*.md`

**依赖项**：
- `../PKGM-Wiki/schema.yaml`
- `../PKGM-Wiki/purpose.md`

**不负责的领域**：
- ❌ 用户创建和管理
- ❌ 前端展示和搜索
- ❌ 索引服务

---

### 3.3 PKGM-Web（展示平面）

**职责范围**：
- 提供多租户 Web 界面
- 渲染 Markdown 文档
- 提供全文搜索
- SSE 实时推送更新

**API 路由**：
| 路由 | 方法 | 说明 |
|------|------|------|
| `/api/users` | GET | 获取所有用户及其文档列表 |
| `/api/doc?user={username}&path={path}` | GET | 获取单篇文档 |
| `/api/search?user={username}&q={query}` | GET | 搜索文档 |
| `/api/events` | GET | SSE 订阅端点 |
| `/api/events` | POST | Indexer 回调端点 |

**不负责的领域**：
- ❌ 用户创建和管理
- ❌ 内容生成逻辑
- ❌ 仅负责展示，不修改内容

---

## 4. 用户目录结构

```
/workspace/project/PKGM/users/{username}/
├── agent-workspace/            # 用户专属 Agent 工作区
│   └── SOUL.md                 # Agent 身份定义
│
├── content/                    # PKGM-Web 展示的内容
│   ├── daily/                  # 日报类文档 (YYYY-MM-DD-[主题].md)
│   ├── uploads/                # 用户上传文档
│   ├── tasks/                  # 任务类文档
│   └── app/                    # PKGM Wiki 内容
│       └── wiki/
│           ├── 01_Wiki/        # Wiki 页面 (concepts, entities...)
│           ├── 02_System/      # 用户级配置
│           ├── 03_Engine/      # 缓存和日志
│           ├── 04_Knowledge/   # 知识领域
│           ├── 05_Project/     # 项目知识
│           ├── 06_Mynotes/     # 原创思考
│           └── 07_Research/    # 创作研究
│
├── assets/                     # 图片和附件
└── meta/                       # SQLite 索引
    └── index.db
```

---

## 5. 与 PKGM-Web 的集成

### 5.1 数据流

```
PKGM-Wiki 输出 Markdown
        │
        ▼ (原子写入)
/workspace/project/PKGM/users/{username}/content/
        │
        ▼
PKGM-Web Indexer (chokidar 监控)
        │
        ├─→ 解析 Frontmatter
        ├─→ 中文分词 (@node-rs/jieba)
        ├─→ 写入 SQLite FTS5
        └─→ HTTP POST /api/events
        │
        ▼
Next.js 接收 SSE 推送
        │
        ▼
浏览器自动刷新显示新内容
```

### 5.2 Frontmatter 规范

PKGM 系统统一使用 PKGM-Wiki 定义的 Schema，详见：
- [schema.yaml](../../PKGM-Wiki/references/default-configs/schema.yaml) — 完整的实体类型、关系类型、属性定义
- [Frontmatter 格式规范](../../PKGM-Wiki/references/default-configs/schema.yaml#4-frontmatter-格式规范) — 正确/错误示例

**快速参考**：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `title` | string | 是 | 文档标题 |
| `type` | enum | 是 | `daily` \| `upload` \| `task` \| `wiki` |
| `status` | enum | 否 | `writing` \| `completed`（默认 `completed`） |
| `source` | enum | 否 | `cron` \| `user-upload` \| `explore-task` \| `wiki-gen` |
| `created` | ISO8601 | 是 | 创建时间 |
| `modified` | ISO8601 | 是 | 修改时间 |

**Wiki 类型扩展字段**（PKGM Wiki 内容专用）：

Wiki 类型页面的扩展字段（domain, confidence, verification, lifecycle, relations）参见
[PKGM-Wiki schema.yaml §3.2 溯源属性必填影响置信度](../../PKGM-Wiki/references/default-configs/schema.yaml#32-溯源属性必填影响置信度)。

**状态机规则**：

| status | Indexer 行为 | 说明 |
|--------|-------------|------|
| `writing` | **跳过**（不索引） | 流式生成中，可能不完整 |
| `completed` | **索引** | 生成完毕，可安全读取 |
| 缺失 | **索引**（向后兼容） | 旧文件默认索引 |

**与 PKGM-Wiki Schema 对齐**：
- `domain`: D01-D12 对应知识领域定义
- `confidence`: 1-5 对应溯源体系
- `verification.status`: unverified/pending/verified/refuted
- `lifecycle.status`: active/superseded/deprecated/refuted
- `relations`: wikilink 格式 `[[页面名]]`

详细规范参见 [PKGM-Wiki schema.yaml](../PKGM-Wiki/schema.yaml)。

---

## 6. 知识图谱 Schema 概览

### 6.1 实体类型（12 种）

| ID | 类型 | 说明 |
|----|------|------|
| N01 | **Concept** | 技术概念 |
| N02 | **Architecture** | 架构设计 |
| N03 | **Decision** | 技术决策 (ADR) |
| N04 | **Experiment** | 实验记录 |
| N05 | **Paper** | 学术论文 |
| N06 | **Method** | 技术方法 |
| N07 | **Person** | 人物 |
| N08 | **Organization** | 组织 |
| N09-N12 | 扩展类型 | CodePattern, Project, Tool, Question |

### 6.2 关系类型（15 种）

| ID | 关系 | 说明 |
|----|------|------|
| R01 | DEPENDS_ON | 概念依赖 |
| R02 | INSPIRED_BY | 灵感来源 |
| R03 | IMPLEMENTS | 实现 |
| R04 | VERIFIED_BY | 验证 |
| R05 | OBSOLETES | 淘汰 |
| R06 | REFINES | 细化 |
| R07 | CONTRADICTS | 矛盾 |
| R08 | BELONGS_TO | 归属 |
| R09 | CITES | 引用 |
| R10 | SURPASSES | 超越 |
| R11 | REFUTES | 反驳 |
| R12 | PROPOSES | 提出 |
| R13 | CREATED_BY | 创建者 |
| R14 | AFFILIATED_WITH | 隶属 |
| R15 | USED_IN | 使用于 |

详细 Schema 定义参见 [PKGM-Wiki schema.yaml](../PKGM-Wiki/schema.yaml)。

---

## 7. 知识领域（Knowledge Domains）

> **权威来源**: 本表为系统支持的全部 12 个知识领域定义。
> 用户级个性化配置（每个用户的 `purpose.md`）可能仅包含部分领域。
> Agent 应读取 `purpose.md` 确定优先级，未配置的领域使用默认 P2 优先级。

| ID | 领域 | 说明 |
|----|------|------|
| D01 | GPU Architecture | GPU 架构 |
| D02 | CPU Architecture | CPU 架构 |
| D03 | Compilers | 编译器 |
| D04 | Programming Languages | 编程语言 |
| D05 | System Architecture | 系统架构 |
| D06 | Hardware Verification | 硬件验证 |
| D07 | CNN Accelerator | CNN 加速器 |
| D08 | RNN Accelerator | RNN 加速器 |
| D09 | Transformer | Transformer 模型 |
| D10 | Quantum Computing | 量子计算 |
| D11 | Operating System | 操作系统 |
| D12 | Distributed Systems | 分布式系统 |

详细领域定义参见 [PKGM-Wiki purpose.md](../PKGM-Wiki/purpose.md)。

---

## 8. 关键约束

1. **文件系统是唯一数据源**：SQLite 只是索引缓存，任何时刻可通过删除 `index.db` 并重启 Indexer 从文件重新生成索引
2. **Python 脚本不调 LLM**：Agent 是唯一调 LLM 的人
3. **NFS 兼容**：SQLite 必须使用 DELETE 模式（而非 WAL），避免 `.wal/.shm` 文件问题
4. **多租户隔离**：每个用户独立目录、独立 Agent、独立 Wiki

---

## 9. Indexer 冷启动机制

### 9.1 冷启动流程

Indexer 启动时自动执行以下步骤：

```
Indexer 启动
    │
    ├─→ discoverUsers() 扫描 /workspace/project/PKGM/users/ 目录
    │    条件：有 content/ 子目录的目录视为有效用户
    │
    ├─→ 对每个用户启动 chokidar 监控
    │    ignoreInitial: false  ← 首次扫描会触发所有已有文件
    │
    ├─→ awaitWriteFinish 配置
    │    stabilityThreshold: 300ms
    │    pollInterval: 100ms
    │
    └─→ ready 事件后输出 "scan complete"
```

### 9.2 discoverUsers 实现

```javascript
function discoverUsers() {
    if (!fs.existsSync(USERS_ROOT)) return [];
    return fs.readdirSync(USERS_ROOT).filter(d => {
        const p = path.join(USERS_ROOT, d);
        return fs.statSync(p).isDirectory() && fs.existsSync(path.join(p, 'content'));
    });
}
```

**用户发现规则**：
- 扫描 `/workspace/project/PKGM/users/` 下的所有目录
- 必须有 `content/` 子目录才算有效用户
- 纯目录（无 content/）会被忽略

### 9.3 首次索引（ignoreInitial: false）

**行为**：
- 冷启动时，chokidar 会触发所有现有文件的 `add` 事件
- 每个 `.md` 文件都会被标记为 `upsert`
- 200ms 防抖后批量写入 SQLite

**日志输出**：
```
[Indexer] Starting, discovered 2 user(s): alice, bob
[Indexer] Watching user: alice → /workspace/project/PKGM/users/alice/content
[Indexer] alice: scan complete
[Indexer] Watching user: bob → /workspace/project/PKGM/users/bob/content
[Indexer] bob: scan complete
```

### 9.4 新用户感知

**Indexer 如何发现新用户**：
- Indexer 启动时执行 `discoverUsers()` 扫描已有用户
- 启动后每隔 `DISCOVERY_INTERVAL_MS`（默认 15 秒）轮询一次 `users/` 目录
- 发现新用户后自动启动 chokidar 监控，无需重启容器
- 新用户内容首次写入时触发 Indexer 的 `add` 事件，自动索引

**推荐流程**：
```bash
# 创建新用户后，无需任何操作
# Indexer 会在 15 秒内自动发现并开始监控
```

**日志输出**：
```
[Indexer] Discovered new user(s): charlie
[Indexer] Watching user: charlie → /workspace/project/PKGM/users/charlie/content
[Indexer] charlie: scan complete
```

**配置项**：
| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| DISCOVERY_INTERVAL_MS | 15000 | 新用户发现轮询间隔（毫秒） |

---

## 9. 相关文档

| 文档 | 路径 | 说明 |
|------|------|------|
| [SYSTEM-ARCHITECTURE-OVERVIEW](../SYSTEM-ARCHITECTURE-OVERVIEW.md) | PKGM 总览 | 三项目联合架构 |
| [PKGM-Wiki 架构](https://github.com/code-yeongyu/pkgm/blob/main/PKGM-Wiki/docs/ARCHITECTURE.md) | PKGM-Wiki | 知识管线详细设计 |

---

## 10. 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| V1.0 | 2026-04-22 | 初始版本（单租户架构） |
| V2.0 | 2026-04-23 | 重写对齐多租户三项目架构，补充 Frontmatter 规范 |
| V2.1 | 2026-04-23 | 补充 Indexer 动态用户发现机制（P0-1） |

---

*本文档为 PKGM 系统的核心架构参考，对齐 SYSTEM-ARCHITECTURE-OVERVIEW.md 总览文档。*
*知识管线详细设计参见 PKGM-Wiki 项目文档。*
