#!/bin/bash
set -u

# 单 benchmark 求解脚本
RUN_SCRIPT="/home/richard/project/kissat/scripts/kissat_neurobranch_simp_multiprocess_single_benchmark.sh"

# SATLIB 根目录
SATLIB_ROOT="/home/richard/project/SAT_benchmark/SATLIB"

# 检查必要文件
if [[ ! -x "$RUN_SCRIPT" ]]; then
    echo "错误：找不到或不可执行的子脚本: $RUN_SCRIPT" >&2
    exit 1
fi

if [[ ! -d "$SATLIB_ROOT" ]]; then
    echo "错误：SATLIB 根目录不存在: $SATLIB_ROOT" >&2
    exit 1
fi

echo "顶层脚本启动（含 uf 或 k3）。"
echo "SATLIB 根目录: $SATLIB_ROOT"
echo "子脚本:        $RUN_SCRIPT"
echo

# 收集：名字里含 'uf' 或 'k3' 的一级子目录
targets=()

for d in "$SATLIB_ROOT"/*; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    if [[ "$base" == *uf* || "$base" == *k3* ]]; then
        targets+=("$d")
    fi
done

echo "待运行的 benchmark 目录数量（含 uf 或 k3）: ${#targets[@]}"
echo

if (( ${#targets[@]} == 0 )); then
    echo "没有符合条件的 benchmark 目录，退出。"
    exit 0
fi

# 排序，保证顺序稳定
IFS=$'\n' targets=($(printf "%s\n" "${targets[@]}" | sort))
unset IFS

for bench_dir in "${targets[@]}"; do
    echo
    echo "=== 运行 benchmark 目录: $bench_dir ==="
    bash "$RUN_SCRIPT" "$bench_dir"
    # 如需在子脚本失败时中止整个流程，可以打开下面几行：
    # status=$?
    # if (( status != 0 )); then
    #     echo "子脚本在 $bench_dir 上退出码=$status，顶层脚本中止。" >&2
    #     exit $status
    # fi
done

echo
echo "所有含 uf 或 k3 的 SATLIB benchmark 已处理完成。"