# PKGM-Manager 架构文档

**版本**: v3.0  
**创建日期**: 2026-07-17  
**状态**: 设计中（待评审）  
**关联文档**:
- 全栈架构总览：`../docs/architecture/fullstack-architecture.md`（PKGM-Web 主项目）
- 展示面架构：`../docs/architecture/architecture.md`
- 业务逻辑层架构：`../PKGM-Wiki/docs/architecture/architecture.md`
- 调研文档：`../docs/research/01-auth-multi-tenant.md`, `02-object-storage-minio.md`, `04-git-forgejo.md`

---

## 1. 项目定位

PKGM-Manager 是 PKGM 系统的**控制面（Control Plane）**，负责：

- **租户生命周期管理**（创建 / 删除 / 配额调整）
- **跨基础设施编排**（调用 5 个 Provider 完成跨系统资源创建）
- **审计日志**（所有租户操作记录）
- **OpenClaw Agent 注册**（保留现有逻辑）

### 1.1 与三项目的关系

```
┌─────────────────────────────────────────────────────────────────────┐
│                     基础设施层（独立部署）                              │
│  Keycloak │ MinIO │ Temporal │ Forgejo │ Qdrant │ tusd │ ClamAV     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  控制面：PKGM-Manager（本文档）                                       │
│  - 租户生命周期（create/delete tenant）                               │
│  - 5 个 Provider 调用基础设施 API                                     │
│  - 审计日志                                                           │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  业务逻辑面：PKGM-Wiki                                              │
│  - 6 阶段管线（SKILL.md 不变）                                        │
│  - Temporal Worker 适配层                                            │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  展示面：PKGM-Web                                                   │
│  - 认证 / 搜索 / 渲染 / Webhook Gateway                              │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 核心原则

> **Provider 抽象层是 PKGM-Manager 的核心**。每个外部系统（Keycloak / MinIO / Forgejo / Temporal / Qdrant）通过 Provider 接口封装，Manager 只关心编排逻辑。  
> **事务性**。跨系统操作必须保证最终一致性——任一 Provider 失败时触发反向清理。  
> **审计可追溯**。每次操作写入 JSONL 日志，保留 ≥ 1 年。

---

## 2. 模块架构

### 2.1 Provider 抽象层

PKGM-Manager 通过 5 个 Provider 与外部基础设施交互。每个 Provider 实现统一的接口：

```python
class TenantProvider(Protocol):
    def setup(self, tenant_id: str) -> Result: ...
    def teardown(self, tenant_id: str) -> Result: ...
    def health_check(self) -> HealthStatus: ...
```

#### 2.1.1 KeycloakProvider

| 项 | 说明 |
|---|---|
| **职责** | 创建/删除 Keycloak Organization + 用户 |
| **技术路径** | 集成开源：`python-keycloak` 库 |
| **API 调用** | `POST /admin/realms/pkgm/organizations` |
| **关键约束** | Organization name = `tenant-{id}`（不可变） |

**关键文件**：
```
manager/lib/providers/keycloak_provider.py
```

**setup 流程**：
1. 创建 Organization（`name=tenant-{id}`）
2. 创建用户（`username={id}`, `email=...`）
3. 将用户加入 Organization
4. 返回 `tenant_id` + `user_id`

#### 2.1.2 MinIOProvider

| 项 | 说明 |
|---|---|
| **职责** | 验证/创建 MinIO prefix 隔离 |
| **技术路径** | 集成开源：`minio-py` 库 |
| **API 调用** | 验证 prefix 不存在（实际数据由 Pipeline 写入） |
| **关键约束** | 不创建 Bucket（使用共享 `pkgm-data` Bucket） |

**关键文件**：
```
manager/lib/providers/minio_provider.py
```

**setup 流程**：
1. 验证 `pkgm-data/{tenant_id}/` prefix 不存在
2. 返回 prefix 路径

#### 2.1.3 ForgejoProvider

| 项 | 说明 |
|---|---|
| **职责** | 创建租户私有 Repo + 注入 Deploy Key + 创建 Webhook |
| **技术路径** | 集成开源：`pyforgejo` 或 requests |
| **API 调用** | `POST /api/v1/repos/{template}/generate` + `POST /keys` + `POST /hooks` |
| **关键约束** | 模板仓库只放目录骨架，不放真实文件 |

**关键文件**：
```
manager/lib/providers/forgejo_provider.py
```

**setup 流程**：
1. 从模板生成 Repo（`owner=pkgm-tenants`, `name=tenant-{id}`, `private=true`）
2. 生成 SSH Deploy Key（`ed25519`）
3. 注入 Deploy Key 到 Repo（`read_only=false`）
4. 创建 Push Webhook（`events=["push"]`, `branch_filter=refs/heads/main`）
5. 返回 `repo_url` + `webhook_id` + `deploy_key_id`

#### 2.1.4 FilesystemProvider

| 项 | 说明 |
|---|---|
| **职责** | 创建本地用户目录 + 初始化 Wiki 骨架 |
| **技术路径** | 保留现有：`init_user_wiki.sh` |
| **关键约束** | 保持与现有 Agent 的兼容性 |

**关键文件**：
```
manager/lib/providers/filesystem_provider.py
manager/scripts/init_user_wiki.sh   # 保留
```

**setup 流程**：
1. `mkdir -p /workspace/project/PKGM/users/{tenant_id}/{agent-workspace,content,assets,meta}`
2. `bash init_user_wiki.sh {tenant_id}`
3. 返回本地目录路径

#### 2.1.5 OpenClawProvider

| 项 | 说明 |
|---|---|
| **职责** | 注册 Agent 到 OpenClaw Gateway |
| **技术路径** | 保留现有逻辑 |
| **关键约束** | 保持与现有 Agent 的兼容性 |

**关键文件**：
```
manager/lib/providers/openclaw_provider.py
```

**setup 流程**：
1. 生成 `SOUL.md`（从模板）
2. `openclaw agents add pkgm-{tenant_id}`
3. `openclaw gateway restart`
4. 返回 Agent 注册状态

---

### 2.2 租户生命周期技能

#### 2.2.1 create-tenant（替代 create-agent）

| 项 | 说明 |
|---|---|
| **技能名** | `create-tenant` |
| **触发** | 管理员调用或 API 触发 |
| **参数** | `tenant_id`（UUID）, `email`, `display_name` |
| **输出** | `TenantProvisioningResult`（包含所有 Provider 的返回信息） |

**关键文件**：
```
manager/skills/create-tenant/SKILL.md
manager/scripts/create_tenant.py
```

**执行流程**：
```
1. 验证输入（tenant_id 格式、唯一性）
2. 调用 KeycloakProvider.setup(tenant_id)
3. 调用 MinIOProvider.setup(tenant_id)
4. 调用 ForgejoProvider.setup(tenant_id)
5. 调用 FilesystemProvider.setup(tenant_id)
6. 调用 OpenClawProvider.setup(tenant_id)
7. 写入审计日志
8. 返回 TenantProvisioningResult
```

**错误处理**：
- 任一 Provider 失败 → 触发反向清理（已成功的 Provider 调用 teardown）
- 清理失败 → 记录错误日志，人工介入

#### 2.2.2 delete-tenant

| 项 | 说明 |
|---|---|
| **技能名** | `delete-tenant` |
| **触发** | 管理员调用 |
| **参数** | `tenant_id` |
| **输出** | 删除结果 |

**关键文件**：
```
manager/skills/delete-tenant/SKILL.md
manager/scripts/delete_tenant.py
```

**执行流程**：
```
1. 验证 tenant_id 存在
2. 调用 OpenClawProvider.teardown(tenant_id)
3. 调用 FilesystemProvider.teardown(tenant_id)（删除本地目录）
4. 调用 ForgejoProvider.teardown(tenant_id)（删除 Repo）
5. 调用 MinIOProvider.teardown(tenant_id)（删除 prefix）
6. 调用 KeycloakProvider.teardown(tenant_id)（删除 Organization + 用户）
7. 写入审计日志
```

#### 2.2.3 manage-quota（新增）

| 项 | 说明 |
|---|---|
| **技能名** | `manage-quota` |
| **触发** | 管理员调用 |
| **参数** | `tenant_id`, `quota_type`（storage/llm/api）, `new_limit` |
| **输出** | 配额更新结果 |

**关键文件**：
```
manager/skills/manage-quota/SKILL.md
manager/scripts/manage_quota.py
```

---

### 2.3 审计日志模块

| 项 | 说明 |
|---|---|
| **格式** | JSONL（每行一个操作记录） |
| **存储** | `manager/logs/audit.jsonl`（追加模式，不删除） |
| **保留期** | ≥ 1 年 |
| **字段** | `timestamp`, `action`, `tenant_id`, `user_id`, `resource`, `status`, `latency_ms` |

**关键文件**：
```
manager/lib/audit.py
manager/logs/audit.jsonl
```

**示例记录**：
```json
{"timestamp": "2026-07-17T10:00:00Z", "action": "create-tenant", "tenant_id": "01JABCXYZ", "user_id": "admin", "status": "success", "latency_ms": 3200}
```

---

### 2.4 健康检查模块

| 项 | 说明 |
|---|---|
| **端点** | `GET /health` |
| **实现** | 调用所有 Provider 的 `health_check()` |
| **返回** | 各 Provider 状态 + 总体健康状态 |

**关键文件**：
```
manager/scripts/health_check.py
```

---

## 3. 数据模型

### 3.1 租户注册表

PKGM-Manager 维护一个租户注册表（JSON 或 SQLite），记录每个租户的跨系统映射：

```json
{
  "tenant_id": "01JABCXYZ",
  "forgejo": {
    "owner": "pkgm-tenants",
    "repo": "tenant-01JABCXYZ",
    "default_branch": "main",
    "webhook_id": 123,
    "deploy_key_id": 456
  },
  "keycloak": {
    "organization_id": "org-...",
    "user_id": "user-..."
  },
  "minio": {
    "bucket": "pkgm-data",
    "prefix": "01JABCXYZ/"
  },
  "filesystem": {
    "local_path": "/workspace/project/PKGM/users/01JABCXYZ/"
  },
  "openclaw": {
    "agent_id": "pkgm-01JABCXYZ"
  },
  "status": "active",
  "created_at": "2026-07-17T10:00:00Z",
  "quota": {
    "storage_mb": 1024,
    "llm_tokens_per_day": 100000
  }
}
```

**关键文件**：
```
manager/data/tenants.json
```

---

## 4. 依赖清单

### 4.1 新增 Python 依赖

| 包 | 用途 |
|---|---|
| `python-keycloak` | Keycloak Admin API 客户端 |
| `minio` | MinIO 客户端 |
| `pyforgejo` 或 `requests` | Forgejo API 客户端 |
| `paramiko` | SSH Key 生成（可选） |

### 4.2 保留的依赖

| 包 | 用途 |
|---|---|
| `subprocess` | 调用 `init_user_wiki.sh` + `openclaw` 命令 |
| `json` / `sqlite3` | 租户注册表 |

---

## 5. 部署拓扑

### 5.1 Phase 0（单机原型）

PKGM-Manager 作为 OpenClaw 容器内的技能脚本运行，无需独立部署。

```
OpenClaw 容器
├── manager/skills/create-tenant/SKILL.md
├── manager/scripts/create_tenant.py
├── manager/lib/providers/*.py
└── manager/data/tenants.json
```

### 5.2 Phase 1+（生产）

- PKGM-Manager 独立容器部署
- 暴露 REST API（`POST /api/tenants`, `DELETE /api/tenants/{id}`）
- 与 Keycloak / MinIO / Forgejo 通过内网通信
- 审计日志挂载到持久化卷

---

## 6. 迁移路线图

| 阶段 | 工作 | 风险 |
|------|------|------|
| **Phase 0** | 新增 Provider 抽象层（5 个 Provider 接口定义） | 低 |
| **Phase 1** | 实现 `create-tenant` 技能（替代 `create-agent`） | 中（跨系统事务） |
| **Phase 2** | 实现 `delete-tenant` 技能 | 中（清理逻辑） |
| **Phase 3** | 实现审计日志模块 | 低 |
| **Phase 4** | 实现 `manage-quota` 技能 | 低 |
| **Phase 5** | 删除旧 `create-agent` 技能 | 低 |

---

## 7. 关键约束

1. **Provider 失败必须反向清理**：跨系统操作不能留下半成品
2. **审计日志不可变**：追加模式，不删除
3. **租户 ID 不可变**：一旦创建，不能改名（避免路径冲突）
4. **模板仓库不放真实文件**：避免每个新租户复制大量数据
5. **Deploy Key 每租户独立**：泄露影响范围最小
6. **Webhook 不可靠**：PKGM-Web 必须做 Outbox 持久化

---

## 8. 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-04-22 | 初始版本（单租户架构） |
| v2.0 | 2026-04-23 | 重写对齐多租户三项目架构 |
| v3.0 | 2026-07-17 | 全栈架构改造：引入 5 个 Provider 抽象层 |

---

*本文档为 PKGM-Manager 控制面的目标架构参考。*  
*当前状态：设计中（待评审）*