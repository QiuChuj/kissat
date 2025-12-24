// neuro_const.h

#ifndef NEURO_CONST_H
#define NEURO_CONST_H

// 简化版 neurobranch_simp 特征
enum {
    SIMP_FEATURES = 9, // 每个变量 9 维特征
    SIMP_VARS = 10000, // 最多 10000 个变量
};

// 原始版 neurobranch (shared_data)
enum {
    FULL_FEATURES = 2, // features[2][20000]，你这里本来就写死了 2
    FULL_PAIRS = 20000,
    FULL_OUTPUT = 500,
};

#endif // NEURO_CONST_H