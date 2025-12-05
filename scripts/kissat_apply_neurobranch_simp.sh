#!/bin/bash

# 定义文件路径
PYTHON_SCRIPT="/home/richard/project/neurobranch_simp/python/apply.py"
KISSAT_EXECUTABLE="/home/richard/project/kissat/build/kissat"

# 检查参数
if [ $# -ne 1 ]; then
    echo "错误: 请提供CNF文件路径作为参数"
    echo "用法: $0 <cnf文件路径>"
    exit 1
fi

CNF_FILE="$1"

# 检查文件是否存在
if [ ! -f "$PYTHON_SCRIPT" ]; then
    echo "错误: Python脚本不存在: $PYTHON_SCRIPT" >&2
    exit 1
fi

if [ ! -f "$KISSAT_EXECUTABLE" ]; then
    echo "错误: Kissat可执行文件不存在: $KISSAT_EXECUTABLE" >&2
    exit 1
fi

if [ ! -f "$CNF_FILE" ]; then
    echo "错误: CNF文件不存在: $CNF_FILE" >&2
    exit 1
fi

# 创建日志目录
LOG_DIR="/home/richard/project/kissat/logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
PYTHON_LOG="$LOG_DIR/python.log"
KISSAT_LOG="$LOG_DIR/kissat.log"

echo "=== 启动神经网络监测和SAT求解 ==="
echo "Python脚本: $PYTHON_SCRIPT"
echo "Kissat求解器: $KISSAT_EXECUTABLE"
echo "CNF文件: $CNF_FILE"
echo "日志目录: $LOG_DIR"
echo "======================================"

# 进程ID变量
PYTHON_PID=""
KISSAT_PID=""

# 改进的清理函数
cleanup() {
    local exit_code=${1:-0}
    echo "正在清理进程..." | tee -a "$KISSAT_LOG"
    
    # 终止Kissat进程
    if [ ! -z "$KISSAT_PID" ] && kill -0 "$KISSAT_PID" 2>/dev/null; then
        echo "终止Kissat进程: $KISSAT_PID" | tee -a "$KISSAT_LOG"
        kill "$KISSAT_PID" 2>/dev/null
        sleep 2
        # 如果进程仍然存在，强制终止
        if kill -0 "$KISSAT_PID" 2>/dev/null; then
            kill -9 "$KISSAT_PID" 2>/dev/null
            echo "强制终止Kissat进程" | tee -a "$KISSAT_LOG"
        fi
    fi
    
    # 终止Python进程
    if [ ! -z "$PYTHON_PID" ] && kill -0 "$PYTHON_PID" 2>/dev/null; then
        echo "终止Python进程: $PYTHON_PID" | tee -a "$KISSAT_LOG"
        kill "$PYTHON_PID" 2>/dev/null
        sleep 1
        # 如果进程仍然存在，强制终止
        if kill -0 "$PYTHON_PID" 2>/dev/null; then
            kill -9 "$PYTHON_PID" 2>/dev/null
            echo "强制终止Python进程" | tee -a "$KISSAT_LOG"
        fi
    fi
    
    exit $exit_code
}

# 信号处理函数
handle_signal() {
    local sig=$1
    echo "捕获到信号 $sig，开始清理..." | tee -a "$KISSAT_LOG"
    cleanup 134  # 返回134表示SIGABRT
}

# 设置信号捕获
trap 'handle_signal SIGABRT' SIGABRT
trap 'handle_signal SIGINT' SIGINT
trap 'handle_signal SIGTERM' SIGTERM

# 启动Python神经网络监测服务（后台运行）
echo "启动Python神经网络监测服务..."
python3 "$PYTHON_SCRIPT" >> "$PYTHON_LOG" 2>&1 &
PYTHON_PID=$!
echo "Python进程PID: $PYTHON_PID"

# 等待Python服务启动
echo "等待Python服务初始化..."
sleep 5

# 检查Python进程是否仍在运行
if ! kill -0 "$PYTHON_PID" 2>/dev/null; then
    echo "错误: Python进程启动失败，请检查日志: $PYTHON_LOG" >&2
    exit 1
fi

echo "Python神经网络监测服务已启动"

# 运行Kissat SAT求解器
echo "启动Kissat SAT求解器..."
echo "开始求解: $(date)" | tee -a "$KISSAT_LOG"
echo "CNF文件: $CNF_FILE" | tee -a "$KISSAT_LOG"
echo "--------------------------------------" | tee -a "$KISSAT_LOG"

# 运行求解器并记录输出（在子shell中运行以便获取PID）
(
    "$KISSAT_EXECUTABLE" "$CNF_FILE" 2>&1 | tee -a "$KISSAT_LOG"
) &
KISSAT_PID=$!

# 等待Kissat进程完成
wait $KISSAT_PID
KISSAT_EXIT_CODE=$?

echo "--------------------------------------" | tee -a "$KISSAT_LOG"
echo "求解完成: $(date)" | tee -a "$KISSAT_LOG"
echo "退出代码: $KISSAT_EXIT_CODE" | tee -a "$KISSAT_LOG"

# 清理Python进程
cleanup $KISSAT_EXIT_CODE