#!/bin/bash

# 脚本：filter_sat_data.sh
# 功能：筛选CSV中decision次数或conflict次数不同的记录
# 用法：./filter_sat_data.sh <输入csv文件> [输出csv文件]

# 检查参数
if [ $# -lt 1 ]; then
    echo "错误: 请提供输入CSV文件路径"
    echo "用法: $0 <输入csv文件> [输出csv文件]"
    echo "示例: $0 sat_results.csv filtered_results.csv"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="${2:-filtered_sat_results.csv}"  # 默认输出文件名

# 检查输入文件是否存在
if [ ! -f "$INPUT_FILE" ]; then
    echo "错误: 输入文件不存在: $INPUT_FILE" >&2
    exit 1
fi

# 清空输出文件
> "$OUTPUT_FILE"

echo "开始处理CSV文件: $INPUT_FILE"
echo "输出文件: $OUTPUT_FILE"

# 使用awk处理CSV文件
awk -F, -v out_file="$OUTPUT_FILE" '
# 列索引说明（根据您的CSV格式调整）:
# 1:文件绝对路径
# 2:求解结果(kissat)
# 3:求解结果(neurobranch)
# 4:求解总时间(kissat)
# 5:求解总时间(neurobranch)
# 6:decision时间(kissat)
# 7:decision时间(neurobranch)
# 8:剩余时间(kissat)
# 9:剩余时间(neurobranch)
# 10:decision次数(kissat)
# 11:decision次数(neurobranch)
# 12:conflict次数(kissat)
# 13:conflict次数(neurobranch)

# 处理第一行（表头）
NR == 1 {
    # 检查列数是否足够
    if (NF < 13) {
        print "警告: 表头只有 " NF " 列，但需要至少13列" > "/dev/stderr"
        exit 1
    }
    print > out_file
    next
}

# 处理数据行
{
    # 检查当前行是否有足够列
    if (NF < 13) {
        print "警告: 第 " NR " 行只有 " NF " 列，跳过" > "/dev/stderr"
        next
    }
    
    # 提取decision次数和conflict次数
    dec_kissat = $10
    dec_neuro = $11
    conf_kissat = $12
    conf_neuro = $13
    
    # 检查是否不同
    if (dec_kissat != dec_neuro || conf_kissat != conf_neuro) {
        print > out_file
    }
}
' "$INPUT_FILE"

# 统计处理结果
TOTAL_LINES=$(wc -l < "$INPUT_FILE")
FILTERED_LINES=$(wc -l < "$OUTPUT_FILE" | awk '{print $1}')

# 减去表头行
if [ "$TOTAL_LINES" -gt 0 ]; then
    DATA_LINES=$((TOTAL_LINES - 1))
else
    DATA_LINES=0
fi

if [ "$FILTERED_LINES" -gt 0 ]; then
    FILTERED_DATA=$((FILTERED_LINES - 1))
else
    FILTERED_DATA=0
fi

echo "处理完成!"
echo "统计信息:"
echo "  输入文件总行数: $TOTAL_LINES (其中数据行: $DATA_LINES)"
echo "  输出文件总行数: $FILTERED_LINES (其中差异记录: $FILTERED_DATA)"