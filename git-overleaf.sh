#!/bin/bash
set -e

# ===============================
# 权限检查
# ===============================
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  请使用 sudo 或以 root 用户运行此脚本！"
    exit 1
fi

# ===============================
# 配置参数
# ===============================
# Overleaf Docker 容器名
CONTAINER_NAME="sharelatex"

# Overleaf 项目编译目录
OVERLEAF_DIR="/var/lib/overleaf/data/compiles/690328c2699fd9794f6d8988-690328a5699fd9794f6d8968"

# 宿主机本地 Git 仓库目录
LOCAL_REPO="/root/thesis_local"

# GitHub SSH 仓库地址
GIT_REPO="git@github.com:hionwi/thesis.git"

# commit message，默认 "Update thesis"
COMMIT_MSG="${1:-Update thesis}"

# ===============================
# 在容器内执行同步脚本
# ===============================
docker exec "$CONTAINER_NAME" bash -c "
set -e

# 1️⃣ 创建本地仓库（如果不存在）
if [ ! -d \"$LOCAL_REPO/.git\" ]; then
    mkdir -p \"$LOCAL_REPO\"
    git init \"$LOCAL_REPO\"
    git -C \"$LOCAL_REPO\" config user.name \"Yunxiao Tian\"
    git -C \"$LOCAL_REPO\" config user.email \"tyunxiao@qq.com\"
    git -C \"$LOCAL_REPO\" remote add origin \"$GIT_REPO\"
    git -C \"$LOCAL_REPO\" branch -M main
fi

# 2️⃣ 将 Overleaf 文件同步到本地仓库（忽略 output* 和 .git）
rsync -av --exclude=\"output*\" --exclude=\".git\" \"$OVERLEAF_DIR/\" \"$LOCAL_REPO/\"

# 3️⃣ 添加文件并提交
git -C \"$LOCAL_REPO\" add .
if git -C \"$LOCAL_REPO\" diff --cached --quiet; then
    echo \"没有新的修改，跳过提交。\"
else
    git -C \"$LOCAL_REPO\" commit -m \"$COMMIT_MSG\"
    echo \"✅ 已提交修改：$COMMIT_MSG\"
fi

# 4️⃣ 推送到 GitHub
git -C \"$LOCAL_REPO\" push -f origin main

echo \"🚀 已成功同步到 GitHub！\"
"
