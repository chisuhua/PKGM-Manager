# PKGM-Web 认证架构设计

**日期**: 2026-04-24
**状态**: 评审中
**版本**: V1.0

---

## 1. 当前状态分析

### 1.1 现有实现

| 组件 | 状态 | 说明 |
|------|------|------|
| `auth.ts` (JWT 工具) | ✅ 存在 | `createToken()`, `verifyToken()` 已实现 |
| Token 存储 | ❌ 不存在 | 未使用 cookie 或 localStorage |
| 登录 API | ❌ 不存在 | 无 `/api/login` 端点 |
| Middleware | ❌ 不存在 | 无认证中间件 |
| 页面保护 | ❌ 不存在 | 无登录页 |

### 1.2 当前安全风险

```
当前系统: 任何人可直接访问以下端点
├── GET /api/users        → 获取所有用户及文档列表
├── GET /api/doc?user=a&path=x  → 获取用户 A 的任意文档
├── GET /api/search?user=a&q=x  → 搜索用户 A 的文档
└── GET /api/events        → SSE 连接（无验证）
```

**风险**: 用户 A 可以通过修改 URL 参数访问用户 B 的数据。

---

## 2. 认证架构设计

### 2.1 设计原则

1. **简化优先**: 当前是内部工具系统，暂不需要复杂密码认证
2. **Cookie 存储**: JWT 存储在 httpOnly cookie，防止 XSS
3. **渐进式**: 先实现基础认证，再考虑 SSO/OAuth
4. **多租户隔离**: 用户只能访问自己的数据

### 2.2 认证流程

```
┌─────────────────────────────────────────────────────────────┐
│                     用户登录流程                            │
└─────────────────────────────────────────────────────────────┘

用户浏览器                    PKGM-Web                    Indexer
    │                           │                            │
    │  GET / (无 cookie)         │                            │
    │──────────────────────────>│                            │
    │                           │                            │
    │  返回登录页               │                            │
    │<──────────────────────────│                            │
    │                           │                            │
    │  POST /api/login           │                            │
    │  { username: "alice" }     │                            │
    │──────────────────────────>│                            │
    │                           │──GET /users───────────────>│
    │                           │<──["alice", "bob"]────────│
    │                           │                            │
    │                           │ 验证用户存在               │
    │                           │ 生成 JWT                   │
    │                           │                            │
    │  Set-Cookie: pkgm-token=xxx│                            │
    │<──────────────────────────│                            │
    │                           │                            │
    │  后续请求自动携带 cookie   │                            │
    │──────────────────────────>│                            │
    │                           │  Middleware 验证 JWT        │
    │                           │  注入 x-authenticated-user │
    │                           │                            │
```

### 2.3 Token 管理

| 属性 | 值 | 说明 |
|------|-----|------|
| 存储位置 | httpOnly Cookie | 防止 XSS 攻击 |
| Cookie 名称 | `pkgm-token` | |
| 有效期 | 24 小时 | 过期后需重新登录 |
| 传输方式 | 自动随同源请求发送 | 浏览器自动处理 |
| Secure | 生产环境开启 | HTTPS 传输 |

### 2.4 路由分类

| 路由 | 认证 | 说明 |
|------|------|------|
| `GET /` | 公开 | 根页面显示所有用户（公开信息） |
| `GET /login` | 公开 | 登录页 |
| `POST /api/login` | 公开 | 登录 API |
| `GET /api/users` | **需要** | 返回当前用户信息（不是所有用户） |
| `GET /api/doc` | **需要** | 验证用户只能访问自己的文档 |
| `GET /api/search` | **需要** | 验证用户只能搜索自己的文档 |
| `GET /api/events` | **需要** | SSE 订阅需认证 |
| `POST /api/events` | **需要 INDEXER_SECRET** | Indexer 回调验证 |
| `/_next/*` | 公开 | Next.js 静态资源 |
| `/docs/*` | **需要** | 文档页面需认证 |

---

## 3. API 设计

### 3.1 登录 API

**POST /api/login**

Request:
```json
{ "username": "alice" }
```

Response (成功):
```json
{ "success": true, "username": "alice" }
```
同时设置 `Set-Cookie: pkgm-token=<jwt>; HttpOnly; Path=/; Max-Age=86400`

Response (失败 - 用户不存在):
```json
{ "success": false, "error": "User not found" }
```

### 3.2 登出 API

**POST /api/logout**

Response:
```json
{ "success": true }
```
同时设置 `Set-Cookie: pkgm-token=; Max-Age=0`

### 3.3 当前用户 API

**GET /api/me**

Response:
```json
{ "username": "alice" }
```

### 3.4 受保护的 API 修改

#### GET /api/users (修改)

**原来**: 返回所有用户列表
**改为**: 返回当前认证用户的信息

```typescript
// 返回当前用户信息（不是所有用户）
{ "username": "alice", "docs": [...] }
```

#### GET /api/doc (修改)

**原来**: `?user=alice&path=/content/...`
**改为**: 无需 user 参数，从 JWT 获取

```typescript
const username = req.headers.get('x-authenticated-user');
// 仅返回当前用户的文档
```

#### GET /api/search (修改)

**原来**: `?user=alice&q=keyword`
**改为**: 无需 user 参数

---

## 4. Middleware 实现

### 4.1 中间件逻辑

```typescript
// middleware.ts
export async function middleware(req) {
    // 1. 公开路径放行
    if (isPublicPath(req.nextUrl.pathname)) {
        return NextResponse.next();
    }

    // 2. 读取 cookie 中的 token
    const token = req.cookies.get('pkgm-token')?.value;

    // 3. 验证 token
    const username = await verifyToken(token);
    if (!username) {
        // 未登录，重定向到登录页
        return NextResponse.redirect('/login');
    }

    // 4. 注入认证用户 header
    const response = NextResponse.next();
    response.headers.set('x-authenticated-user', username);
    return response;
}

export const config = {
    matcher: ['/((?!_next/static|_next/image|favicon.ico).*)']
};
```

### 4.2 路径匹配规则

| 路径 | 匹配 | 说明 |
|------|------|------|
| `/login` | ❌ | 公开 |
| `/api/login` | ❌ | 公开 |
| `/api/logout` | ❌ | 公开 |
| `/_next/*` | ❌ | 静态资源 |
| `/favicon.ico` | ❌ | 静态资源 |
| `/` | ✅ | 需要认证（显示用户信息） |
| `/docs/*` | ✅ | 需要认证 |
| `/api/*` | ✅ | 需要认证（除 login/logout） |

---

## 5. 前端页面

### 5.1 登录页 (`/login`)

```tsx
// app/login/page.tsx
'use client';

export default function Login() {
    const [username, setUsername] = useState('');
    const [error, setError] = useState('');

    async function handleSubmit(e) {
        e.preventDefault();
        const res = await fetch('/api/login', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username })
        });
        const data = await res.json();
        if (data.success) {
            window.location.href = '/';
        } else {
            setError(data.error);
        }
    }

    return (
        <form onSubmit={handleSubmit}>
            <input
                value={username}
                onChange={e => setUsername(e.target.value)}
                placeholder="Username"
            />
            <button type="submit">Login</button>
            {error && <p>{error}</p>}
        </form>
    );
}
```

### 5.2 根页面重定向 (`/`)

当前 `/` 显示所有用户，需要改为：
- 有 cookie → 显示当前用户信息
- 无 cookie → 重定向到 `/login`

```typescript
// middleware.ts 逻辑
if (req.nextUrl.pathname === '/' && !token) {
    return NextResponse.redirect('/login');
}
```

---

## 6. 安全模型

### 6.1 多租户隔离

```
用户 alice:
├── cookie: pkgm-token=<alice-jwt>
├── GET /api/users → { username: "alice", docs: [...] }
├── GET /api/doc?path=/content/... → 仅返回 alice 的文档
└── 尝试访问 bob 的路径 → 403 Forbidden

用户 bob:
├── cookie: pkgm-token=<bob-jwt>
├── GET /api/users → { username: "bob", docs: [...] }
└── 无法访问 alice 的数据
```

### 6.2 Indexer 安全

| 调用方 | 验证方式 | 说明 |
|--------|---------|------|
| 浏览器 → Web `/api/events` (POST) | INDEXER_SECRET | 防止非 Indexer 调用 |
| Web → Indexer API | Docker 内部网络 | 通过 `pkgm-net` 网络 |
| Indexer → Web `/api/events` (POST) | INDEXER_SECRET | 调用方验证 |

---

## 7. 实施计划

### Phase 1: 基础认证（1-2 天）

1. 创建 `middleware.ts`
2. 创建 `/api/login` 端点
3. 创建 `/api/logout` 端点
4. 创建 `/login` 页面
5. 修改受保护的 API 路由

### Phase 2: 数据隔离（0.5 天）

1. 修改 `/api/users` 返回当前用户信息
2. 修改 `/api/doc` 使用 JWT 中的用户
3. 修改 `/api/search` 使用 JWT 中的用户

### Phase 3: 文档页面保护（0.5 天）

1. 修改 `/docs/[user]` 页面验证访问权限
2. Middleware 中添加用户路径匹配验证

---

## 8. 替代方案考虑

### 方案 B: 密码认证

如需密码认证：

```typescript
// POST /api/login
{ "username": "alice", "password": "xxx" }
```

缺点：增加复杂度，需要存储密码 hash

### 方案 C: SSO/OAuth

如需对接 Google/GitHub 登录：

- 使用 NextAuth.js
- 需要公网 HTTPS
- 超出当前需求范围

---

## 9. 结论

**推荐实施**: 方案 A（简化认证）

- 当前系统是内部工具，用户已通过 PKGM-Manager 创建
- 暂不需要密码认证，用户名验证即可
- 未来需要时可以渐进式增加

**风险**: 低（内部系统，公开部署前需重新评估）

**工作量**: 约 2-3 人天

---

*评审通过后开始实施*