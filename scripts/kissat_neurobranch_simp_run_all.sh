#!/usr/bin/env bash
set -uo pipefail

# 路径配置
KISSAT_BIN="/home/richard/project/kissat/build/kissat"
APPLY_SCRIPT="/home/richard/project/neurobranch_simp/python/apply.py"
SAT_ROOT="/home/richard/project/SAT_benchmark/SATLIB"
RESULTS_CSV="/home/richard/project/kissat/neurobranch_simp_results.csv"
ERROR_CSV="/home/richard/project/kissat/neurobranch_simp_error.csv"

# Python 解释器
PYTHON_BIN="python3"

# 超时相关配置
TIME_LIMIT=600    # 单个实例最大运行时间（秒）
KILL_GRACE=5     # timeout 先发 SIGTERM，KILL_GRACE 秒后再 SIGKILL

# 禁止生成 core 文件，避免崩溃时写 core 卡住
ulimit -c 0

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

echo "开始批量求解 SAT 实例（kissat + neurobranch_simp）..."
echo "SAT 根目录: $SAT_ROOT"
echo "结果 CSV:   $RESULTS_CSV"
echo "错误 CSV:   $ERROR_CSV"
echo

# 遍历所有子目录下的 .cnf 文件
find "$SAT_ROOT" -type f -name '*.cnf' -print0 | while IFS= read -r -d '' cnf_file; do
  # 若已经在结果 CSV 的第一列中出现过，则跳过
  if [[ -f "$RESULTS_CSV" ]]; then
    if awk -F',' -v name="$cnf_file" '$1 == name {found=1; exit} END {exit !found}' "$RESULTS_CSV"; then
      echo "跳过已求解文件: $cnf_file"
      continue
    fi
  fi

  # 若已经在错误 CSV 的第一列中出现过（TIMEOUT/CRASH 等），也跳过
  if [[ -f "$ERROR_CSV" ]]; then
    if awk -F',' -v name="$cnf_file" '$1 == name {found=1; exit} END {exit !found}' "$ERROR_CSV"; then
      echo "跳过已记录错误的文件: $cnf_file"
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

  echo "启动 kissat 求解当前 CNF（带超时: ${TIME_LIMIT}s）..."

  # 用 timeout 限制单个实例运行时间
  timeout -k "${KILL_GRACE}s" "${TIME_LIMIT}s" \
    "$KISSAT_BIN" "$cnf_file"
  KISSAT_STATUS=$?

  echo "kissat 结束，原始退出码: $KISSAT_STATUS"
  echo "终止 neurobranch_simp (PID=$APPLY_PID)..."

  # 无论 kissat 正常 / 超时 / 崩溃，都要先结束 apply.py
  if kill -0 "$APPLY_PID" 2>/dev/null; then
    kill "$APPLY_PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$APPLY_PID" 2>/dev/null; then
      echo "apply.py 未正常退出，使用 kill -9..."
      kill -9 "$APPLY_PID" 2>/dev/null || true
    fi
  fi

  # 1) 超时
  if (( KISSAT_STATUS == 124 )); then
    echo "警告: $cnf_file 求解超时 (> ${TIME_LIMIT}s)，已被 timeout 终止，跳过该实例。"
    echo "$cnf_file,TIMEOUT" >> "$ERROR_CSV"
    echo "当前 CNF 处理完成（超时）: $cnf_file"
    echo
    continue
  fi

  # 2) 被信号终止（如 SIGSEGV / SIGABRT 等）
  if (( KISSAT_STATUS >= 128 )); then
    signal=$((KISSAT_STATUS - 128))
    echo "警告: kissat 在 $cnf_file 上被信号 $signal 终止 (exit=$KISSAT_STATUS)，跳过该实例。"
    echo "$cnf_file,CRASH(signal=$signal)" >> "$ERROR_CSV"
    echo "当前 CNF 处理完成（崩溃）: $cnf_file"
    echo
    continue
  fi

  # 3) 其他异常退出码（既不是 SAT=10, 也不是 UNSAT=20, 也不是 0）
  if (( KISSAT_STATUS != 0 && KISSAT_STATUS != 10 && KISSAT_STATUS != 20 )); then
    echo "警告: kissat 在 $cnf_file 上异常退出 (exit=$KISSAT_STATUS)，跳过该实例。"
    echo "$cnf_file,ERROR(exit=$KISSAT_STATUS)" >> "$ERROR_CSV"
    echo "当前 CNF 处理完成（异常退出）: $cnf_file"
    echo
    continue
  fi

  # 4) 正常结束
  echo "kissat 正常结束，退出码: $KISSAT_STATUS"
  echo "当前 CNF 处理完成: $cnf_file"
  echo

  # 这里仍然不直接修改 RESULTS_CSV，假定 kissat/neurobranch_simp
  # 在内部负责向 RESULTS_CSV 追加记录。

done

echo "所有 CNF 文件处理完毕。"