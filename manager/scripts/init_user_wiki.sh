#!/bin/bash
# init_user_wiki.sh — 为多租户用户初始化 PKGM Wiki 目录骨架
#
# 维护说明:
#   此脚本是 PKGM-Manager 专用版本，与 PKGM-Wiki/skills/pkgm/scripts/init_user_wiki.sh
#   为同步副本。修改此脚本时需要同步更新 PKGM-Wiki 中的原版。
#
# 同步检查清单:
#   - 目录结构变更已同步
#   - 知识领域列表（D01-D12）已同步
#   - 脚本参数和输出格式已同步
#
# 最后同步日期: 2026-04-24

set -e

USERNAME="${1:-}"
WIKI_ROOT="${2:-/workspace/project/PKGM/users}/${USERNAME}/content/app/wiki"

if [ -z "$USERNAME" ]; then
    echo "[pkgm-wiki] 错误: 必须提供用户名"
    echo "用法: $0 <username> [wiki_root]"
    exit 1
fi

echo "[pkgm-wiki] 为用户 ${USERNAME} 初始化 Wiki 目录到: ${WIKI_ROOT}"

# 创建一级目录（与单用户 PKGM 一致的结构）
mkdir -p "${WIKI_ROOT}"/{00_Raw_Sources,01_Wiki,02_System,03_Engine,04_Knowledge,06_Mynotes}

# 00_Raw_Sources 子目录
mkdir -p "${WIKI_ROOT}/00_Raw_Sources"/{papers,articles,urls,inbox}

# 01_Wiki 子目录（多租户版本的 Wiki 内容）
mkdir -p "${WIKI_ROOT}/01_Wiki"/{concepts,entities,papers,architectures,experiments,topics,sources}
echo "# ${USERNAME} 的知识库

## 健康度仪表板

" > "${WIKI_ROOT}/01_Wiki/index.md"

# 02_System 子目录（用户级配置和模板）
mkdir -p "${WIKI_ROOT}/02_System"/{templates,prompts,skills,schema}

# 03_Engine 子目录（缓存和日志）
mkdir -p "${WIKI_ROOT}/03_Engine"/{cache/ingest,cache/analysis,cache/link,logs,scripts}

# 04_Knowledge 子目录（按知识领域）
for domain in D01-GPU_Architecture D02-CPU_Architecture D03-Compilers D04-Programming_Languages D05-System_Architecture D06-Hardware_Verification D07-CNN_Accelerator D08-RNN_Accelerator D09-Transformer D10-Quantum_Computing D11-Operating_System D12-Distributed_Systems; do
    mkdir -p "${WIKI_ROOT}/04_Knowledge/${domain}"
done

# 05_Project 子目录（项目知识）
mkdir -p "${WIKI_ROOT}/05_Project"

# 06_Mynotes 子目录（原创思考）
mkdir -p "${WIKI_ROOT}/06_Mynotes"/{architecture,decisions,experiments,reflections}

# 07_Research 子目录（创作性研究）
mkdir -p "${WIKI_ROOT}/07_Research"/{proposals,published,_pending,_templates}

echo "[pkgm-wiki] 用户 ${USERNAME} Wiki 目录骨架初始化完成:"
find "${WIKI_ROOT}" -maxdepth 2 -type d | sort

# 输出用户 Wiki 根路径供后续使用
echo ""
echo "[pkgm-wiki] 用户 ${USERNAME} 的 Wiki 根目录: ${WIKI_ROOT}"