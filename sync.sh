#!/bin/bash

# --- 配置区域 ---
# 你的本地分支
MY_BRANCH="dev"
# 模板的上游分支
TARGET_BRANCH="dev"
# 默认的上游模板地址 (当前项目的地址)
DEFAULT_UPSTREAM_URL="git@github.com:jqlts1/my-shipany-project-2.git"

# --- [关键配置] 保护目录 ---
# 这些目录下的文件在同步时会被"冻结"
# 无论上游模板怎么改，这些目录都会被强制恢复成你本地的样子
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
    
    echo "🔗 添加默认上游 (Template): $DEFAULT_UPSTREAM_URL"
    git remote add upstream "$DEFAULT_UPSTREAM_URL"
    
    echo "📥 获取模板历史..."
    git fetch upstream
    
    echo "🔄 重置本地到模板状态..."
    git reset --mixed "upstream/$TARGET_BRANCH"
    
    echo "📦 提交当前状态..."
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

# --- 3. 智能处理 Origin (Github CLI) ---
ORIGIN_URL=$(git remote get-url origin 2>/dev/null)

# 子串匹配：只要 origin 包含默认上游地址，就认为是模板 clone 下来的
# 注意：这里我们放宽了匹配，只要包含项目名即可，以兼容 git@ 和 https:// 以及可能的后缀
if [[ "$ORIGIN_URL" == *"jqlts1/my-shipany-project-2"* ]]; then
    echo "⚠️  检测到 origin 指向了模板仓库 ($ORIGIN_URL)。"
    echo "� 正在移除旧 origin..."
    git remote remove origin
fi

if ! git remote | grep -q "origin"; then
    echo "⚠️  未检测到远程仓库 (Origin)。"
    
    if command -v gh &> /dev/null; then
        if gh auth status &> /dev/null; then
            echo "🤖 正在使用 GitHub CLI 自动创建仓库..."
            # 获取当前文件夹名作为仓库名
            REPO_NAME=$(basename "$PWD")
            
            # 创建公开仓库 (Public) - 因为这是模板项目通常是开源的，或者根据之前脚本是 public
            # 如果需要私有，可以改回 --private
            if gh repo create "$REPO_NAME" --public --source=. --remote=origin; then
                echo "🎉 GitHub 仓库 '$REPO_NAME' 创建成功！"
            else
                echo "❌ 自动创建失败，请手动处理。"
                echo "   可能原因：仓库名已存在，或网络问题。"
                echo "   请运行: git remote add origin <你的git地址>"
                exit 1
            fi
        else
            echo "⚠️  GitHub CLI 未登录 (运行 'gh auth login')。"
        fi
    else
        echo "ℹ️  未安装 gh 工具，跳过自动建库。"
        echo "   请手动创建仓库并运行: git remote add origin <URL>"
    fi
fi

echo ""

# --- 4. 保护现场 ---
# 在拉取之前，必须保证工作区是干净的
if [ -n "$(git status --porcelain)" ]; then
    echo "📦 检测到未提交的修改，正在自动保存..."
    git add .
    git commit -m "chore: save local changes before sync"
fi

TEMP_BACKUP_DIR=$(mktemp -d)
HAS_PROTECTED_FILES=false

echo "🛡️  正在备份受保护的文件..."
for path in "${PROTECTED_PATHS[@]}"; do
    if [ -e "$path" ]; then
        # 使用 tar 备份，保留目录结构
        tar -rf "$TEMP_BACKUP_DIR/protected.tar" "$path" 2>/dev/null
        HAS_PROTECTED_FILES=true
        echo "   - 已锁定: $path"
    fi
done

# --- 5. 同步核心 (Rebase) ---
echo ""
echo "🔄 正在拉取模板更新 (Rebase)..."

# 确保在正确的分支
CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
if [ "$CURRENT_BRANCH" != "$MY_BRANCH" ]; then
    echo "🔀 切换到分支 $MY_BRANCH..."
    git checkout -b $MY_BRANCH 2>/dev/null || git checkout $MY_BRANCH
fi

# 执行 Rebase
# -Xtheirs 表示如果有冲突，优先保留"模板"的修改 
# (因为我们已经备份了受保护的文件，稍后会覆盖回来)
if git pull upstream $TARGET_BRANCH --rebase -Xtheirs; then
    echo "✅ 核心代码已更新。"
else
    echo "❌ 同步遇到严重冲突，请手动解决。"
    # 尝试恢复备份以便用户手动处理
    if [ "$HAS_PROTECTED_FILES" = true ]; then
        tar -xf "$TEMP_BACKUP_DIR/protected.tar"
    fi
    exit 1
fi

# --- 6. 恢复现场 ---
if [ "$HAS_PROTECTED_FILES" = true ]; then
    echo ""
    echo "🛡️  正在恢复受保护文件..."
    tar -xf "$TEMP_BACKUP_DIR/protected.tar"
    
    if [ -n "$(git status --porcelain)" ]; then
        echo "✨ 发现模板试图修改受保护文件，已强制回滚。"
        git add .
        git commit -m "chore: restore protected paths after sync"
    else
        echo "✅ 受保护文件无变动。"
    fi
    rm -rf "$TEMP_BACKUP_DIR"
fi

# --- 7. 推送 ---
echo ""
echo "🚀 推送到远程仓库..."

# 如果 origin 刚刚被移除且没有重建成功，这里会失败，所以加个检查
if git remote | grep -q "origin"; then
    if git push origin $MY_BRANCH --force; then
        echo ""
        echo "🎉--------------------------------------🎉"
        echo "  同步完成！项目已升级到最新版。"
        echo "  仓库地址: $(git remote get-url origin)"
        echo "🎉--------------------------------------🎉"
    else
        echo "❌ 推送失败，请检查权限。"
        exit 1
    fi
else
    echo "⚠️  未检测到 origin，跳过推送。"
    echo "   请手动添加 origin 后推送: git remote add origin <URL>"
fi
