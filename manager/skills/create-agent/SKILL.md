# SKILL.md - create-agent

**触发条件**: 包含 "创建 Agent"/"创建用户"/"new user" 等关键词

## 执行步骤

### Step 1: 验证输入
- 必需参数：用户名
- 验证用户名格式：只允许字母数字和下划线（正则 `^[a-zA-Z0-9_]+$`）

### Step 2: 验证唯一性
```bash
test -d /workspace/project/PKGM/users/{username} && echo "EXISTS" || echo "OK"
```
- 存在 → 返回错误："用户名已存在"
- 不存在 → 继续

### Step 3: 创建目录结构
```bash
mkdir -p /workspace/project/PKGM/users/{username}/{
  agent-workspace,
  content/{daily,uploads,tasks},
  assets,
  meta
}
```

### Step 3.5: 初始化用户 Wiki 目录（PKGM 多租户）
从 `/workspace/project/PKGM-Wiki/skills/pkgm/scripts/init_user_wiki.sh` 初始化用户级 PKGM Wiki：

```bash
bash /workspace/project/PKGM-Wiki/skills/pkgm/scripts/init_user_wiki.sh {username}
```

这将在 `content/app/wiki/` 下创建完整的 PKGM 目录结构：
```
content/app/wiki/
├── 00_Raw_Sources/  # 原材料
├── 01_Wiki/         # Wiki 页面（concepts, entities, papers...）
├── 02_System/       # 用户配置和模板
├── 03_Engine/       # 缓存和日志
├── 04_Knowledge/   # 知识领域
├── 05_Project/      # 项目知识
├── 06_Mynotes/      # 原创思考
└── 07_Research/     # 创作研究
```

### Step 4: 生成 SOUL.md
- 读取 `templates/SOUL_TEMPLATE.md`
- 替换 `{username}` 和 `{role}`
- 写入 `agent-workspace/SOUL.md`

### Step 5: 注册 Agent 配置
- 通过 `openclaw agents add pkgm-{username}` 或编辑 config.json
- 配置项：id, model, workspace

### Step 6: 重启 Gateway
- `openclaw gateway restart`

### Step 7: 验证
- 检查目录结构是否完整
- 创建空 SQLite 数据库
- 验证 Agent 在线

### Step 8: 审计日志
```jsonl
{"timestamp": "...", "action": "create-agent", "username": "...", "status": "success"}
```
