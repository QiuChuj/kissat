#!/bin/bash
set -euo pipefail

IN_CSV="/home/richard/project/kissat/results/merge_results.csv"
OUT_XLSX="/home/richard/project/kissat/results/highlighed.xlsx"

if [[ ! -f "$IN_CSV" ]]; then
    echo "错误：找不到输入文件 $IN_CSV" >&2
    exit 1
fi

python3 - <<EOF
import pandas as pd
from openpyxl import load_workbook
from openpyxl.styles import PatternFill

in_csv = r"$IN_CSV"
out_xlsx = r"$OUT_XLSX"

# 1. 读入 CSV
df = pd.read_csv(in_csv)

# 确认列名（根据你给的表头）
COL_FILE      = "文件绝对路径"
COL_RES_K     = "求解结果(kissat)"
COL_RES_N     = "求解结果(neurobranch)"
COL_DEC_K     = "decision次数(kissat)"
COL_DEC_N     = "decision次数(neurobranch)"
COL_CON_K     = "conflict次数(kissat)"
COL_CON_N     = "conflict次数(neurobranch)"

# 2. 确保需要排序的数值列为 numeric 类型（防止被当成字符串）
for col in [COL_DEC_K, COL_DEC_N, COL_CON_K, COL_CON_N]:
    df[col] = pd.to_numeric(df[col], errors="coerce")

# 3. 按指定规则排序
#   文件绝对路径
#   求解结果(kissat)
#   求解结果(neurobranch)
#   decision次数(kissat)
#   conflict次数(kissat)
#   decision次数(neurobranch)
#   conflict次数(neurobranch)
df_sorted = df.sort_values(
    by=[
        COL_FILE,
        COL_RES_K,
        COL_RES_N,
        COL_DEC_K,
        COL_CON_K,
        COL_DEC_N,
        COL_CON_N,
    ],
    ascending=[True, True, True, True, True, True, True],
)

# 4. 先写一个基础的 Excel 文件
df_sorted.to_excel(out_xlsx, index=False)

# 5. 用 openpyxl 打开 Excel 并上色
wb = load_workbook(out_xlsx)
ws = wb.active

# 获取列索引（根据表头匹配）
header = {cell.value: cell.column for cell in ws[1]}

dec_k_col = header.get(COL_DEC_K)
dec_n_col = header.get(COL_DEC_N)
con_k_col = header.get(COL_CON_K)
con_n_col = header.get(COL_CON_N)

if None in (dec_k_col, dec_n_col, con_k_col, con_n_col):
    raise RuntimeError("列名与预期不符，请检查 CSV 表头。")

# 定义填充颜色（浅绿和浅黄，接近 Excel 默认的条件格式颜色）
green_fill = PatternFill(start_color="C6EFCE", end_color="C6EFCE", fill_type="solid")
yellow_fill = PatternFill(start_color="FFF2CC", end_color="FFF2CC", fill_type="solid")

# 从第二行开始遍历（第一行是表头）
for row in range(2, ws.max_row + 1):
    # 读取 decision 次数
    dk_cell = ws.cell(row=row, column=dec_k_col)
    dn_cell = ws.cell(row=row, column=dec_n_col)
    ck_cell = ws.cell(row=row, column=con_k_col)
    cn_cell = ws.cell(row=row, column=con_n_col)

    dk = dk_cell.value
    dn = dn_cell.value
    ck = ck_cell.value
    cn = cn_cell.value

    # 只对数值做比较
    try:
        dk_val = float(dk) if dk is not None else None
        dn_val = float(dn) if dn is not None else None
        ck_val = float(ck) if ck is not None else None
        cn_val = float(cn) if cn is not None else None
    except (TypeError, ValueError):
        continue

    # ---- decision 次数高亮 ----
    if dk_val is not None and dn_val is not None:
        if dk_val > dn_val:
            # kissat decision 更多 => neurobranch 更优 => 标黄
            dk_cell.fill = yellow_fill
            dn_cell.fill = yellow_fill
        elif dk_val < dn_val:
            # kissat decision 更少 => kissat 更优 => 标绿
            dk_cell.fill = green_fill
            dn_cell.fill = green_fill
        # 相等则不高亮

    # ---- conflict 次数高亮 ----
    if ck_val is not None and cn_val is not None:
        if ck_val > cn_val:
            # kissat conflict 更多 => neurobranch 更优 => 标黄
            ck_cell.fill = yellow_fill
            cn_cell.fill = yellow_fill
        elif ck_val < cn_val:
            # kissat conflict 更少 => kissat 更优 => 标绿
            ck_cell.fill = green_fill
            cn_cell.fill = green_fill
        # 相等则不高亮

wb.save(out_xlsx)
print(f"已生成排序并高亮的 Excel 文件：{out_xlsx}")
EOF