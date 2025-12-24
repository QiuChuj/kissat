#!/bin/bash
# 遍历 SATLIB 下所有 .cnf 文件
# 对未在 kissat_results.csv 第一列中出现过的文件运行 kissat
# 若 kissat 崩溃或超时，则强制终止并继续下一个实例

KISSAT_BIN="/home/richard/project/kissat/build/kissat"
BENCH_ROOT="/home/richard/project/SAT_benchmark/SATLIB"
RESULTS_CSV="/home/richard/project/kissat/kissat_results.csv"
ERROR_CSV="/home/richard/project/kissat/error.csv"

# 每个实例的最大运行时间（秒），可根据需要调整
TIME_LIMIT=60    # 比如 60 秒 = 1 分钟
KILL_GRACE=5      # timeout 先发 SIGTERM，KILL_GRACE 秒后再 SIGKILL

# 禁止生成 core 文件，避免 abort 写 core 时卡住
ulimit -c 0

# 使用 bash 关联数组记录已求解的实例
declare -A SOLVED

# 1. 读取已有的结果 CSV，把第一列加载到 SOLVED 中
if [[ -f "$RESULTS_CSV" ]]; then
    echo "从 $RESULTS_CSV 读取已求解问题列表..."

    while IFS=, read -r fname _; do
        [[ -z "$fname" ]] && continue
        if [[ "$fname" == "filename" || "$fname" == "cnf" ]]; then
            continue
        fi
        SOLVED["$fname"]=1
    done < "$RESULTS_CSV"
else
    echo "结果文件 $RESULTS_CSV 不存在，视为当前没有已求解实例。"
fi

echo "已记录的已求解实例数量: ${#SOLVED[@]}"

# 2. 递归遍历 SATLIB 目录下所有 .cnf 文件
find "$BENCH_ROOT" -type f -name "*.cnf" | while IFS= read -r cnf_path; do
    abs_path="$cnf_path"
    base_name="$(basename "$cnf_path")"

    # 3. 检查是否已经在 CSV 中出现过
    if [[ -n "${SOLVED["$abs_path"]+x}" || -n "${SOLVED["$base_name"]+x}" ]]; then
        echo "跳过已求解: $cnf_path"
        continue
    fi

    echo "=============================================="
    echo "求解: $cnf_path"

    # 4. 用 timeout 限制单个实例运行时间
    #    timeout 返回码语义：
    #      - 命令正常退出：返回命令退出码
    #      - 超时：          124
    #      - 若被 timeout 自己 SIGKILL 等杀掉，可能返回 137(128+9) 等
    timeout -k "${KILL_GRACE}s" "${TIME_LIMIT}s" \
        "$KISSAT_BIN" "$cnf_path"
    kissat_status=$?

    # 5. 分类处理退出码

    # 5.1 超时
    if (( kissat_status == 124 )); then
        echo "警告: $cnf_path 求解超时 (> ${TIME_LIMIT}s)，已被 timeout 终止，跳过该实例。"
        # 如需记录到 CSV，在此处追加一行：
        echo "$abs_path,TIMEOUT" >> "$ERROR_CSV"
        continue
    fi

    # 5.2 被信号终止（包括 SIGABRT=6, SIGSEGV=11 等）
    if (( kissat_status >= 128 )); then
        signal=$((kissat_status - 128))
        echo "警告: kissat 在 $cnf_path 上被信号 $signal 终止 (exit=$kissat_status)，跳过该实例。"
        # 例如：stack smashing -> glibc 打印后 abort -> SIGABRT(6) -> exit=134
        # 可按需记录：
        echo "$abs_path,CRASH(signal=$signal)" >> "$ERROR_CSV"
        continue
    fi

    # 5.3 其他非 0 退出码（既不是 SAT=10, 也不是 UNSAT=20）
    if (( kissat_status != 0 && kissat_status != 10 && kissat_status != 20 )); then
        echo "警告: kissat 在 $cnf_path 上异常退出 (exit=$kissat_status)，跳过该实例。"
        echo "$abs_path,ERROR(exit=$kissat_status)" >> "$ERROR_CSV"
        continue
    fi

    echo "kissat 正常结束，退出码: $kissat_status"

    echo "当前 CNF 处理完成: $cnf_path"
    echo
done

echo "所有 CNF 文件处理完毕。"