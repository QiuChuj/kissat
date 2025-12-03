#!/bin/bash

# 定义Kissat求解器路径和目标目录
KISSAT_PATH="/home/richard/project/kissat/build/kissat"
TARGET_DIR=$1
RECORD_FILE="/home/richard/project/kissat/neurobranch_simp_results.csv"

# 检查Kissat求解器是否存在
if [ ! -f "$KISSAT_PATH" ]; then
    echo "错误: Kissat可执行文件不存在: $KISSAT_PATH" >&2
    exit 1
fi

# 检查目标目录是否存在
if [ ! -d "$TARGET_DIR" ]; then
    echo "错误: 目标目录不存在: $TARGET_DIR" >&2
    exit 1
fi

# 检查记录文件是否存在，如果不存在则创建
if [ ! -f "$RECORD_FILE" ]; then
    echo "记录文件不存在，将创建新文件: $RECORD_FILE"
    touch "$RECORD_FILE"
fi

# 创建日志目录
LOG_DIR="/home/richard/project/kissat/logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
BATCH_LOG="$LOG_DIR/batch_solve.log"

echo "=== 开始批量求解CNF文件 ===" | tee -a "$BATCH_LOG"
echo "开始时间: $(date)" | tee -a "$BATCH_LOG"
echo "Kissat求解器: $KISSAT_PATH" | tee -a "$BATCH_LOG"
echo "目标目录: $TARGET_DIR" | tee -a "$BATCH_LOG"
echo "日志目录: $LOG_DIR" | tee -a "$BATCH_LOG"
echo "记录文件: $RECORD_FILE" | tee -a "$BATCH_LOG"
echo "======================================" | tee -a "$BATCH_LOG"

# 计数器
TOTAL_FILES=0
SOLVED_FILES=0
FAILED_FILES=0
SKIPPED_FILES=0

# 函数：检查文件是否已在记录中
check_file_in_record() {
    local file_path="$1"
    # 使用绝对路径进行精确匹配
    local abs_path=$(readlink -f "$file_path")
    # 检查记录文件中是否存在该路径（第一列）
    if grep -q "^\"$abs_path\"," "$RECORD_FILE"; then
        return 0  # 找到，已存在
    else
        return 1  # 未找到，不存在
    fi
}

# 使用find命令递归查找所有.cnf文件
# 使用-print0和while循环安全处理文件名（包括空格和特殊字符）
find "$TARGET_DIR" -type f -name "*.cnf" -print0 | while IFS= read -r -d '' cnf_file; do
    ((TOTAL_FILES++))
    
    # 获取相对路径用于显示
    relative_path="${cnf_file#$TARGET_DIR/}"
    
    # 检查文件是否已在记录中
    if check_file_in_record "$cnf_file"; then
        echo "[$TOTAL_FILES] 跳过: $relative_path (已在记录中)" | tee -a "$BATCH_LOG"
        ((SKIPPED_FILES++))
        continue
    fi
    
    echo "[$TOTAL_FILES] 求解: $relative_path" | tee -a "$BATCH_LOG"
    
    # 为每个CNF文件创建单独的日志
    cnf_basename=$(basename "$cnf_file" .cnf)
    cnf_log="$LOG_DIR/${cnf_basename}_kissat.log"
    
    # 记录开始时间
    start_time=$(date +%s)
    
    # 运行Kissat求解器并记录输出
    echo "开始求解: $(date)" > "$cnf_log"
    echo "CNF文件: $cnf_file" >> "$cnf_log"
    echo "--------------------------------------" >> "$cnf_log"
    
    # 运行求解器并捕获退出状态
    if "$KISSAT_PATH" "$cnf_file" >> "$cnf_log" 2>&1; then
        exit_code=0
        status="SAT"
        ((SOLVED_FILES++))
    else
        exit_code=$?
        status="UNSAT"
        ((FAILED_FILES++))
    fi
    
    # 记录结束时间和状态
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    echo "--------------------------------------" >> "$cnf_log"
    echo "求解完成: $(date)" >> "$cnf_log"
    echo "退出代码: $exit_code" >> "$cnf_log"
    echo "求解时间: ${duration}秒" >> "$cnf_log"
    
    # 输出当前结果
    echo "  状态: $status, 时间: ${duration}秒, 日志: $cnf_log" | tee -a "$BATCH_LOG"
    
done

# 由于管道创建子shell，计数器需要特殊处理
# 重新计算文件总数
TOTAL_FILES=$(find "$TARGET_DIR" -type f -name "*.cnf" | wc -l)

# 输出汇总信息
echo "======================================" | tee -a "$BATCH_LOG"
echo "批量求解完成: $(date)" | tee -a "$BATCH_LOG"
echo "汇总统计:" | tee -a "$BATCH_LOG"
echo "  总文件数: $TOTAL_FILES" | tee -a "$BATCH_LOG"
echo "  跳过文件数: $SKIPPED_FILES" | tee -a "$BATCH_LOG"
echo "  实际求解数: $((TOTAL_FILES - SKIPPED_FILES))" | tee -a "$BATCH_LOG"
echo "  成功数: $SOLVED_FILES" | tee -a "$BATCH_LOG"
echo "  失败数: $FAILED_FILES" | tee -a "$BATCH_LOG"
if [ $((TOTAL_FILES - SKIPPED_FILES)) -gt 0 ]; then
    success_rate=$((SOLVED_FILES * 100 / (TOTAL_FILES - SKIPPED_FILES)))
    echo "  成功率: ${success_rate}%" | tee -a "$BATCH_LOG"
else
    echo "  成功率: 0%" | tee -a "$BATCH_LOG"
fi
echo "详细日志目录: $LOG_DIR" | tee -a "$BATCH_LOG"
echo "批量处理日志: $BATCH_LOG" | tee -a "$BATCH_LOG"