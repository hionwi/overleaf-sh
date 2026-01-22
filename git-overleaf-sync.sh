#!/bin/bash
set -e

# ===============================
# 🎨 颜色与格式配置
# ===============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ===============================
# 🛡️ 权限与依赖检查
# ===============================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}⚠️  请使用 sudo 或以 root 用户运行此脚本！${NC}"
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo -e "${RED}⚠️  未检测到 GitHub CLI (gh)。${NC}"
    echo -e "为了自动创建仓库，在宿主机安装 gh 并登录：'sudo gh auth login'"
    sudo apt install gh && sudo gh auth login
    exit 1
fi

# ===============================
# ⚙️ 配置参数
# ===============================
CONTAINER_NAME="sharelatex"
DB_FILE="/root/overleaf.db"
COMMIT_MSG="${1:-Update thesis}"

# ===============================
# 📂 1. 检查 Overleaf 编译目录
# ===============================
echo -e "${BLUE}🔍 正在扫描 Overleaf 容器内的编译目录...${NC}"

# 获取容器内的项目列表
PROJECT_IDS=$(docker exec "$CONTAINER_NAME" bash -c "ls /var/lib/overleaf/data/compiles/" 2>/dev/null || true)

# 检查目录是否为空
if [ -z "$PROJECT_IDS" ]; then
    echo -e "${RED}❌ 错误：/var/lib/overleaf/data/compiles/ 目录为空或无法访问。${NC}"
    exit 1
fi

# 确保数据库文件存在
if [ ! -f "$DB_FILE" ]; then
    touch "$DB_FILE"
    echo -e "${YELLOW}⚠️  数据库文件不存在，已创建空的 $DB_FILE${NC}"
fi

# ===============================
# 📊 2. 构建项目菜单
# ===============================
declare -a OPTION_IDS
declare -a OPTION_LABELS
declare -a OPTION_REPOS
declare -a OPTION_STATUS

echo -e "\n${CYAN}📋 检测到以下 Overleaf 项目：${NC}"
RAW_DATA="序号#项目 ID#项目标识#GitHub 仓库"

INDEX=1
for ID in $PROJECT_IDS; do
    # 在 DB 中查找该 ID
    DB_ENTRY=$(grep "^$ID" "$DB_FILE" || true)

    SHORT_ID=${ID%%-*}

    if [ -n "$DB_ENTRY" ]; then
        LABEL=$(echo "$DB_ENTRY" | awk '{print $2}')
        REPO=$(echo "$DB_ENTRY" | awk '{print $3}')
        
        OPTION_IDS+=("$ID")
        OPTION_LABELS+=("$LABEL")
        OPTION_REPOS+=("$REPO")
        OPTION_STATUS+=("EXISTING")

        RAW_DATA+="\n$INDEX#$SHORT_ID#${GREEN}$LABEL${NC}#$REPO"
        
    else
        OPTION_IDS+=("$ID")
        OPTION_LABELS+=("未配置")
        OPTION_REPOS+=("待创建")
        OPTION_STATUS+=("NEW")

        RAW_DATA+="\n$INDEX#$SHORT_ID#${RED}未配置${NC}#---"
        
    fi
    ((INDEX++))
done

echo -e "$RAW_DATA" | column -t -s "#"


# ===============================
# ⌨️ 3. 用户选择项目
# ===============================
echo -e "\n${YELLOW}请输入项目的序号 (1-$((${#OPTION_IDS[@]}))): ${NC}"
read -r SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#OPTION_IDS[@]}" ]; then
    echo -e "${RED}❌ 无效的选择，脚本退出。${NC}"
    exit 1
fi

IDX=$((SELECTION-1))
SELECTED_ID="${OPTION_IDS[$IDX]}"
SELECTED_STATUS="${OPTION_STATUS[$IDX]}"
CURRENT_LABEL="${OPTION_LABELS[$IDX]}"

# ===============================
# 🎮 4. 选择操作模式 (同步/删除)
# ===============================
echo -e "\n${CYAN}对项目 [$SELECTED_ID] ($CURRENT_LABEL) 执行什么操作？${NC}"
echo -e "  [1] 🔄 同步 (Sync to GitHub)"
echo -e "  [2] 🗑️  删除 (Delete Data & Config)"
read -r -p "请输入选项 (1/2): " ACTION

# ===============================
# 🚨 模式 A: 删除操作
# ===============================
if [ "$ACTION" == "2" ]; then
    echo -e "\n${RED}⚠️  危险操作警告！${NC}"
    echo -e "即将执行以下删除操作："
    echo -e "  1. 从 $DB_FILE 中移除配置"
    echo -e "  2. 删除容器内 Git 仓库: /root/$SELECTED_ID"
    echo -e "  3. 删除容器内编译目录: /var/lib/overleaf/data/compiles/$SELECTED_ID"
    
    read -r -p "确认删除吗？请输入 'y' 继续: " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "已取消。"
        exit 0
    fi

    echo -e "${BLUE}🧹 正在清理...${NC}"

    # 1. 从 DB 删除 (使用 sed 原地编辑)
    # 匹配以 SELECTED_ID 开头的行并删除
    sed -i "/^$SELECTED_ID/d" "$DB_FILE"
    echo -e "✅ 已从 $DB_FILE 移除记录。"

    # 2. 删除容器内目录
    # 这里的 rm -rf 非常强力，确保 ID 变量不为空
    if [ -n "$SELECTED_ID" ]; then
        docker exec "$CONTAINER_NAME" bash -c "rm -rf /root/$SELECTED_ID"
        echo -e "✅ 已删除容器内 Git 镜像 (/root/$SELECTED_ID)。"

        docker exec "$CONTAINER_NAME" bash -c "rm -rf /var/lib/overleaf/data/compiles/$SELECTED_ID"
        echo -e "✅ 已删除容器内编译目录 (/var/lib/overleaf/data/compiles/$SELECTED_ID)。"
    else
        echo -e "${RED}❌ 错误：项目 ID 为空，跳过文件删除以防误删。${NC}"
    fi

    echo -e "${GREEN}🎉 删除完成！${NC}"
    exit 0
fi

# ===============================
# 🚀 模式 B: 同步操作 (原有逻辑)
# ===============================
if [ "$ACTION" != "1" ] && [ -n "$ACTION" ]; then
    echo -e "${RED}❌ 无效选项。${NC}"
    exit 1
fi

# --- 下面是原有的同步逻辑 ---

if [ "$SELECTED_STATUS" == "NEW" ]; then
    echo -e "\n${YELLOW}🆕 检测到新项目，开始配置流程...${NC}"
    read -p "请输入该项目的自定义标识 (例如 master_thesis): " USER_LABEL
    if [ -z "$USER_LABEL" ]; then
        echo -e "${RED}标识不能为空！${NC}"
        exit 1
    fi

    echo -e "${BLUE}🛠️  正在使用 gh CLI 创建私有仓库 '$USER_LABEL'...${NC}"
    GH_USER=$(gh api user -q ".login")
    
    if gh repo create "$USER_LABEL" --private; then
        echo -e "${GREEN}✅ 仓库创建成功！${NC}"
    else
        echo -e "${RED}❌ 仓库创建失败 (可能已存在?)。${NC}"
        read -p "是否继续使用已存在的同名仓库? (y/n): " CONTINUE
        if [ "$CONTINUE" != "y" ]; then exit 1; fi
    fi

    GIT_REPO_URL="git@github.com:$GH_USER/$USER_LABEL.git"
    echo "$SELECTED_ID $USER_LABEL $GIT_REPO_URL" >> "$DB_FILE"
    echo -e "${GREEN}✅ 已将配置写入 $DB_FILE${NC}"

    FINAL_LABEL="$USER_LABEL"
    FINAL_REPO="$GIT_REPO_URL"

else
    FINAL_LABEL="${OPTION_LABELS[$IDX]}"
    FINAL_REPO="${OPTION_REPOS[$IDX]}"
    echo -e "\n${GREEN}✅ 选中已配置项目: $FINAL_LABEL${NC}"
fi

# 准备变量传给 Docker
OVERLEAF_DIR="/var/lib/overleaf/data/compiles/$SELECTED_ID"
LOCAL_REPO="/root/$SELECTED_ID"
GIT_REPO="$FINAL_REPO"

echo -e "${BLUE}🚀 开始同步...${NC}"

# 在容器内执行同步脚本
docker exec "$CONTAINER_NAME" bash -c "
set -e
GREEN='\033[0;32m'
NC='\033[0m'

if ! command -v rsync &> /dev/null; then
    apt-get update && apt-get install -y rsync
fi

if [ ! -d \"$LOCAL_REPO/.git\" ]; then
    echo \"⚙️  初始化本地 Git 仓库...\"
    git config --global --add safe.directory \"$LOCAL_REPO\"
    mkdir -p \"$LOCAL_REPO\"
    git init \"$LOCAL_REPO\"
    echo ".project-sync-state" > "$LOCAL_REPO/.gitignore"
    git -C \"$LOCAL_REPO\" config user.name \"Overleaf Sync Bot\"
    git -C \"$LOCAL_REPO\" config user.email \"bot@overleaf.local\"
    git -C \"$LOCAL_REPO\" remote add origin \"$GIT_REPO\"
    git -C \"$LOCAL_REPO\" branch -M main
fi

echo \"📦 正在执行 rsync...\"
rsync -av --exclude=\"output*\" --exclude=\".git\" \"$OVERLEAF_DIR/\" \"$LOCAL_REPO/\"

git -C \"$LOCAL_REPO\" add .
if git -C \"$LOCAL_REPO\" diff --cached --quiet; then
    echo \"⚠️  没有新的修改，跳过提交。\"
else
    git -C \"$LOCAL_REPO\" commit -m \"$COMMIT_MSG\"
    echo -e \"\${GREEN}✅ 已提交修改：$COMMIT_MSG\${NC}\"
fi

echo \"⬆️  正在推送到 GitHub...\"
git -C \"$LOCAL_REPO\" push -f origin main

echo -e \"\${GREEN}🚀 成功完成所有同步操作！\${NC}\"
"