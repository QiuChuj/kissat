#!/usr/bin/env bash
# 清理 neurobranch_simp 相关的后台进程和 SysV IPC（共享内存 + 信号量）

set -euo pipefail

echo "=== 清理 neurobranch_simp / kissat 相关进程和 IPC 资源 ==="

# 1. 杀掉 Python 端 apply.py 进程
echo "[1] 终止 Python apply.py 进程..."
pkill -f "/home/richard/project/neurobranch_simp/python/apply.py" 2>/dev/null || true

# 2. 杀掉 kissat 进程
echo "[2] 终止 kissat 进程..."
pkill -f "/home/richard/project/kissat/build/kissat" 2>/dev/null || true

# 给进程一点时间退出
sleep 1

# 再次强制 kill 一次（防止顽固进程）
pkill -9 -f "/home/richard/project/neurobranch_simp/python/apply.py" 2>/dev/null || true
pkill -9 -f "/home/richard/project/kissat/build/kissat" 2>/dev/null || true

# 3. 清理当前用户的 SysV 共享内存段
echo "[3] 清理当前用户的 SysV 共享内存段(ipcs -m)..."
ipcs -m | awk -v user="$USER" '$3 == user { print $2 }' | xargs -r ipcrm -m || true

# 4. 清理当前用户的 SysV 信号量
echo "[4] 清理当前用户的 SysV 信号量(ipcs -s)..."
ipcs -s | awk -v user="$USER" '$3 == user { print $2 }' | xargs -r ipcrm -s || true

# 5. 删掉用于 ftok 的临时文件
echo "[5] 删除 /tmp 下的 ftok 文件..."
rm -f /tmp/nn_shared /tmp/neurobranch_simp 2>/dev/null || true

echo "=== 清理完成 ==="