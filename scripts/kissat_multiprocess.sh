#!/bin/bash
set -u

# =============== kissat 配置文件 ===============
CONFIG_JSON="/home/richard/project/kissat/config/config.json"
PYTHON_BIN="python3"

update_kissat_config() {
    local use_neurobranch="$1"
    local train_mode="$2"
    local simple_mode="$3"
    local reinforce_mode="$4"

    "$PYTHON_BIN0" - "$CONFIG_JSON" <<EOF
import json, sys
path = sys.argv[1]
with open(path, "r") as f:
    cfg = json.load(f)

cfg["use_neurobranch"] = $use_neurobranch
cfg["train_mode"]      = $train_mode
cfg["simple_mode"]     = $simple_mode
cfg["reinforce_mode"]  = $reinforce_mode

with open(path, "w") as f:
    json.dump(cfg, f, indent=4)
EOF
}
# ================= 配置区 =================

# 1. 并行数量 (建议 = CPU核心数 - 1)
NUM_WORKERS=4

# 2. 超时设置 (必须设置，防止卡死)
TIME_LIMIT=600    # 单个实例最大运行时间（秒）
KILL_GRACE=5      # timeout 发送 SIGTERM 后等待几秒再发 SIGKILL

# 3. 路径配置
KISSAT_BIN="/home/richard/project/kissat/build/kissat"
SAT_ROOT="/home/richard/project/SAT_benchmark/SATLIB"

# 4. 主结果文件（纯 kissat 的结果 & 错误）
MAIN_RESULTS_CSV="/home/richard/project/kissat/results/kissat_results.csv"
MAIN_ERROR_CSV="/home/richard/project/kissat/results/kissat_error.csv"

# 5. 临时目录
TMP_DIR="/tmp/kissat_parallel_jobs"
mkdir -p "$TMP_DIR"

# 禁止生成 core 文件
ulimit -c 0

# 提前定义 pids 数组，方便 cleanup 使用
pids=()

# ========= Ctrl+C 清理函数和 trap =========
cleanup() {
    echo
    echo "捕获到中断信号，正在清理所有 worker 进程和临时文件..."

    # 杀掉所有 worker 子进程（如果已经启动的话）
    # 注意使用 ${pids[@]:-} 防止 set -u 下 pids 未定义时报错
    for pid in "${pids[@]:-}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done

    # 保险起见，再杀一次所有 kissat 进程
    pkill -f "$KISSAT_BIN"   2>/dev/null || true

    # 删除临时目录
    rm -rf "$TMP_DIR"

    echo "清理完成，脚本已退出。"
    exit 1
}

# 捕获 Ctrl+C (SIGINT) 和 SIGTERM
trap cleanup INT TERM
# ==========================================

# 检查必要文件
if [[ ! -x "$KISSAT_BIN" ]]; then
    echo "错误：找不到 kissat: $KISSAT_BIN"
    exit 1
fi

# 纯 kissat 模式设置：
# {
#   "use_neurobranch": 0,
#   "train_mode": 0,
#   "simple_mode": 0,
#   "reinforce_mode": 0
# }
update_kissat_config 0 0 0 0

echo "=== 开始并行求解 (Workers: $NUM_WORKERS) ==="

# ---------------------------------------------------------
# 第一步：任务扫描与去重 (加载主 CSV 到内存)
# ---------------------------------------------------------
echo "正在扫描并去重..."
ALL_TASKS_FILE="$TMP_DIR/all_tasks.txt"
TO_DO_FILE="$TMP_DIR/todo_tasks.txt"

declare -A PROCESSED

# 加载主结果和主错误日志
for csv in "$MAIN_RESULTS_CSV" "$MAIN_ERROR_CSV"; do
    if [[ -f "$csv" ]]; then
        while IFS=, read -r col1 _; do
            [[ -z "$col1" || "$col1" == "filename" ]] && continue
            PROCESSED["$col1"]=1
        done < "$csv"
    fi
done

# 查找所有 CNF
find "$SAT_ROOT" -type f -name '*.cnf' > "$ALL_TASKS_FILE"
> "$TO_DO_FILE"

count=0
while read -r cnf_file; do
    base_name=$(basename "$cnf_file")
    # 检查绝对路径和文件名
    if [[ -z "${PROCESSED["$cnf_file"]+x}" && -z "${PROCESSED["$base_name"]+x}" ]]; then
        echo "$cnf_file" >> "$TO_DO_FILE"
        ((count++))
    fi
done < "$ALL_TASKS_FILE"

echo "待处理任务数: $count"
if [[ $count -eq 0 ]]; then echo "全部完成，退出。"; exit 0; fi

# ---------------------------------------------------------
# 第二步：切分任务
# ---------------------------------------------------------
# 按行数平均切分
split -n l/"$NUM_WORKERS" -d "$TO_DO_FILE" "$TMP_DIR/task_part_"

# ---------------------------------------------------------
# 第三步：定义 Worker 函数 (只用 kissat)
# ---------------------------------------------------------
run_worker() {
    local worker_id=$1
    local task_file=$2
    
    # 每个 Worker 独享的日志文件 (避免多进程写同一个文件冲突)
    local worker_error="$TMP_DIR/error_${worker_id}.csv"
    local worker_result="$TMP_DIR/result_${worker_id}.csv"
    
    echo ">>> Worker $worker_id 启动，处理: $task_file"
    
    while read -r cnf_file; do
        # 1. 运行 Kissat (带 timeout 保护)
        timeout -k "${KILL_GRACE}s" "${TIME_LIMIT}s" \
            "$KISSAT_BIN" "$cnf_file" > /dev/null
        local status=$?
        
        # 2. 分类处理退出码 
        
        # A. 超时 (124)
        if (( status == 124 )); then
            echo "[W$worker_id] 超时: $(basename "$cnf_file")"
            echo "$cnf_file,TIMEOUT" >> "$worker_error"
            continue
        fi
        
        # B. 崩溃信号 (>= 128)
        if (( status >= 128 )); then
            local signal=$((status - 128))
            echo "[W$worker_id] 崩溃(Sig $signal): $(basename "$cnf_file")"
            echo "$cnf_file,CRASH(signal=$signal)" >> "$worker_error"
            continue
        fi
        
        # C. 异常退出 (非 0, 10, 20)
        if (( status != 0 && status != 10 && status != 20 )); then
            echo "[W$worker_id] 异常(Code $status): $(basename "$cnf_file")"
            echo "$cnf_file,ERROR(exit=$status)" >> "$worker_error"
            continue
        fi
        
        # D. 成功 (10=SAT, 20=UNSAT)
        echo "[W$worker_id] 完成: $(basename "$cnf_file") ($status)"
        
        # 在这里记录成功结果
        echo "$cnf_file,SOLVED,$status" >> "$worker_result"
        
    done < "$task_file"
    
    echo ">>> Worker $worker_id 任务结束。"
}

# ---------------------------------------------------------
# 第四步：启动并行 Worker
# ---------------------------------------------------------
for (( i=0; i<NUM_WORKERS; i++ )); do
    part_file="$TMP_DIR/task_part_$(printf "%02d" $i)"
    
    if [[ -f "$part_file" ]]; then
        run_worker "$i" "$part_file" &
        pids+=($!)
    fi
done

# ---------------------------------------------------------
# 第五步：等待完成并合并结果
# ---------------------------------------------------------
echo "正在运行... (按 Ctrl+C 可中断，但请等待清理)"

# 等待所有子进程
for pid in "${pids[@]}"; do
    wait "$pid"
done

echo "所有 Worker 已结束，正在合并日志..."

# 合并错误日志
if ls "$TMP_DIR"/error_*.csv 1> /dev/null 2>&1; then
    cat "$TMP_DIR"/error_*.csv >> "$MAIN_ERROR_CSV"
fi

# 合并结果
echo "合并结果到主 CSV..."
if ls "$TMP_DIR"/result_*.csv 1> /dev/null 2>&1; then
    cat "$TMP_DIR"/result_*.csv >> "$MAIN_RESULTS_CSV"
fi

# 清理临时目录
rm -rf "$TMP_DIR"

echo "并行处理全部完成！"