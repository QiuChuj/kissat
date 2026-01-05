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
TIME_LIMIT=60    # 单个实例最大运行时间（秒）
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
monitor_pid=""

# 每个 worker 的任务总数
declare -a worker_total

# ========= Ctrl+C 清理函数和 trap =========
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
    cat "$RESULTS_DIR"/kissat_results_*.csv >> "$MAIN_RESULTS_CSV" 2>/dev/null

    # 合并完后删除这些分片文件
    rm -f "$RESULTS_DIR"/kissat_results_*.csv

    # 停掉进度监视器
    if [[ -n "${monitor_pid:-}" ]] && kill -0 "$monitor_pid" 2>/dev/null; then
        kill "$monitor_pid" 2>/dev/null || true
    fi

    # 杀掉所有 worker 子进程（如果已经启动的话）
    for pid in "${pids[@]:-}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done

    # 保险起见，再杀一次所有 kissat 进程
    pkill -f "$KISSAT_BIN" 2>/dev/null || true

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
# 进度监视器：在主进程中展示每个 worker 的进度条
# ---------------------------------------------------------
progress_monitor() {
    local bar_width=40
    while true; do
        # 清屏
        printf "\033[H\033[2J"
        echo "正在运行... (按 Ctrl+C 可中断)"
        echo "总任务数: $count"
        echo

        for (( i=0; i<NUM_WORKERS; i++ )); do
            local total=${worker_total[$i]:-0}
            local done=0

            if [[ -f "$TMP_DIR/progress_$i" ]]; then
                done=$(<"$TMP_DIR/progress_$i")
            fi

            if (( total == 0 )); then
                printf "W%d [%-${bar_width}s] %3d%% (%d/%d)\n" "$i" "" 0 0 0
                continue
            fi

            (( done > total )) && done=$total

            local percent=$(( done * 100 / total ))
            local filled=$(( percent * bar_width / 100 ))

            local bar=""
            for (( j=0; j<bar_width; j++ )); do
                if (( j < filled )); then
                    bar+="#"
                else
                    bar+="."
                fi
            done

            printf "W%d [%s] %3d%% (%d/%d)\n" "$i" "$bar" "$percent" "$done" "$total"
        done

        # 检查是否所有 worker 都结束
        local all_done=1
        for pid in "${pids[@]:-}"; do
            if kill -0 "$pid" 2>/dev/null; then
                all_done=0
                break
            fi
        done
        (( all_done )) && break

        sleep 1
    done
}

# ---------------------------------------------------------
# 第三步：定义 Worker 函数 (只用 kissat)
# ---------------------------------------------------------
run_worker() {
    local worker_id=$1
    local task_file=$2
    
    local worker_error="$TMP_DIR/error_${worker_id}.csv"
    local progress_file="$TMP_DIR/progress_${worker_id}"

    # 初始化进度为 0
    echo 0 > "$progress_file"
    local done=0
    
    # 统计该 worker 的总任务数（在主进程里也做了一次，这里再确认）
    local total=0
    if [[ -f "$task_file" ]]; then
        total=$(wc -l < "$task_file")
    fi
    worker_total[$worker_id]=$total

    echo ">>> Worker $worker_id 启动，任务数: $total"

    while read -r cnf_file; do
        # 1. 运行 Kissat (带 timeout 保护)
        timeout -k "${KILL_GRACE}s" "${TIME_LIMIT}s" \
            "$KISSAT_BIN" "$cnf_file" "$worker_id"> /dev/null
        local status=$?
        
        # 2. 分类处理退出码 
        
        # A. 超时 (124)
        if (( status == 124 )); then
            echo "$cnf_file,TIMEOUT" >> "$worker_error"
        # B. 崩溃信号 (>= 128)
        elif (( status >= 128 )); then
            local signal=$((status - 128))
            echo "$cnf_file,CRASH(signal=$signal)" >> "$worker_error"
        # C. 异常退出 (非 0, 10, 20)
        elif (( status != 0 && status != 10 && status != 20 )); then
            echo "$cnf_file,ERROR(exit=$status)" >> "$worker_error"
        # D. 成功 (10=SAT, 20=UNSAT)
        fi

        # 3. 更新本 worker 的进度
        ((done++))
        echo "$done" > "$progress_file"
        
    done < "$task_file"
    
    echo ">>> Worker $worker_id 任务结束。"
}

# ---------------------------------------------------------
# 第四步：启动并行 Worker
# ---------------------------------------------------------
for (( i=0; i<NUM_WORKERS; i++ )); do
    part_file="$TMP_DIR/task_part_$(printf "%02d" $i)"
    
    if [[ -f "$part_file" ]]; then
        # 在主进程中先记录这个 worker 的总任务数
        worker_total[$i]=$(wc -l < "$part_file")
        # 初始化 progress 文件为 0
        echo 0 > "$TMP_DIR/progress_$i"

        run_worker "$i" "$part_file" &
        pids+=($!)
    else
        worker_total[$i]=0
        echo 0 > "$TMP_DIR/progress_$i"
    fi
done

# 启动进度监视器（后台执行）
progress_monitor &
monitor_pid=$!

# ---------------------------------------------------------
# 第五步：等待完成并合并结果
# ---------------------------------------------------------
# 等待所有子进程
for pid in "${pids[@]}"; do
    wait "$pid"
done

# 等待进度监视器退出
if [[ -n "${monitor_pid:-}" ]]; then
    wait "$monitor_pid" 2>/dev/null || true
fi

echo "所有 Worker 已结束，正在合并日志..."

echo "合并错误日志..."

# 合并错误日志
if ls "$TMP_DIR"/error_*.csv 1> /dev/null 2>&1; then
    cat "$TMP_DIR"/error_*.csv >> "$MAIN_ERROR_CSV"
fi

echo "合并结果..."

RESULTS_DIR="/home/richard/project/kissat/results"
# 将所有带 worker 后缀的文件合并到主文件（如果有的话）
cat "$RESULTS_DIR"/kissat_results_*.csv >> "$MAIN_RESULTS_CSV" 2>/dev/null

# 合并完后删除这些分片文件
rm -f "$RESULTS_DIR"/kissat_results_*.csv

# 清理临时目录
rm -rf "$TMP_DIR"

echo "并行处理全部完成！"