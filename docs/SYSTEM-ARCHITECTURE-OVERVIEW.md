# PKGM 多租户系统架构总览

**版本**: V1.0  
**创建日期**: 2026-04-22  
**状态**: 现行  

---

## 1. 系统概述

PKGM 是一个基于 LLM Agent 的个人知识管理系统，采用**多租户架构**设计。整个系统由三个独立项目组成：

| 项目 | 职责 | 定位 |
|------|------|------|
| **PKGM-Manager** | 多租户管理（创建/删除用户 Agent） | 管理平面 |
| **PKGM-Wiki** | 多租户内容生成技能 | 业务逻辑层 |
| **PKGM-Web** | 前端展示页面 | 展示平面 |

**核心设计理念**：每个用户拥有独立的 Agent、独立的内容存储目录、独立的 Wiki 知识库。

### 1.2 技术栈概览

| 组件 | 技术 | 端口 |
|------|------|------|
| OpenClaw Gateway | Agent 运行框架 | 18789 |
| PKGM-Web (Next.js) | 前端展示 | 3001 |
| PKGM-Web Indexer | 索引服务 | 3004 |

### 1.3 OpenClaw Gateway 集成

**用户与专属 Agent 的交互**：
```
用户浏览器 → OpenClaw Gateway Web UI (port 18789)
                    │
                    ▼
            专属 Agent (pkgm-{username})
                    │
                    ▼
            PKGM-Wiki 技能调用
                    │
                    ▼
            生成 Markdown 到 content/
```

**Gateway 配置**：
- Agent 注册：`openclaw agents add pkgm-{username}`
- 工作区：`/workspace/project/PKGM/users/{username}/agent-workspace/`
- 内容输出：`/workspace/project/PKGM/users/{username}/content/`

---

## 2. 系统架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              用户操作流                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PKGM-Manager (管理平面)                               │
│                                                                              │
│   ┌──────────────────────────────────────────────────────────────────────┐ │
│   │  新用户登录 → 验证 → 调用 create-agent 技能                           │ │
│   │                                                                       │ │
│   │  执行步骤：                                                           │ │
│   │  1. 创建用户目录结构                                                  │ │
│   │     /workspace/project/PKGM/users/{username}/                        │ │
│   │        ├── agent-workspace/                                          │ │
│   │        ├── content/app/wiki/  ← PKGM Wiki 骨架                       │ │
│   │        ├── assets/                                                   │ │
│   │        └── meta/                                                     │ │
│   │                                                                       │ │
│   │  2. 初始化用户专属 Agent                                              │ │
│   │     - 生成 SOUL.md                                                    │ │
│   │     - 写入 USER_PROMPT.md                                             │ │
│   │     - 注册到 OpenClaw Gateway                                         │ │
│   │                                                                       │ │
│   │  3. 初始化 PKGM Wiki 目录                                             │ │
│   │     - 调用 init_user_wiki.sh                                          │ │
│   │     - 在 content/app/wiki/ 下创建完整 PKGM 目录结构                   │ │
│   └──────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼ (专属 Agent 已就绪)
┌─────────────────────────────────────────────────────────────────────────────┐
│                      用户专属 Agent (业务逻辑层)                              │
│                                                                              │
│   ┌──────────────────────────────────────────────────────────────────────┐ │
│   │  用户对话 → 调用 PKGM-Wiki 技能                                   │ │
│   │                                                                       │ │
│   │  PKGM-Wiki 工作流：                                              │ │
│   │  1. 读取输入素材 (URL/PDF/文本)                                       │ │
│   │     ↓                                                                 │ │
│   │  2. Ingest → Extract → Link → WikiGen                                │ │
│   │     ↓                                                                 │ │
│   │  3. 输出 Markdown 文件                                                │ │
│   │     /workspace/project/PKGM/users/{username}/content/app/wiki/       │ │
│   │        ├── 01_Wiki/concepts/*.md                                     │ │
│   │        ├── 01_Wiki/entities/*.md                                     │ │
│   │        └── ...                                                       │ │
│   └──────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼ (原子写入)
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NAS 共享存储                                         │
│         /mnt/nas/project/PKGM/users/{username}/content/                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
              ┌─────────────────────┴─────────────────────┐
              ▼                                           ▼
┌─────────────────────────────┐         ┌─────────────────────────────┐
│    PKGM-Web Indexer          │         │   PKGM-Web Next.js          │
│    (索引服务)                │         │    (前端展示)               │
│                             │         │                             │
│  - chokidar 监控 content/   │◄────────│  - HTTP POST /api/events    │
│  - 解析 Frontmatter         │         │    SSE 推送                 │
│  - @node-rs/jieba 分词      │         │                             │
│  - SQLite FTS5 索引         │         │  - GET /api/users           │
│  - HTTP API (3004)          │         │  - GET /api/doc             │
│                             │         │  - GET /api/search          │
│                             │         │  - GET /api/events (SSE)    │
└─────────────────────────────┘         └─────────────────────────────┘
              │                                           │
              ▼                                           ▼
        浏览器展示 ←─────────────── SSE 实时更新
```

---

## 3. 项目边界与接口定义

### 3.1 PKGM-Manager

**职责范围**：
- 用户生命周期管理（创建、删除、查询状态）
- 用户专属 Agent 的注册与配置
- 用户目录结构的初始化和清理

**对外接口**：

| 接口类型 | 路径/命令 | 说明 |
|---------|----------|------|
| **技能** | `create-agent` | 创建用户 Agent |
| **技能** | `delete-agent` | 删除用户 Agent |
| **技能** | `manage-session` | 管理用户会话 |
| **技能** | `query-status` | 查询系统状态 |

**数据产出**：
- `/workspace/project/PKGM/users/{username}/` - 用户根目录
- `/workspace/project/PKGM/users/{username}/agent-workspace/SOUL.md` - 用户 Agent 身份定义
- `/workspace/project/PKGM/users/{username}/content/app/wiki/` - 用户 Wiki 骨架

**依赖项**：
- OpenClaw Gateway (`agents add`, `gateway restart`)
- `init_user_wiki.sh` 脚本

**不负责的领域**：
- ❌ 内容生成逻辑
- ❌ 前端展示
- ❌ 索引服务

---

### 3.2 PKGM-Wiki (原 pkgm-wiki-gen)

**职责范围**：
- 接收用户输入的素材（URL/PDF/文本）
- 执行 PKGM 知识管线（Ingest → Extract → Link → WikiGen）
- 输出符合 Schema 的 Markdown Wiki 页面

**对外接口**：

| 接口类型 | 说明 |
|---------|------|
| **调用者** | 用户专属 Agent（通过对话触发） |
| **输入** | URL、PDF 文件、文本内容 |
| **输出** | `/workspace/project/PKGM/users/{username}/content/app/wiki/` 下的 Markdown 文件 |

**数据契约**：

**输入**：
```yaml
素材类型：url | pdf | text
上下文：当前用户的工作目录
```

**输出**：
```markdown
/workspace/project/PKGM/users/{username}/content/app/wiki/01_Wiki/{concepts,entities,...}/*.md
```

**Frontmatter 规范**：
```yaml
---
title: "页面标题"
type: concept | paper | person | ...
domain: "D01"  # 知识领域 ID
source_type: primary | secondary
confidence: 1-5
created_at: ISO8601
updated_at: ISO8601
version: 1
relations:
  depends_on:
    - "[[关联页面]]"
---
```

**依赖项**：
- `../PKGM-Wiki/schema.yaml` - 实体/关系 Schema
- `../PKGM-Wiki/purpose.md` - 知识领域定义
- Python 脚本层（pkgm_*.py）

**不负责的领域**：
- ❌ 用户创建和管理
- ❌ 前端展示和搜索
- ❌ 索引服务

---

### 3.3 PKGM-Web

**职责范围**：
- 提供多租户 Web 界面
- 渲染 Markdown 文档
- 提供全文搜索
- SSE 实时推送更新

**对外接口**：

**API 路由**：
| 路由 | 方法 | 说明 |
|------|------|------|
| `/api/users` | GET | 获取所有用户及其文档列表 |
| `/api/doc?user={username}&path={path}` | GET | 获取单篇文档 |
| `/api/search?user={username}&q={query}` | GET | 搜索文档 |
| `/api/events` | GET | SSE 订阅端点 |
| `/api/events` | POST | Indexer 回调端点 |

**前端页面**：
| 路径 | 说明 |
|------|------|
| `/` | 用户列表页 |
| `/docs/{username}` | 用户文档列表 |
| `/docs/{username}?path={encoded_path}` | 文档详情页 |

**数据消费**：
- 从 Indexer HTTP API 获取文档数据
- 从 SSE 接收实时更新

**依赖项**：
- Indexer HTTP API (port 3004)
- 用户目录 `/workspace/project/PKGM/users/{username}/content/`

**不负责的领域**：
- ❌ 用户创建和管理
- ❌ 内容生成逻辑
- ❌ 仅负责展示，不修改内容

---

## 4. 完整使用流程

### 4.1 用户注册初始化

```
系统管理员/触发器
        │
        ▼
调用 PKGM-Manager create-agent 技能
        │
        ├─→ 验证用户名唯一性
        ├─→ 创建目录结构
        │    /workspace/project/PKGM/users/{username}/
        │         ├── agent-workspace/     (Agent 工作区)
        │         ├── content/             (内容目录)
        │         │    └── app/wiki/01_Wiki/...  (Wiki 骨架)
        │         └── assets/
        ├─→ 初始化 Wiki 骨架
        │    bash init_user_wiki.sh {username}
        ├─→ 创建用户专属 Agent
        │    agent-workspace/SOUL.md
        ├─→ 注册到 OpenClaw Gateway
        │    openclaw agents add pkgm-{username}
        └─→ 重启 Gateway
        │
        ▼
注册完成，用户可访问专属 Agent
```

### 4.2 日常使用：用户与 Agent 交互

```
用户打开 OpenClaw Gateway (http://{host}:18789)
        │
        ▼
选择/切换到 pkgm-{username} Agent
        │
        ▼
与 Agent 对话

【场景 A】用户说：「帮我摄取这个链接」
        │
        ▼
Agent 调用 pkgm-url-ingest → pkgm-pipeline
        │
        ├─→ Phase 1: ingest (粗咀嚼)
        ├─→ Phase 2: extract (两阶段抽取)
        ├─→ Phase 3: link (关联)
        ├─→ Phase 4: wiki-gen (生成 Wiki 页面)
        ├─→ Phase 5: lint (质量门控)
        │
        ▼
原子写入 content/app/wiki/01_Wiki/*.md

【场景 B】用户说：「处理 00_Raw_Sources/ 下的文件」
        │
        ▼
Agent 调用 pkgm-pipeline
        │
        ▼ (同上管线流程)

【场景 C】用户问：「D01 知识领域的 GPU 架构概念」
        │
        ▼
Agent 直接读取 content/app/wiki/01_Wiki/concepts/
        │
        ▼
结合 Wiki 内容回答用户
```

### 4.3 内容自动同步到 Web 展示

```
PKGM-Wiki 写入 Markdown 文件
        │
        ▼ (原子写入：tmp → fsync → rename)
/workspace/project/PKGM/users/{username}/content/
        │
        ▼
Indexer chokidar 检测到变化
        │
        ├─→ 解析 Frontmatter
        ├─→ @node-rs/jieba 中文分词
        ├─→ 写入 SQLite FTS5
        └─→ HTTP POST /api/events (触发 SSE)
        │
        ▼
Next.js SSE 推送 → 浏览器
        │
        ▼
浏览器自动刷新，显示新文档
```

### 4.4 用户通过 Web 查看内容

```
用户打开 PKGM-Web (http://{host}:3001)
        │
        ▼
首页展示所有用户列表
        │
        ▼
点击用户名 → 查看该用户文档列表
        │
        ▼
点击文档 → 查看 Markdown 渲染内容
        │
        ▼
使用搜索框 → FTS5 全文搜索
```

### 4.5 完整数据流总图

```
┌─────────────────────────────────────────────────────────────────────┐
│                       用户操作                                      │
│  OpenClaw Gateway (:18789)                PKGM-Web (:3001)        │
└─────────────────────────────────────────────────────────────────────┘
                    │                                           ▲
                    ▼                                           │
┌───────────────────────────────────────────────────────────────┐   │
│                    用户专属 Agent                               │   │
│                  (pkgm-{username})                            │   │
│                                                               │   │
│   用户对话 ──► Agent 理解意图 ──► 调用 PKGM-Wiki 技能          │   │
│                          │                                    │   │
│                          ▼                                    │   │
│              ┌─────────────────────────┐                      │   │
│              │   PKGM-Wiki 管线         │                      │   │
│              │  ingest → extract       │                      │   │
│              │  link → wiki-gen        │                      │   │
│              │  → lint                 │                      │   │
│              └────────────┬────────────┘                      │   │
└─────────────────────────────│──────────────────────────────────┘   │
                              │ (原子写入)                          │
                              ▼                                    │
┌───────────────────────────────────────────────────────────────┐   │
│                    NAS 共享存储                                 │   │
│   /mnt/nas/project/PKGM/users/{username}/content/              │   │
└───────────────────────────────────────────────────────────────┘   │
          │                                           ▲           │
          │                                           │           │
          ▼                                           │           │
┌─────────────────────────┐    HTTP POST /api/events  │           │
│   PKGM-Web Indexer       │──────────────────────────┘           │
│   (:3004)                │                                        │
│                          │ SSE 推送                               │
│   chokidar 监控 ──► FTS5 索引                                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. 目录结构约定

### 5.1 用户根目录

```
/workspace/project/PKGM/users/{username}/
├── agent-workspace/            # 用户专属 Agent 工作区
│   ├── SOUL.md                # Agent 身份定义
│   └── ...                    # 其他配置文件
│
├── content/                    # PKGM-Web 展示的内容
│   ├── daily/                 # 日报类文档
│   ├── uploads/               # 用户上传文档
│   ├── tasks/                 # 任务类文档
│   └── app/                   # PKGM Wiki 内容
│       └── wiki/              # PKGM 多租户 Wiki 目录
│           ├── 00_Raw_Sources/
│           ├── 01_Wiki/       # Wiki 页面（concepts, entities...）
│           ├── 02_System/     # 用户级配置
│           ├── 03_Engine/     # 缓存和日志
│           ├── 04_Knowledge/  # 知识领域
│           ├── 05_Project/    # 项目知识
│           ├── 06_Mynotes/    # 原创思考
│           └── 07_Research/   # 创作研究
│
├── assets/                     # 图片和附件
└── meta/                       # SQLite 索引
    └── index.db
```

### 5.2 各项目管理目录

> **注意**：以下路径为 OpenClaw 容器内环境路径，用于说明系统结构。

```
/workspace/project/PKGM/
├── manager/                    # PKGM-Manager
│   ├── skills/
│   │   ├── create-agent/
│   │   ├── delete-agent/
│   │   └── manage-session/
│   └── templates/
│
├── docs/                       # PKGM 系统文档
│   ├── SYSTEM-ARCHITECTURE-OVERVIEW.md
│   └── ARCHITECTURE.md
│
└── users/                      # 用户数据（由 Manager 创建）
    ├── alice/
    └── bob/

/workspace/project/PKGM-Web/    # PKGM-Web
├── web/                        # Next.js 前端
├── indexer/                    # Node.js 索引服务
└── docs/
    └── ARCHITECTURE.md

/workspace/project/PKGM-Wiki/   # PKGM-Wiki (原 pkgm-wiki-gen)
├── skills/
│   ├── pkgm/
│   │   ├── subSkills/
│   │   │   ├── pkgm-ingest/
│   │   │   ├── pkgm-extract/
│   │   │   ├── pkgm-link/
│   │   │   ├── pkgm-wiki-gen/
│   │   │   └── pkgm-lint/
│   │   ├── pkgm-pipeline/
│   │   └── pkgm-architect/
│   └── pkgm-url-ingest/
│   ├── pkgm-scan/
├── scripts/
│   └── init_user_wiki.sh
├── references/
│   └── default-configs/
│       └── schema.yaml
├── purpose.md
└── docs/
    └── ARCHITECTURE.md
```

---

## 6. 独立开发指南

### 6.1 PKGM-Manager 开发者

**只需关注**：
- `manager/skills/create-agent/SKILL.md` 中的执行步骤
- 确保正确调用 `init_user_wiki.sh`
- 遵循用户目录命名规范

**不需要了解**：
- PKGM-Wiki 的具体实现细节
- PKGM-Web 的前端代码
- 索引服务的内部逻辑

**测试要点**：
- 创建用户后，检查 `content/app/wiki/` 目录是否正确初始化
- 验证 Agent 能否正常启动和对话

---

### 6.2 PKGM-Wiki 开发者

**只需关注**：
- 输入输出的数据格式（Frontmatter 规范）
- 管线各阶段（Ingest → Extract → Link → WikiGen）的实现
- 输出到正确的用户目录路径

**不需要了解**：
- 用户如何被创建和管理
- 前端如何展示生成的内容
- 索引服务的工作方式

**测试要点**：
- 输出文件的 Frontmatter 是否符合规范
- 文件是否写入正确的用户目录
 

---

### 6.3 PKGM-Web 开发者

**只需关注**：
- Indexer HTTP API 的端点和返回格式
- 前端页面的渲染逻辑
- SSE 实时更新机制

**不需要了解**：
- PKGM-Manager 如何创建用户
- PKGM-Wiki 的内容生成逻辑
- 具体的知识处理算法

**测试要点**：
- 能否正确列出用户和文档
- 搜索功能是否正常工作
- SSE 推送是否及时

---

## 7. 版本信息

**本文档版本**: V1.0  
**创建日期**: 2026-04-22  
**状态**: 现行  

*本文档为 PKGM 多租户系统的总体架构参考，各子项目开发者应依据此文档进行独立开发和集成。*
