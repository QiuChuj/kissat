#!/bin/bash

# 定义现有求解器脚本的路径
SOLVER_SCRIPT="/home/richard/project/kissat/scripts/kissat_apply_neurobranch_simp.sh"
# 定义根目录
ROOT_DIR="/home/richard/project/SAT_benchmark/SATLIB"
# 定义已处理结果记录文件
PROCESSED_CSV="/home/richard/project/kissat/neurobranch_simp_results.csv"
# 定义溢出文件夹
OVERFLOW_DIR="/home/richard/project/SAT_benchmark/overflow"
# 定义随机选择比例
SELECT_RATIO=1

# 检查求解器脚本是否存在
if [ ! -f "$SOLVER_SCRIPT" ]; then
    echo "错误: 求解器脚本不存在: $SOLVER_SCRIPT" >&2
    echo "请检查SOLVER_SCRIPT路径是否正确" >&2
    exit 1
fi

# 检查根目录是否存在
if [ ! -d "$ROOT_DIR" ]; then
    echo "错误: 根目录不存在: $ROOT_DIR" >&2
    exit 1
fi

# 创建溢出文件夹（如果不存在）
mkdir -p "$OVERFLOW_DIR"

# 创建批量处理日志
BATCH_LOG_DIR="/home/richard/project/kissat/batch_logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BATCH_LOG_DIR"
BATCH_LOG="$BATCH_LOG_DIR/batch_processing.log"

echo "=== 开始批量处理SAT问题 ===" | tee -a "$BATCH_LOG"
echo "开始时间: $(date)" | tee -a "$BATCH_LOG"
echo "求解器脚本: $SOLVER_SCRIPT" | tee -a "$BATCH_LOG"
echo "根目录: $ROOT_DIR" | tee -a "$BATCH_LOG"
echo "随机选择比例: $SELECT_RATIO (50%)" | tee -a "$BATCH_LOG"
echo "已处理记录文件: $PROCESSED_CSV" | tee -a "$BATCH_LOG"
echo "溢出文件夹: $OVERFLOW_DIR" | tee -a "$BATCH_LOG"
echo "批量处理日志: $BATCH_LOG" | tee -a "$BATCH_LOG"
echo "======================================" | tee -a "$BATCH_LOG"

# 读取已处理文件列表（从CSV第一列）
declare -A PROCESSED_FILES
if [ -f "$PROCESSED_CSV" ]; then
    echo "读取已处理文件记录..." | tee -a "$BATCH_LOG"
    while IFS=, read -r processed_file _; do
        # 清理文件名（去除空格和引号）
        cleaned_file=$(echo "$processed_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
        if [ -n "$cleaned_file" ]; then
            PROCESSED_FILES["$cleaned_file"]=1
            echo "  已记录: $cleaned_file" | tee -a "$BATCH_LOG"
        fi
    done < <(tail -n +2 "$PROCESSED_CSV" 2>/dev/null)  # 跳过标题行
    
    # 如果跳过标题行后没有数据，尝试读取整个文件
    if [ ${#PROCESSED_FILES[@]} -eq 0 ]; then
        while IFS=, read -r processed_file _; do
            cleaned_file=$(echo "$processed_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
            if [ -n "$cleaned_file" ]; then
                PROCESSED_FILES["$cleaned_file"]=1
            fi
        done < "$PROCESSED_CSV"
    fi
    echo "已加载 ${#PROCESSED_FILES[@]} 个已处理文件记录" | tee -a "$BATCH_LOG"
else
    echo "警告: 已处理记录文件不存在，将处理所有文件" | tee -a "$BATCH_LOG"
fi

# 查找所有子文件夹
echo "正在查找子文件夹..." | tee -a "$BATCH_LOG"
SUB_DIRS=()
while IFS= read -r -d '' dir; do
    SUB_DIRS+=("$dir")
done < <(find "$ROOT_DIR" -maxdepth 1 -type d ! -path "$ROOT_DIR" -print0)

TOTAL_SUB_DIRS=${#SUB_DIRS[@]}

if [ "$TOTAL_SUB_DIRS" -eq 0 ]; then
    echo "在 $ROOT_DIR 中未找到任何子文件夹" | tee -a "$BATCH_LOG"
    exit 0
fi

echo "找到 $TOTAL_SUB_DIRS 个子文件夹" | tee -a "$BATCH_LOG"

# 成功和失败计数器
TOTAL_SUCCESS_COUNT=0
TOTAL_FAILURE_COUNT=0
TOTAL_SKIPPED_COUNT=0
TOTAL_SELECTED_COUNT=0

# 全局变量存储当前处理的CNF文件
CURRENT_CNF=""

# 信号处理函数 - 处理SIGABRT
handle_sigabrt() {
    local cnf_file="$CURRENT_CNF"
    if [ -n "$cnf_file" ] && [ -f "$cnf_file" ]; then
        echo "捕获到SIGABRT信号，正在处理文件: $(basename "$cnf_file")" | tee -a "$BATCH_LOG"
        echo "将文件移动到溢出文件夹并继续处理下一个..." | tee -a "$BATCH_LOG"
        
        # 移动文件到溢出文件夹
        mv "$cnf_file" "$OVERFLOW_DIR/" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "文件已移动到溢出文件夹: $OVERFLOW_DIR/$(basename "$cnf_file")" | tee -a "$BATCH_LOG"
        else
            echo "警告: 移动文件到溢出文件夹失败" | tee -a "$BATCH_LOG"
        fi
        
        # 不退出脚本，继续处理下一个文件
        return 0
    else
        echo "捕获到SIGABRT信号，但未找到当前处理的CNF文件" | tee -a "$BATCH_LOG"
        return 1
    fi
}

# 设置信号捕获
trap 'handle_sigabrt' SIGABRT

# 处理每个子文件夹
for sub_dir in "${SUB_DIRS[@]}"; do
    dir_name=$(basename "$sub_dir")
    echo "处理子文件夹: $dir_name" | tee -a "$BATCH_LOG"
    
    # 查找当前子文件夹中的所有.cnf文件
    CNF_FILES=()
    while IFS= read -r -d '' file; do
        CNF_FILES+=("$file")
    done < <(find "$sub_dir" -type f -name "*.cnf" -print0)
    
    FILES_IN_DIR=${#CNF_FILES[@]}
    
    if [ "$FILES_IN_DIR" -eq 0 ]; then
        echo "  在 $dir_name 中未找到任何.cnf文件，跳过" | tee -a "$BATCH_LOG"
        continue
    fi
    
    echo "  找到 $FILES_IN_DIR 个CNF文件" | tee -a "$BATCH_LOG"
    
    # 过滤掉已处理的文件
    UNPROCESSED_FILES=()
    for cnf_file in "${CNF_FILES[@]}"; do
        if [ -z "${PROCESSED_FILES["$cnf_file"]}" ]; then
            UNPROCESSED_FILES+=("$cnf_file")
        fi
    done
    
    UNPROCESSED_COUNT=${#UNPROCESSED_FILES[@]}
    echo "  其中未处理文件: $UNPROCESSED_COUNT 个" | tee -a "$BATCH_LOG"
    
    if [ "$UNPROCESSED_COUNT" -eq 0 ]; then
        echo "  所有文件都已处理过，跳过此文件夹" | tee -a "$BATCH_LOG"
        continue
    fi
    
    # 随机选择50%的文件
    SELECT_COUNT=$(echo "scale=0; ($UNPROCESSED_COUNT * $SELECT_RATIO + 0.5)/1" | bc)
    if [ "$SELECT_COUNT" -eq 0 ] && [ "$UNPROCESSED_COUNT" -gt 0 ]; then
        SELECT_COUNT=1  # 至少选择1个文件
    fi
    
    echo "  随机选择 $SELECT_COUNT 个文件进行处理" | tee -a "$BATCH_LOG"
    
    # 使用shuf命令进行随机选择
    SELECTED_FILES=()
    while IFS= read -r -d '' file; do
        SELECTED_FILES+=("$file")
    done < <(printf '%s\0' "${UNPROCESSED_FILES[@]}" | shuf -z -n "$SELECT_COUNT")
    
    # 子文件夹内的计数器
    DIR_SUCCESS_COUNT=0
    DIR_FAILURE_COUNT=0
    DIR_SKIPPED_COUNT=0
    CURRENT_IN_DIR=0
    
    # 处理选中的文件
    for cnf_file in "${SELECTED_FILES[@]}"; do
        ((CURRENT_IN_DIR++))
        ((TOTAL_SELECTED_COUNT++))
        
        filename=$(basename "$cnf_file")
        echo "  [$CURRENT_IN_DIR/$SELECT_COUNT] 处理: $filename" | tee -a "$BATCH_LOG"
        
        # 记录开始时间
        start_time=$(date +%s)
        
        # 设置当前处理的文件（用于信号处理）
        CURRENT_CNF="$cnf_file"
        
        # 调用求解器脚本并捕获输出和退出状态
        # 使用超时机制防止永久卡死（例如设置5分钟超时）
        solver_output=$(timeout 300 "$SOLVER_SCRIPT" "$cnf_file" 2>&1)
        exit_status=$?
        
        # 检查退出状态
        if [ $exit_status -eq 124 ]; then
            # 超时情况
            echo "    求解器超时（5分钟），移动文件到溢出文件夹" | tee -a "$BATCH_LOG"
            mv "$cnf_file" "$OVERFLOW_DIR/" 2>/dev/null
            status="失败（超时）"
            ((DIR_FAILURE_COUNT++))
            ((TOTAL_FAILURE_COUNT++))
        elif echo "$solver_output" | grep -q "stack smashing detected"; then
            echo "    检测到stack smashing错误" | tee -a "$BATCH_LOG"
            mv "$cnf_file" "$OVERFLOW_DIR/" 2>/dev/null
            status="失败（stack smashing）"
            ((DIR_FAILURE_COUNT++))
            ((TOTAL_FAILURE_COUNT++))
        elif [ $exit_status -eq 0 ]; then
            status="成功"
            ((DIR_SUCCESS_COUNT++))
            ((TOTAL_SUCCESS_COUNT++))
        elif [ $exit_status -eq 134 ]; then  # SIGABRT的退出状态是128+6=134
            echo "    检测到SIGABRT错误（退出状态: 134）" | tee -a "$BATCH_LOG"
            # 文件已经在信号处理函数中移动，这里只更新状态
            status="失败（SIGABRT）"
            ((DIR_FAILURE_COUNT++))
            ((TOTAL_FAILURE_COUNT++))
        else
            # 其他错误情况
            echo "    求解器返回非零退出码: $exit_status" | tee -a "$BATCH_LOG"
            # 可以选择是否移动文件到溢出文件夹
            # mv "$cnf_file" "$OVERFLOW_DIR/" 2>/dev/null
            status="失败（退出码: $exit_status）"
            ((DIR_FAILURE_COUNT++))
            ((TOTAL_FAILURE_COUNT++))
        fi
        
        # 计算耗时
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        
        echo "    状态: $status, 耗时: ${duration}秒" | tee -a "$BATCH_LOG"
        echo "    --------------------------------------" | tee -a "$BATCH_LOG"
        
        # 清空当前文件变量
        CURRENT_CNF=""
    done
    
    # 输出子文件夹处理结果
    echo "子文件夹 $dir_name 处理完成:" | tee -a "$BATCH_LOG"
    echo "  总文件数: $FILES_IN_DIR" | tee -a "$BATCH_LOG"
    echo "  未处理文件数: $UNPROCESSED_COUNT" | tee -a "$BATCH_LOG"
    echo "  随机选择文件数: $SELECT_COUNT" | tee -a "$BATCH_LOG"
    echo "  成功: $DIR_SUCCESS_COUNT" | tee -a "$BATCH_LOG"
    echo "  失败: $DIR_FAILURE_COUNT" | tee -a "$BATCH_LOG"
    echo "======================================" | tee -a "$BATCH_LOG"
done

# 计算跳过的文件总数（由于已处理记录）
TOTAL_SKIPPED_COUNT=$((TOTAL_SELECTED_COUNT - TOTAL_SUCCESS_COUNT - TOTAL_FAILURE_COUNT))

# 输出汇总信息
echo "批量处理完成!" | tee -a "$BATCH_LOG"
echo "完成时间: $(date)" | tee -a "$BATCH_LOG"
echo "汇总统计:" | tee -a "$BATCH_LOG"
echo "  总子文件夹数: $TOTAL_SUB_DIRS" | tee -a "$BATCH_LOG"
echo "  随机选择文件总数: $TOTAL_SELECTED_COUNT" | tee -a "$BATCH_LOG"
echo "  成功: $TOTAL_SUCCESS_COUNT" | tee -a "$BATCH_LOG"
echo "  失败: $TOTAL_FAILURE_COUNT" | tee -a "$BATCH_LOG"
echo "  跳过: $TOTAL_SKIPPED_COUNT" | tee -a "$BATCH_LOG"
echo "======================================" | tee -a "$BATCH_LOG"