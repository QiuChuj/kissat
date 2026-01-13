#!/bin/bash

# 定义输入和输出文件路径
KISSAT_CSV="/home/richard/project/kissat/results/kissat_results.csv"
NEUROBRANCH_CSV="/home/richard/project/kissat/results/neurobranch_simp_results.csv"
MERGED_CSV="/home/richard/project/kissat/results/merge_results.csv"

# 检查输入文件是否存在
if [ ! -f "$KISSAT_CSV" ]; then
    echo "错误: Kissat结果文件不存在: $KISSAT_CSV" >&2
    exit 1
fi

if [ ! -f "$NEUROBRANCH_CSV" ]; then
    echo "错误: Neurobranch结果文件不存在: $NEUROBRANCH_CSV" >&2
    exit 1
fi

echo "开始合并CSV文件..."
echo "Kissat结果文件: $KISSAT_CSV"
echo "Neurobranch结果文件: $NEUROBRANCH_CSV"
echo "合并输出文件: $MERGED_CSV"

# 创建临时文件
TEMP_DIR=$(mktemp -d)
KISSAT_CLEANED="$TEMP_DIR/kissat_cleaned.csv"
NEUROBRANCH_CLEANED="$TEMP_DIR/neurobranch_cleaned.csv"
COMMON_PATHS="$TEMP_DIR/common_paths.txt"

echo "创建临时目录: $TEMP_DIR"

# 清理CSV文件（去除可能的空格和引号）
echo "清理CSV文件..."
awk -F',' '{
    # 清理每列的空格和引号
    for(i=1; i<=NF; i++) {
        gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", $i)
    }
    print $1 "," $2 "," $3 "," $4 "," $5 "," $6 "," $7
}' "$KISSAT_CSV" > "$KISSAT_CLEANED"

awk -F',' '{
    # 清理每列的空格和引号
    for(i=1; i<=NF; i++) {
        gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", $i)
    }
    print $1 "," $2 "," $3 "," $4 "," $5 "," $6 "," $7
}' "$NEUROBRANCH_CSV" > "$NEUROBRANCH_CLEANED"

# 提取两个文件的文件路径（第一列），并找出交集
echo "查找共同的文件路径..."
awk -F',' 'NR>1 {print $1}' "$KISSAT_CLEANED" | sort > "$TEMP_DIR/kissat_paths.txt"
awk -F',' 'NR>1 {print $1}' "$NEUROBRANCH_CLEANED" | sort > "$TEMP_DIR/neurobranch_paths.txt"

comm -12 "$TEMP_DIR/kissat_paths.txt" "$TEMP_DIR/neurobranch_paths.txt" > "$COMMON_PATHS"

COMMON_COUNT=$(wc -l < "$COMMON_PATHS")
echo "找到 $COMMON_COUNT 个共同的文件路径"

if [ "$COMMON_COUNT" -eq 0 ]; then
    echo "警告: 没有找到共同的文件路径" >&2
    # 清理临时文件
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 创建合并后的CSV文件
echo "创建合并后的CSV文件..."

# 写入标题行
echo "文件绝对路径,求解结果(kissat),求解结果(neurobranch),求解总时间(kissat),求解总时间(neurobranch),decision时间(kissat),decision时间(neurobranch),剩余时间(kissat),剩余时间(neurobranch),decision次数(kissat),decision次数(neurobranch),conflict次数(kissat),conflict次数(neurobranch)" > "$MERGED_CSV"

# 处理每个共同的文件路径
while IFS= read -r file_path; do
    # 从kissat文件中提取数据
    kissat_line=$(grep -F "$file_path" "$KISSAT_CLEANED")
    # 从neurobranch文件中提取数据
    neurobranch_line=$(grep -F "$file_path" "$NEUROBRANCH_CLEANED")
    
    if [ -n "$kissat_line" ] && [ -n "$neurobranch_line" ]; then
        # 解析kissat行的各列
        IFS=',' read -r -a kissat_cols <<< "$kissat_line"
        # 解析neurobranch行的各列
        IFS=',' read -r -a neurobranch_cols <<< "$neurobranch_line"
        
        # 构建合并后的行
        merged_line="$file_path"
        
        # 添加各列数据（除了第一列文件路径外）
        for ((i=1; i<7; i++)); do
            kissat_value="${kissat_cols[$i]}"
            neurobranch_value="${neurobranch_cols[$i]}"
            merged_line="$merged_line,$kissat_value,$neurobranch_value"
        done
        
        # 写入合并后的CSV文件
        echo "$merged_line" >> "$MERGED_CSV"
    fi
done < "$COMMON_PATHS"

# 验证合并结果
MERGED_COUNT=$(awk 'NR>1' "$MERGED_CSV" | wc -l)
echo "成功合并 $MERGED_COUNT 条记录"

# 显示合并文件的前几行作为示例
echo ""
echo "合并文件的前5行示例:"
echo "===================="
head -n 6 "$MERGED_CSV" | column -t -s ','

# 清理临时文件
echo "清理临时文件..."
rm -rf "$TEMP_DIR"

echo ""
echo "合并完成! 结果已保存到: $MERGED_CSV"
echo "总记录数: $MERGED_COUNT"