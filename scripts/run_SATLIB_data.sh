#!/bin/bash
# 遍历 /home/richard/project/SAT_benchmark/SATLIB 下所有 .cnf 文件
# 对未在 kissat_results.csv 第一列中出现过的文件运行 kissat

KISSAT_BIN="/home/richard/project/kissat/build/kissat"
BENCH_ROOT="/home/richard/project/SAT_benchmark/SATLIB"
RESULTS_CSV="/home/richard/project/kissat/kissat_results.csv"

# 使用 bash 关联数组记录已求解的实例
declare -A SOLVED

# 1. 读取已有的结果 CSV，把第一列加载到 SOLVED 中
if [[ -f "$RESULTS_CSV" ]]; then
    echo "从 $RESULTS_CSV 读取已求解问题列表..."

    # 逐行读取 CSV
    # IFS=, 以逗号为分隔符，只取第一列 fname
    while IFS=, read -r fname _; do
        # 跳过空行
        [[ -z "$fname" ]] && continue
        # 如果有表头，按需跳过（可根据你自己的表头名称调整）
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
    # 绝对路径
    abs_path="$cnf_path"
    # 仅文件名（不含路径）
    base_name="$(basename "$cnf_path")"

    # 3. 检查是否已经在 CSV 中出现过
    #    既支持 CSV 里存的是绝对路径，也支持只存文件名
    if [[ -n "${SOLVED["$abs_path"]+x}" || -n "${SOLVED["$base_name"]+x}" ]]; then
        echo "跳过已求解: $cnf_path"
        continue
    fi

    echo "求解: $cnf_path"
    # 4. 调用 kissat 进行求解
    "$KISSAT_BIN" "$cnf_path"

    # 如果你希望在每次求解后立即往 CSV 里追加一行，
    # 可以在这里解析 kissat 输出追加相应信息。
    # 比如至少把文件名记下来（其他列请根据你自己的格式调整）：
    #
    # echo "$base_name" >> "$RESULTS_CSV"
    #
    # 或者：
    # echo "$abs_path" >> "$RESULTS_CSV"
    #
    # 如果 CSV 有更多列（时间、解的状态等），需要在这里自己解析 kissat 输出，拼成一行。
done