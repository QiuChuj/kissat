#!/bin/bash
set -u

# =============== kissat 配置文件 ===============
CONFIG_JSON="/home/richard/project/kissat/config/config.json"

update_kissat_config() {
    local use_neurobranch="$1"
    local train_mode="$2"
    local simple_mode="$3"
    local reinforce_mode="$4"

    "$PYTHON_BIN" - "$CONFIG_JSON" <<EOF
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
APPLY_SCRIPT="/home/richard/project/neurobranch_simp/python/apply.py"
SAT_ROOT="/home/richard/project/SAT_benchmark/SATLIB"
PYTHON_BIN="python3"

# 4. 主结果文件
MAIN_RESULTS_CSV="/home/richard/project/kissat/results/neurobranch_simp_results.csv"
MAIN_ERROR_CSV="/home/richard/project/kissat/results/neurobranch_simp_error.csv"

# 5. 临时目录
TMP_DIR="/tmp/kissat_parallel_jobs"
mkdir -p "$TMP_DIR"

# 禁止生成 core 文件
ulimit -c 0

# ========= 新增：Ctrl+C 清理函数和 trap =========
cleanup() {
    echo
    echo "捕获到中断信号，正在清理所有 worker 进程和临时文件..."
    echo "合并错误日志..."

    # 合并错误日志
    if ls "$TMP_DIR"/error_*.csv 1> /dev/null 2>&1; then
        cat "$TMP_DIR"/error_*.csv >> "$MAIN_ERROR_CSV"
    fi

    echo "合并结果到主 CSV..."

    RESULTS_DIR="/home/richard/project/kissat/results"
    # 将所有带 worker 后缀的文件合并到主文件（如果有的话）
    cat "$RESULTS_DIR"/neurobranch_simp_results_*.csv >> "$MAIN_RESULTS_CSV" 2>/dev/null

    # 合并完后删除这些分片文件
    rm -f "$RESULTS_DIR"/neurobranch_simp_results_*.csv

    # 杀掉所有 worker 子进程（如果已经启动的话）
    # 注意使用 ${pids[@]:-} 防止 set -u 下 pids 未定义时报错
    for pid in "${pids[@]:-}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done

    # 保险起见，再杀一次所有 apply.py 和 kissat 进程
    pkill -f "$APPLY_SCRIPT" 2>/dev/null || true
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
if [[ ! -x "$KISSAT_BIN" || ! -f "$APPLY_SCRIPT" ]]; then
    echo "错误：找不到 kissat 或 apply.py"
    exit 1
fi

echo "=== 开始并行求解 (Workers: $NUM_WORKERS) ==="

# ---------------------------------------------------------
# 第一步：任务扫描与去重 (加载主 CSV 到内存)
# ---------------------------------------------------------
update_kissat_config 1 0 1 0
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
# 第三步：定义 Worker 函数 (包含完整的异常处理)
# ---------------------------------------------------------
run_worker() {
    local worker_id=$1
    local task_file=$2
    
    # 每个 Worker 独享的日志文件 (避免多进程写同一个文件冲突)
    local worker_error="$TMP_DIR/error_${worker_id}.csv"
    # 如果 C 代码没有写结果到文件，我们可以利用这个文件记录成功的
    local worker_result="$TMP_DIR/result_${worker_id}.csv"
    
    echo ">>> Worker $worker_id 启动，处理: $task_file"
    
    # 以前通过环境变量传 worker_id 给 C，现在不再需要：
    # export NEUROBRANCH_WORKER_ID="$worker_id"
    
    while read -r cnf_file; do
        # 1. 后台启动 Python (传入 --worker-id)
        # 将输出重定向到 /dev/null 防止刷屏
        "$PYTHON_BIN" "$APPLY_SCRIPT" --worker-id "$worker_id" > /dev/null 2>&1 &
        local py_pid=$!
        
        # 等待初始化
        sleep 2
        
        # 2. 运行 Kissat (带 timeout 保护)
        # 现在 worker_id 作为命令行第二个参数传给 kissat
        timeout -k "${KILL_GRACE}s" "${TIME_LIMIT}s" \
            "$KISSAT_BIN" "$cnf_file" "$worker_id" > /dev/null
        local status=$?
        
        # 3. 立即清理 Python 进程 (无论 kissat 成功失败)
        if kill -0 "$py_pid" 2>/dev/null; then
            kill "$py_pid" 2>/dev/null || true
            # 极短等待，防止僵尸进程
            sleep 0.2
            if kill -0 "$py_pid" 2>/dev/null; then
                kill -9 "$py_pid" 2>/dev/null || true
            fi
        fi
        
        # 4. 分类处理退出码 
        
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
        
        # 如果 C 端没有写入主 CSV，可以在这里加一行
        # echo "$cnf_file,SOLVED,$status" >> "$worker_result"
        
    done < "$task_file"
    
    echo ">>> Worker $worker_id 任务结束。"
}

# ---------------------------------------------------------
# 第四步：启动并行 Worker
# ---------------------------------------------------------
pids=()
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

echo "合并结果到主 CSV..."

RESULTS_DIR="/home/richard/project/kissat/results"
# 将所有带 worker 后缀的文件合并到主文件（如果有的话）
cat "$RESULTS_DIR"/neurobranch_simp_results_*.csv >> "$MAIN_RESULTS_CSV" 2>/dev/null

# 合并完后删除这些分片文件
rm -f "$RESULTS_DIR"/neurobranch_simp_results_*.csv

# 清理临时目录
rm -rf "$TMP_DIR"

echo "并行处理全部完成！"