#!/usr/bin/env bash
set -uo pipefail

# 路径配置
KISSAT_BIN="/home/richard/project/kissat/build/kissat"
APPLY_SCRIPT="/home/richard/project/neurobranch_simp/python/apply.py"
SAT_ROOT="/home/richard/project/SAT_benchmark/SATLIB"
RESULTS_CSV="/home/richard/project/kissat/neurobranch_simp_results.csv"

# Python 解释器（如果 apply.py 有 shebang 且可执行，也可以改成直接 "$APPLY_SCRIPT"）
PYTHON_BIN="python3"

# 可选：检查必要文件是否存在
if [[ ! -x "$KISSAT_BIN" ]]; then
  echo "错误：找不到可执行的 kissat: $KISSAT_BIN" >&2
  exit 1
fi

if [[ ! -f "$APPLY_SCRIPT" ]]; then
  echo "错误：找不到 apply.py: $APPLY_SCRIPT" >&2
  exit 1
fi

if [[ ! -d "$SAT_ROOT" ]]; then
  echo "错误：找不到 SAT 根目录: $SAT_ROOT" >&2
  exit 1
fi

echo "开始批量求解 SAT 实例..."
echo "SAT 根目录: $SAT_ROOT"
echo "结果 CSV:   $RESULTS_CSV"
echo

# 遍历所有子目录下的 .cnf 文件
find "$SAT_ROOT" -type f -name '*.cnf' -print0 | while IFS= read -r -d '' cnf_file; do
  if [[ -f "$RESULTS_CSV" ]]; then
    if awk -F',' -v name="$cnf_file" '$1 == name {found=1; exit} END {exit !found}' "$RESULTS_CSV"; then
      echo "跳过已求解文件: $cnf_file"
      continue
    fi
  fi

  echo "---------------------------------------------"
  echo "开始求解文件: $cnf_file"
  echo "启动 neurobranch_simp (apply.py)..."

  # 后台启动神经网络进程
  "$PYTHON_BIN" "$APPLY_SCRIPT" &
  APPLY_PID=$!

  # 给 apply.py 一点时间完成初始化（共享内存等）
  sleep 2

  echo "启动 kissat 求解当前 CNF..."
  "$KISSAT_BIN" "$cnf_file"
  KISSAT_STATUS=$?

  echo "kissat 结束，退出码: $KISSAT_STATUS"
  echo "终止 neurobranch_simp (PID=$APPLY_PID)..."

  # 杀掉 apply.py
  if kill -0 "$APPLY_PID" 2>/dev/null; then
    kill "$APPLY_PID" 2>/dev/null || true
    # 再等一小会，必要时强制 kill -9
    sleep 1
    if kill -0 "$APPLY_PID" 2>/dev/null; then
      echo "apply.py 未正常退出，使用 kill -9..."
      kill -9 "$APPLY_PID" 2>/dev/null || true
    fi
  fi

  echo "当前 CNF 处理完成: $cnf_file"
  echo

  # 此处不修改 CSV，假定 kissat/neurobranch 自己负责往 CSV 里追加记录
done

echo "所有 CNF 文件处理完毕。"