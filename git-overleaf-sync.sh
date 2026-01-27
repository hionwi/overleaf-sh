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
    sudo apt update && sudo apt install -y gh && sudo gh auth login
    exit 1
fi

# ===============================
# ⚙️ 配置参数
# ===============================
CONTAINER_NAME="sharelatex"
DB_FILE="/root/overleaf.db"
COMMIT_MSG="${1:-Update thesis}"
CURRENT_TIME=$(date "+%Y-%m-%d_%H:%M")

# ===============================
# 📂 1. 检查 Overleaf 编译目录
# ===============================
echo -e "${BLUE}🔍 正在扫描 Overleaf 容器内的编译目录...${NC}"

PROJECT_IDS=$(docker exec "$CONTAINER_NAME" bash -c "ls /var/lib/overleaf/data/compiles/" 2>/dev/null || true)

if [ -z "$PROJECT_IDS" ]; then
    echo -e "${RED}❌ 错误：/var/lib/overleaf/data/compiles/ 目录为空或无法访问。${NC}"
    exit 1
fi

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
# 更新表头，加入“最后同步时间”
RAW_DATA="序号#项目 ID#项目标识#最后同步时间#GitHub 仓库"

INDEX=1
for ID in $PROJECT_IDS; do
    DB_ENTRY=$(grep "^$ID" "$DB_FILE" || true)
    SHORT_ID=${ID:0:8} # 截取前8位方便查看

    if [ -n "$DB_ENTRY" ]; then
        LABEL=$(echo "$DB_ENTRY" | awk '{print $2}')
        REPO=$(echo "$DB_ENTRY" | awk '{print $3}')
        # 获取第4列时间戳，如果没有则显示“无记录”
        LAST_SYNC=$(echo "$DB_ENTRY" | awk '{print $4}')
        LAST_SYNC=${LAST_SYNC:-"从未同步"}
        
        OPTION_IDS+=("$ID")
        OPTION_LABELS+=("$LABEL")
        OPTION_REPOS+=("$REPO")
        OPTION_STATUS+=("EXISTING")

        RAW_DATA+="\n$INDEX#$SHORT_ID#${GREEN}$LABEL${NC}#${YELLOW}$LAST_SYNC${NC}#$REPO"
    else
        OPTION_IDS+=("$ID")
        OPTION_LABELS+=("未配置")
        OPTION_REPOS+=("待创建")
        OPTION_STATUS+=("NEW")

        RAW_DATA+="\n$INDEX#$SHORT_ID#${RED}未配置${NC}#---#---"
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
# 🎮 4. 选择操作模式
# ===============================
echo -e "\n${CYAN}对项目 [$SELECTED_ID] ($CURRENT_LABEL) 执行什么操作？${NC}"
echo -e "  [1] 🔄 同步 (Sync to GitHub)"
echo -e "  [2] 🗑️  删除 (Delete Data & Config)"
read -r -p "请输入选项 (1/2): " ACTION

if [ "$ACTION" == "2" ]; then
    echo -e "\n${RED}⚠️  危险操作警告！${NC}"
    read -r -p "确认从数据库和容器中彻底删除项目 $SELECTED_ID 吗？(y/n): " CONFIRM
    if [ "$CONFIRM" == "y" ]; then
        sed -i "/^$SELECTED_ID/d" "$DB_FILE"
        docker exec "$CONTAINER_NAME" bash -c "rm -rf /root/$SELECTED_ID /var/lib/overleaf/data/compiles/$SELECTED_ID"
        echo -e "${GREEN}✅ 清理完成。${NC}"
    fi
    exit 0
fi

# ===============================
# 🚀 5. 同步逻辑
# ===============================
if [ "$SELECTED_STATUS" == "NEW" ]; then
    read -p "请输入该项目的自定义标识 (例如 master_thesis): " USER_LABEL
    [ -z "$USER_LABEL" ] && exit 1

    echo -e "${BLUE}🛠️  正在创建 GitHub 仓库...${NC}"
    GH_USER=$(gh api user -q ".login")
    gh repo create "$USER_LABEL" --private || true
    
    GIT_REPO_URL="git@github.com:$GH_USER/$USER_LABEL.git"
    # 初始化写入：ID LABEL REPO TIME
    echo "$SELECTED_ID $USER_LABEL $GIT_REPO_URL $CURRENT_TIME" >> "$DB_FILE"
    
    FINAL_LABEL="$USER_LABEL"
    FINAL_REPO="$GIT_REPO_URL"
else
    FINAL_LABEL="${OPTION_LABELS[$IDX]}"
    FINAL_REPO="${OPTION_REPOS[$IDX]}"
    # 同步前更新数据库中的时间戳
    sed -i "s|^$SELECTED_ID $FINAL_LABEL $FINAL_REPO.*|$SELECTED_ID $FINAL_LABEL $FINAL_REPO $CURRENT_TIME|" "$DB_FILE"
fi

OVERLEAF_DIR="/var/lib/overleaf/data/compiles/$SELECTED_ID"
LOCAL_REPO="/root/$SELECTED_ID"

echo -e "${BLUE}🚀 正在同步至 $FINAL_REPO ...${NC}"

# Docker 执行部分保持不变...
docker exec "$CONTAINER_NAME" bash -c "
set -e
if ! command -v rsync &> /dev/null; then apt-get update && apt-get install -y rsync; fi
if [ ! -d \"$LOCAL_REPO/.git\" ]; then
    git config --global --add safe.directory \"$LOCAL_REPO\"
    mkdir -p \"$LOCAL_REPO\"
    git init \"$LOCAL_REPO\"
    git -C \"$LOCAL_REPO\" config user.name \"Overleaf Sync Bot\"
    git -C \"$LOCAL_REPO\" config user.email \"bot@overleaf.local\"
    git -C \"$LOCAL_REPO\" remote add origin \"$FINAL_REPO\"
    git -C \"$LOCAL_REPO\" branch -M main
fi
rsync -av --exclude=\"output*\" --exclude=\".git\" \"$OVERLEAF_DIR/\" \"$LOCAL_REPO/\"
git -C \"$LOCAL_REPO\" add .
if ! git -C \"$LOCAL_REPO\" diff --cached --quiet; then
    git -C \"$LOCAL_REPO\" commit -m \"$COMMIT_MSG\"
    git -C \"$LOCAL_REPO\" push -f origin main
    echo -e \"\033[0;32m✅ 同步成功！\033[0m\"
else
    echo \"⚠️  没有内容更新。\"
fi
"