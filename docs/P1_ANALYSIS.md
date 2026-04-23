# PKGM P1 问题分析报告

**日期**: 2026-04-24
**状态**: 分析完成，待评审

---

## 0. 背景与上下文

### 当前系统状态

| 组件 | 文件 | 当前实现 |
|------|------|---------|
| JWT 工具 | `web/src/lib/auth.ts` | ✅ `createToken()` / `verifyToken()` 已实现 |
| 认证中间件 | 不存在 | ❌ 无 |
| API 认证 | `route.ts` | ❌ 使用 `x-user-id` header（Nginx 注入，未验证） |
| SSE 认证 | `events/route.ts` | ❌ 完全无认证 |
| 跨项目依赖 | `create-agent/SKILL.md` | ❌ 调用 `/workspace/project/PKGM-Wiki/...` |
| 健康检查 | `indexer/index.js` | ❌ 无 `/health` 端点 |
| NFS 安全 | - | ❌ 无原子写入工具/基准测试 |

---

## P1-1 分析：API 认证方案评估

### 方案对比

| 方案 | 优点 | 缺点 | 推荐度 |
|------|------|------|--------|
| **A. Next.js Middleware** (方案推荐) | 统一入口、可拦截所有请求、可注入 header | 需要改写所有 API 路由 | ⭐⭐⭐⭐ |
| B. 各路由独立验证 | 简单直接 | 代码重复、容易遗漏 | ⭐⭐ |
| C. 独立认证服务 | 扩展性强 | 架构复杂、引入新依赖 | ⭐ |

### 我的评估

**方案 A 基本可行**，但有以下建议修改：

1. **SSE 端点认证特殊处理**：SSE 是长连接，token 验证应该在连接建立时做，不能每个事件都验证。建议在 `GET /api/events` 时验证一次，存储验证状态。

2. **INDEXER_SECRET 方案合理**：POST `/api/events` 需要验证调用方是 Indexer，这个设计是正确的。

3. **x-authenticated-user 覆盖机制**：建议保留 `x-user-id` 作为可选备用，但 Middleware 应该优先使用自己验证的结果。

4. **缺失 `/api/users` 处理**：方案中 `GET /api/users` 需要返回当前认证用户的信息，不是所有用户列表（这涉及多租户隔离）。

### 风险提示

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| 破坏性变更 | 现有前端可能不携带 token | 需要实现登录流程或渐进式迁移 |
| Token 管理 | 需要安全存储和刷新机制 | 使用 httpOnly cookie |
| 性能影响 | Middleware 增加 ~5ms | 可接受范围内 |

---

## P1-2 分析：脚本内联方案评估

### 当前状态确认

```bash
# create-agent/SKILL.md 第 29-32 行
从 `/workspace/project/PKGM-Wiki/skills/pkgm/scripts/init_user_wiki.sh` 初始化用户级 PKGM Wiki：
bash /workspace/project/PKGM-Wiki/skills/pkgm/scripts/init_user_wiki.sh {username}
```

确实存在跨项目物理依赖。

### 方案评估

**方案可行**，但建议：

1. **脚本同步机制**：建议在两个脚本顶部添加注释说明"此脚本与 PKGM-Manager 副本同步，修改时需同步更新"。

2. **不需要 PKGM-Wiki 中的副本**：方案保留 PKGM-Wiki 中的副本是不必要的。PKGM-Manager 应该是唯一来源，PKGM-Wiki 的脚本可以删除或标记为"已废弃，请使用 PKGM-Manager 中的版本"。

3. **测试要点**：验证新用户创建时 Wiki 目录结构完整。

### 影响评估

| 方面 | 说明 |
|------|------|
| 工作量 | 小（复制 50 行脚本） |
| 风险 | 低 |
| 收益 | 高（解除跨项目耦合） |

---

## P1-3 分析：NFS 安全方案评估

### 当前实现缺失

1. **无健康检查端点**：Indexer 没有 `/health` 端点
2. **无原子写入工具**：Agent 写入直接使用 `fs.writeFileSync`，没有原子写入封装
3. **无基准测试**：没有 NFS 并发测试脚本

### 方案评估

| 组件 | 评估 | 建议 |
|------|------|------|
| `atomic_write.py` | 实用 | 建议改为 Node.js 版本（保持技术栈一致） |
| NFS 健康检查 | 有价值 | 建议简化为"写测试文件 + 读回验证"即可 |
| 基准测试 | 有价值 | 建议作为独立工具，不强制集成到生产代码 |

### 技术建议

1. **Python → Node.js**：建议用 Node.js 实现 atomic_write，保持技术栈统一：
```javascript
function atomicWrite(filepath, content) {
    const dir = path.dirname(filepath);
    const tmpPath = path.join(dir, `.tmp_${Date.now()}`);
    fs.writeFileSync(tmpPath, content);
    fs.fsyncSync(fs.openSync(tmpPath, 'r'));
    fs.renameSync(tmpPath, filepath);
}
```

2. **健康检查简化**：
```javascript
// 每 5 分钟检查一次
setInterval(() => {
    const testFile = path.join(USERS_ROOT, `.health_${Date.now()}`);
    try {
        fs.writeFileSync(testFile, 'test');
        const content = fs.readFileSync(testFile, 'utf-8');
        if (content !== 'test') throw new Error('mismatch');
        fs.unlinkSync(testFile);
        nfsHealthStatus = 'ok';
    } catch (e) {
        nfsHealthStatus = 'error';
    }
}, 5 * 60 * 1000);
```

3. **watchedUsers 暴露**：当前 `watchedUsers` 是局部变量，需要通过闭包或模块级变量暴露给健康检查。

---

## 1. 改进建议优先级

| 优先级 | 问题 | 理由 | 建议工作流 |
|--------|------|------|-----------|
| **高** | P1-2 脚本依赖 | 纯复制，无破坏性风险 | 立即执行 |
| **中** | P1-3 健康检查 | 可观测性增强 | 快速实施 |
| **中** | P1-3 原子写入 | 数据安全 | 建议实施 |
| **低** | P1-3 基准测试 | 运维工具，非生产代码 | 可延后 |
| **高** | P1-1 认证 | 破坏性变更，需要登录流程 | 架构设计后再实施 |

---

## 2. 改进实施计划

### Phase 1: P1-2 脚本内联（1 天）

**目标**：消除跨项目依赖

**步骤**：
1. 创建 `PKGM-Manager/manager/scripts/init_user_wiki.sh`
2. 更新 `create-agent/SKILL.md` 路径引用
3. 更新 `PKGM-Manager/docs/ARCHITECTURE.md`
4. 测试验证

### Phase 2: P1-3 健康检查 + 原子写入（1 天）

**目标**：提升可观测性和数据安全

**步骤**：
1. 在 `indexer/index.js` 添加 `/health` 端点
2. 创建 `PKGM-Wiki/scripts/atomic_write.js`（Node.js 版本）
3. 更新相关文档

### Phase 3: P1-1 认证中间件（3-5 天）

**目标**：实现完整的 JWT 认证

**步骤**：
1. 创建 `middleware.ts`
2. 更新所有 API 路由使用 `x-authenticated-user`
3. 实现登录 API（`/api/login`）
4. 前端集成 token 管理
5. 更新文档

---

## 3. 资源评估

| 问题 | 预计工作量 | 风险 |
|------|-----------|------|
| P1-1 | 3-5 人天 | 中（破坏性变更） |
| P1-2 | 0.5 人天 | 低 |
| P1-3 | 1-2 人天 | 低 |

---

## 4. 建议修改汇总

### P1-1 建议

1. SSE 端点在连接建立时验证一次，存储验证状态
2. Middleware 优先使用自己验证的 username
3. `GET /api/users` 返回当前认证用户信息（不是所有用户列表）
4. 准备登录流程或渐进式迁移方案

### P1-2 建议

1. 脚本顶部添加"需同步"注释
2. PKGM-Wiki 中的脚本标记为废弃

### P1-3 建议

1. 原子写入用 Node.js 实现
2. 健康检查简化为写-读验证
3. 基准测试作为独立工具

---

*分析完成，等待评审后开始实施*