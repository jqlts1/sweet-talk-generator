#!/bin/bash

# --- 配置区域 ---
# 你的本地分支
MY_BRANCH="dev"
# 模板的上游分支
TARGET_BRANCH="dev"
# 默认的上游模板地址
DEFAULT_UPSTREAM_URL="git@github.com:jqlts1/my-shipany-project-2.git"
# 项目标识符 (用于检测是否是模板 Clone)
TEMPLATE_IDENTIFIER="jqlts1/my-shipany-project-2"
LEGACY_TEMPLATE_IDENTIFIER="shipanyai/shipany-template-two"

# --- 保护目录 ---
PROTECTED_PATHS=(
    ".claude/skills/shipany-page-builder"
    "public/imgs"
    "src/shared/blocks/common/mdx-content.tsx"
    "source.config.ts"
    "src/app/sitemap.ts"
    "src/app/[locale]/(landing)/page.tsx"
    "src/config/locale/index.ts"
)

echo "========================================"
echo "🛠️  正在检查仓库环境..."
echo "========================================"

# --- 1. 检查/初始化 Git ---
if [ ! -d ".git" ]; then
    echo "⚠️  未检测到 Git 仓库，正在初始化..."
    git init
    git branch -M $MY_BRANCH
    
    echo "🔗 添加默认上游: $DEFAULT_UPSTREAM_URL"
    git remote add upstream "$DEFAULT_UPSTREAM_URL"
    git fetch upstream
    git reset --mixed "upstream/$TARGET_BRANCH"
    git add .
    git commit -m "Initial setup: Sync with upstream template"
    echo "✅ 初始化完成。"
else
    echo "✅ Git 已就绪。"
fi

# --- 2. 确保 Upstream 存在 ---
if ! git remote | grep -q "upstream"; then
    echo "⚠️  未检测到 upstream，正在添加..."
    git remote add upstream "$DEFAULT_UPSTREAM_URL"
    echo "✅ Upstream 已添加。"
fi

# --- 3. 智能处理 Origin ---
ORIGIN_URL=$(git remote get-url origin 2>/dev/null)
echo "🔍 当前 Origin 地址: ${ORIGIN_URL:-'无'}"

# 检测逻辑：
# 只要 Origin URL 包含 'jqlts1/my-shipany-project-2' (忽略 git@ 或 https 前缀)
# 或者包含原始模板 'shipanyai/shipany-template-two'
# 我们就认为它是从模板 Clone 的，需要重置 Origin。
if [[ "$ORIGIN_URL" == *"$TEMPLATE_IDENTIFIER"* ]] || [[ "$ORIGIN_URL" == *"$LEGACY_TEMPLATE_IDENTIFIER"* ]]; then
    echo "⚠️  检测到 Origin 指向了模板仓库 (匹配到关键词)。"
    echo "🔧 正在移除旧 Origin，以便创建你的新仓库..."
    git remote remove origin
fi

# --- 4. 自动创建新仓库 ---
if ! git remote | grep -q "origin"; then
    echo "----------------------------------------"
    echo "⚠️  未检测到远程仓库 (Origin)。"
    echo "🤖 尝试自动创建新仓库..."
    
    if command -v gh &> /dev/null; then
        if gh auth status &> /dev/null; then
            REPO_NAME=$(basename "$PWD")
            echo "   目标仓库名: $REPO_NAME"
            
            # 尝试创建公开仓库 (Public)
            # 如果想创建私有，请把 --public 改为 --private
            if gh repo create "$REPO_NAME" --public --source=. --remote=origin; then
                echo "🎉 GitHub 仓库 '$REPO_NAME' 创建成功！"
            else
                echo "❌ 自动创建失败。"
                echo "   可能原因：仓库名已存在，或网络问题。"
                echo "   请检查上方错误信息，或手动运行: gh repo create $REPO_NAME --public --source=. --remote=origin"
                exit 1
            fi
        else
            echo "❌ GitHub CLI 未登录。请运行 'gh auth login' 登录后再试。"
            exit 1
        fi
    else
        echo "❌ 未安装 'gh' 工具。无法自动建库。"
        echo "   (Mac用户推荐运行: brew install gh)"
        exit 1
    fi
    echo "----------------------------------------"
else
    echo "✅ 远程仓库 (Origin) 已存在: $(git remote get-url origin)"
fi

echo ""

# --- 5. 保护现场 ---
if [ -n "$(git status --porcelain)" ]; then
    echo "📦 自动保存本地修改..."
    git add .
    git commit -m "chore: save local changes before sync"
fi

TEMP_BACKUP_DIR=$(mktemp -d)
HAS_PROTECTED_FILES=false

if [ ${#PROTECTED_PATHS[@]} -gt 0 ]; then
    echo "🛡️  备份受保护文件..."
    for path in "${PROTECTED_PATHS[@]}"; do
        if [ -e "$path" ]; then
            tar -rf "$TEMP_BACKUP_DIR/protected.tar" "$path" 2>/dev/null
            HAS_PROTECTED_FILES=true
        fi
    done
fi

# --- 6. 同步核心 ---
echo ""
echo "🔄 拉取 Upstream 更新..."

CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
if [ "$CURRENT_BRANCH" != "$MY_BRANCH" ]; then
    git checkout -b $MY_BRANCH 2>/dev/null || git checkout $MY_BRANCH
fi

if git pull upstream $TARGET_BRANCH --rebase -Xtheirs; then
    echo "✅ 代码同步成功。"
else
    echo "❌ 同步冲突，尝试恢复备份..."
    if [ "$HAS_PROTECTED_FILES" = true ]; then
        tar -xf "$TEMP_BACKUP_DIR/protected.tar"
    fi
    exit 1
fi

# --- 7. 恢复现场 ---
if [ "$HAS_PROTECTED_FILES" = true ]; then
    echo "🛡️  恢复受保护文件..."
    tar -xf "$TEMP_BACKUP_DIR/protected.tar"
    
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        git commit -m "chore: restore protected paths"
        echo "✨ 已强制回滚受保护的本地文件。"
    fi
    rm -rf "$TEMP_BACKUP_DIR"
fi

# --- 8. 推送 ---
echo ""
echo "🚀 推送到 Origin..."
if git push origin $MY_BRANCH --force; then
    echo "🎉--------------------------------------🎉"
    echo "  同步完成！"
    echo "  仓库地址: $(git remote get-url origin)"
    echo "🎉--------------------------------------🎉"
else
    echo "❌ 推送失败。"
    echo "   如果提示 'Repository not found'，说明 Origin 地址无效或无权限。"
    exit 1
fi
