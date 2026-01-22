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
DB_FILE="overleaf.db"
COMMIT_MSG="${1:-Update thesis}"

# ===============================
# 📂 1. 检查 Overleaf 编译目录
# ===============================
echo -e "${BLUE}🔍 正在扫描 Overleaf 容器内的编译目录...${NC}"

# 获取容器内的项目列表
PROJECT_IDS=$(docker exec "$CONTAINER_NAME" bash -c "ls /var/lib/overleaf/data/compiles/")

# 检查目录是否为空
if [ -z "$PROJECT_IDS" ]; then
    echo -e "${RED}❌ 错误：/var/lib/overleaf/data/compiles/ 目录为空。没有任何项目。${NC}"
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
# 定义数组存储选项
declare -a OPTION_IDS
declare -a OPTION_LABELS
declare -a OPTION_REPOS
declare -a OPTION_STATUS # "EXISTING" or "NEW"

echo -e "\n${CYAN}📋 检测到以下 Overleaf 项目：${NC}"
printf "%-4s | %-30s | %-20s | %-40s\n" "序号" "项目 ID" "项目标识" "GitHub 仓库"
echo "----------------------------------------------------------------------------------------------------"

INDEX=1
# 遍历 Docker 中发现的每一个 ID
for ID in $PROJECT_IDS; do
    # 在 DB 中查找该 ID
    # DB 格式: ID  LABEL  REPO_URL
    DB_ENTRY=$(grep "^$ID" "$DB_FILE" || true)

    if [ -n "$DB_ENTRY" ]; then
        # 如果在 DB 中找到了
        LABEL=$(echo "$DB_ENTRY" | awk '{print $2}')
        REPO=$(echo "$DB_ENTRY" | awk '{print $3}')
        STATUS="EXISTING"
        
        OPTION_IDS+=("$ID")
        OPTION_LABELS+=("$LABEL")
        OPTION_REPOS+=("$REPO")
        OPTION_STATUS+=("EXISTING")
        
        printf "%-4s | %-30s | ${GREEN}%-20s${NC} | %-40s\n" "$INDEX" "$ID" "$LABEL" "$REPO"
    else
        # 如果是新项目
        STATUS="NEW"
        
        OPTION_IDS+=("$ID")
        OPTION_LABELS+=("未配置")
        OPTION_REPOS+=("待创建")
        OPTION_STATUS+=("NEW")
        
        printf "%-4s | %-30s | ${RED}%-20s${NC} | %-40s\n" "$INDEX" "$ID" "未配置 (新项目)" "---"
    fi
    ((INDEX++))
done

echo "----------------------------------------------------------------------------------------------------"

# ===============================
# ⌨️ 3. 用户选择与处理
# ===============================
echo -e "${YELLOW}请输入要同步的项目的序号 (1-$((${#OPTION_IDS[@]}))): ${NC}"
read -r SELECTION

# 验证输入
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#OPTION_IDS[@]}" ]; then
    echo -e "${RED}❌ 无效的选择，脚本退出。${NC}"
    exit 1
fi

# 获取数组索引 (选择 - 1)
IDX=$((SELECTION-1))
SELECTED_ID="${OPTION_IDS[$IDX]}"
SELECTED_STATUS="${OPTION_STATUS[$IDX]}"

# ===============================
# 🔄 分支处理
# ===============================

if [ "$SELECTED_STATUS" == "NEW" ]; then
    echo -e "\n${YELLOW}🆕 检测到新项目，开始配置流程...${NC}"
    echo -e "项目 ID: $SELECTED_ID"
    
    # 1. 获取用户自定义标识
    read -p "请输入该项目的自定义标识 (例如 master_thesis): " USER_LABEL
    if [ -z "$USER_LABEL" ]; then
        echo -e "${RED}标识不能为空！${NC}"
        exit 1
    fi

    # 2. 自动创建 GitHub Private 仓库
    echo -e "${BLUE}🛠️  正在使用 gh CLI 创建私有仓库 '$USER_LABEL'...${NC}"
    
    # 尝试创建仓库 (如果已存在会报错，这里假设名字不冲突或用户能处理)
    # 获取当前用户的 GitHub 用户名
    GH_USER=$(gh api user -q ".login")
    
    if gh repo create "$USER_LABEL" --private; then
        echo -e "${GREEN}✅ 仓库创建成功！${NC}"
    else
        echo -e "${RED}❌ 仓库创建失败 (可能已存在?)。${NC}"
        read -p "是否继续使用已存在的同名仓库? (y/n): " CONTINUE
        if [ "$CONTINUE" != "y" ]; then exit 1; fi
    fi

    # 构造 SSH 地址
    GIT_REPO_URL="git@github.com:$GH_USER/$USER_LABEL.git"
    echo -e "仓库地址: $GIT_REPO_URL"

    # 3. 写入 overleaf.db
    echo "$SELECTED_ID $USER_LABEL $GIT_REPO_URL" >> "$DB_FILE"
    echo -e "${GREEN}✅ 已将配置写入 $DB_FILE${NC}"

    # 设置后续变量
    FINAL_LABEL="$USER_LABEL"
    FINAL_REPO="$GIT_REPO_URL"

else
    # 也就是 EXISTING
    FINAL_LABEL="${OPTION_LABELS[$IDX]}"
    FINAL_REPO="${OPTION_REPOS[$IDX]}"
    echo -e "\n${GREEN}✅ 选中已配置项目: $FINAL_LABEL${NC}"
fi

# ===============================
# 🚀 4. 执行同步 (Docker 内部)
# ===============================

# 准备变量传给 Docker
OVERLEAF_DIR="/var/lib/overleaf/data/compiles/$SELECTED_ID"
LOCAL_REPO="/root/$SELECTED_ID"
GIT_REPO="$FINAL_REPO"

echo -e "${BLUE}🚀 开始同步...${NC}"
echo "-----------------------------------"
echo "源目录: $OVERLEAF_DIR"
echo "目标库: $GIT_REPO"
echo "-----------------------------------"

# 在容器内执行同步脚本
docker exec "$CONTAINER_NAME" bash -c "
set -e

# 定义颜色
GREEN='\033[0;32m'
NC='\033[0m'

# 检查 rsync
if ! command -v rsync &> /dev/null; then
    apt-get update && apt-get install -y rsync
fi

# 1️⃣ 创建本地仓库（如果不存在）
if [ ! -d \"$LOCAL_REPO/.git\" ]; then
    echo \"⚙️  初始化本地 Git 仓库...\"
    git config --global --add safe.directory \"$LOCAL_REPO\"
    mkdir -p \"$LOCAL_REPO\"
    git init \"$LOCAL_REPO\"
    git -C \"$LOCAL_REPO\" config user.name \"Overleaf Sync Bot\"
    git -C \"$LOCAL_REPO\" config user.email \"bot@overleaf.local\"
    git -C \"$LOCAL_REPO\" remote add origin \"$GIT_REPO\"
    git -C \"$LOCAL_REPO\" branch -M main
fi

# 2️⃣ 同步文件 (忽略 output, .git 等)
echo \"📦 正在执行 rsync...\"
rsync -av --exclude=\"output*\" --exclude=\".git\" \"$OVERLEAF_DIR/\" \"$LOCAL_REPO/\"

# 3️⃣ 提交
git -C \"$LOCAL_REPO\" add .
if git -C \"$LOCAL_REPO\" diff --cached --quiet; then
    echo \"⚠️  没有新的修改，跳过提交。\"
else
    git -C \"$LOCAL_REPO\" commit -m \"$COMMIT_MSG\"
    echo -e \"\${GREEN}✅ 已提交修改：$COMMIT_MSG\${NC}\"
fi

# 4️⃣ 推送
# 注意：容器内必须有能访问 GitHub 的 SSH 私钥 (/root/.ssh/id_rsa)
echo \"⬆️  正在推送到 GitHub...\"
git -C \"$LOCAL_REPO\" push -f origin main

echo -e \"\${GREEN}🚀 成功完成所有同步操作！\${NC}\"
"