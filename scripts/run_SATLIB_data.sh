#!/bin/bash

# =================配置区域=================
# 原始求解脚本的绝对路径
RUNNER_SCRIPT="/home/richard/project/kissat/scripts/run_by_filenames.sh"

# SATLIB Benchmark 的根目录
BENCHMARK_ROOT="/home/richard/project/SAT_benchmark/SATLIB"
# =========================================

# 1. 检查原始脚本是否存在
if [ ! -f "$RUNNER_SCRIPT" ]; then
    echo "错误: 找不到求解脚本: $RUNNER_SCRIPT"
    exit 1
fi

# 确保原始脚本有执行权限
chmod +x "$RUNNER_SCRIPT"

# 2. 检查Benchmark目录是否存在
if [ ! -d "$BENCHMARK_ROOT" ]; then
    echo "错误: 找不到Benchmark目录: $BENCHMARK_ROOT"
    exit 1
fi

echo "=========================================="
echo "      开始全量 Benchmark 测试"
echo "=========================================="
echo "求解脚本: $RUNNER_SCRIPT"
echo "数据根目录: $BENCHMARK_ROOT"
echo "开始时间: $(date)"
echo "=========================================="
echo ""

# 统计总耗时
start_total_time=$(date +%s)

# 3. 遍历 SATLIB 下的一级子目录
# 使用 find maxdepth 1 确保只列出第一层子文件夹（例如 uf20-91, uf50-218）
# sort 确保按字母顺序执行
find "$BENCHMARK_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | while read -r benchmark_dir; do
    
    dir_name=$(basename "$benchmark_dir")
    
    echo ">>>>>>>>> 正在处理 Benchmark 集: $dir_name <<<<<<<<<"
    echo "路径: $benchmark_dir"
    
    # 4. 调用原始脚本
    # 将当前的子目录作为参数传递给 run_by_filenames.sh
    bash "$RUNNER_SCRIPT" "$benchmark_dir"
    
    # 捕获原始脚本的退出状态（可选）
    exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo "警告: Benchmark 集 $dir_name 处理过程中出现非零退出代码。"
    fi
    
    echo ""
    echo ">>>>>>>>> 完成 Benchmark 集: $dir_name <<<<<<<<<"
    echo "--------------------------------------------------"
    echo ""
    
    # 可选：这里可以加一个 sleep 1 让系统稍微缓冲一下，防止日志写入冲突
    sleep 1

done

end_total_time=$(date +%s)
total_duration=$((end_total_time - start_total_time))

echo "=========================================="
echo "所有 Benchmark 处理完毕！"
echo "总耗时: ${total_duration} 秒"
echo "日志文件已保存在 /home/richard/project/kissat/logs/ 下各自的时间戳文件夹中"
echo "=========================================="