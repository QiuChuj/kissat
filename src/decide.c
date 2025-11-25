#include "decide.h"
#include "heap.h"
#include "inlineframes.h"
#include "inlineheap.h"
#include "inlinequeue.h"
#include "print.h"

#include <float.h> // 用于 DBL_MIN 常量
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/stat.h>  // 包含mkdir函数声明
#include <sys/types.h> // 包含mode_t类型定义
#include <time.h>
#include <unistd.h>

static unsigned last_enqueued_unassigned_variable (kissat *solver) {
    assert (solver->unassigned);
    const links *const links = solver->links;
    const value *const values = solver->values;
    unsigned res = solver->queue.search.idx;
    if (values[LIT (res)]) {
        do {
            res = links[res].prev;
            assert (!DISCONNECTED (res));
        } while (values[LIT (res)]);
        kissat_update_queue (solver, links, res);
    }
#ifdef LOGGING
    const unsigned stamp = links[res].stamp;
    LOG ("last enqueued unassigned %s stamp %u", LOGVAR (res), stamp);
#endif
#ifdef CHECK_QUEUE
    for (unsigned i = links[res].next; !DISCONNECTED (i); i = links[i].next)
        assert (VALUE (LIT (i)));
#endif
    return res;
}

static unsigned largest_score_unassigned_variable (kissat *solver) {
    heap *scores = SCORES;
    unsigned res = kissat_max_heap (scores);
    const value *const values = solver->values;
    while (values[LIT (res)]) {
        kissat_pop_max_heap (solver, scores);
        res = kissat_max_heap (scores);
    }
#if defined(LOGGING) || defined(CHECK_HEAP)
    const double score = kissat_get_heap_score (scores, res);
#endif
    LOG ("largest score unassigned %s score %g", LOGVAR (res), score);
#ifdef CHECK_HEAP
    for (all_variables (idx)) {
        if (!ACTIVE (idx))
            continue;
        if (VALUE (LIT (idx)))
            continue;
        const double idx_score = kissat_get_heap_score (scores, idx);
        assert (score >= idx_score);
    }
#endif
    return res;
}

void kissat_start_random_sequence (kissat *solver) {
    if (!GET_OPTION (randec))
        return;

    if (solver->stable && !GET_OPTION (randecstable))
        return;

    if (!solver->stable && !GET_OPTION (randecfocused))
        return;

    if (solver->randec)
        kissat_very_verbose (solver,
                             "continuing random decision sequence "
                             "at %s conflicts",
                             FORMAT_COUNT (CONFLICTS));
    else {
        INC (random_sequences);
        const uint64_t count = solver->statistics.random_sequences;
        const unsigned length = GET_OPTION (randeclength) * LOGN (count);
        kissat_very_verbose (solver,
                             "starting random decision sequence "
                             "at %s conflicts for %s conflicts",
                             FORMAT_COUNT (CONFLICTS), FORMAT_COUNT (length));
        solver->randec = length;

        UPDATE_CONFLICT_LIMIT (randec, random_sequences, LOGN, false);
    }
}

static unsigned next_random_decision (kissat *solver) {
    if (!VARS)
        return INVALID_IDX;

    if (solver->warming)
        return INVALID_IDX;

    if (!GET_OPTION (randec))
        return INVALID_IDX;

    if (solver->stable && !GET_OPTION (randecstable))
        return INVALID_IDX;

    if (!solver->stable && !GET_OPTION (randecfocused))
        return INVALID_IDX;

    if (!solver->randec) {
        assert (solver->level);
        if (solver->level > 1)
            return INVALID_IDX;

        uint64_t conflicts = CONFLICTS;
        limits *limits = &solver->limits;
        if (conflicts < limits->randec.conflicts)
            return INVALID_IDX;

        kissat_start_random_sequence (solver);
    }

    for (;;) {
        unsigned idx = kissat_next_random32 (&solver->random) % VARS;
        if (!ACTIVE (idx))
            continue;
        unsigned lit = LIT (idx);
        if (solver->values[lit])
            continue;
        return idx;
    }
}

unsigned kissat_next_decision_variable (kissat *solver) {
#ifdef LOGGING
    const char *type = 0;
#endif
    unsigned res = next_random_decision (solver);
    if (res == INVALID_IDX) {
        if (solver->stable) {
#ifdef LOGGING
            type = "maximum score";
#endif
            res = largest_score_unassigned_variable (solver);
            INC (score_decisions);
            // printf ("largest_score_unassigned_variable: %u\n", res);
        } else {
#ifdef LOGGING
            type = "dequeued";
#endif
            res = last_enqueued_unassigned_variable (solver);
            INC (queue_decisions);
            // printf ("last_enqueued_unassigned_variable: %u\n", res);
        }
    } else {
#ifdef LOGGING
        type = "random";
#endif
        INC (random_decisions);
        // printf ("random_decision: %u\n", res);
    }
    LOG ("next %s decision %s", type, LOGVAR (res));
    return res;
}

int kissat_decide_phase (kissat *solver, unsigned idx) {
    bool force = GET_OPTION (forcephase);

    value *target;
    if (force)
        target = 0;
    else if (!GET_OPTION (target))
        target = 0;
    else if (solver->stable || GET_OPTION (target) > 1)
        target = solver->phases.target + idx;
    else
        target = 0;

    value *saved;
    if (force)
        saved = 0;
    else if (GET_OPTION (phasesaving))
        saved = solver->phases.saved + idx;
    else
        saved = 0;

    value res = 0;

    if (!solver->stable) {
        switch ((solver->statistics.switched >> 1) & 7) {
        case 1:
            res = INITIAL_PHASE;
            break;
        case 3:
            res = -INITIAL_PHASE;
            break;
        }
    }

    if (!res && target && (res = *target)) {
        LOG ("%s uses target decision phase %d", LOGVAR (idx), (int) res);
        INC (target_decisions);
    }

    if (!res && saved && (res = *saved)) {
        LOG ("%s uses saved decision phase %d", LOGVAR (idx), (int) res);
        INC (saved_decisions);
    }

    if (!res) {
        res = INITIAL_PHASE;
        LOG ("%s uses initial decision phase %d", LOGVAR (idx), (int) res);
        INC (initial_decisions);
    }
    assert (res);

    return res < 0 ? -1 : 1;
}

void kissat_write_cnf (kissat *solver, const char *filename) {
    FILE *file = fopen (filename, "w");
    unsigned clause_count = 0;
    for (all_clauses (C)) {
        if (!C->garbage && !C->shrunken) {
            clause_count++;
        }
    }
    fprintf (file, "p cnf %u %u\n", solver->vars, clause_count);
    for (all_clauses (C)) {
        if (C->garbage || C->shrunken)
            continue;
        for (unsigned i = 0; i < C->size; i++) {
            unsigned lit_index = C->lits[i];
            int var_index = lit_index / 2;
            int sign = (lit_index % 2 == 0) ? 1 : -1;
            fprintf (file, "%d ", sign * (var_index + 1));
        }
        fprintf (file, "0\n");
    }
    fclose (file);
}

void kissat_write_simple_features (kissat *solver, const char *filename) {
    FILE *file = fopen (filename, "w");
    unsigned idx = 0;
    for (idx = 0; idx < 1000; idx++) {
        fprintf (file, "%f,%f,%f,%f,%f,%f,%f,%f\n",
                 (double) solver->appearance_count[idx],
                 (double) solver->conflict_appearance[idx],
                 (double) solver->decision_num[idx],
                 (double) solver->generated_appearance[idx],
                 (double) solver->LBD_min[idx],
                 (double) solver->short_clause_appearance[idx],
                 (double) solver->decision_level[idx],
                 (double) solver->polarity_distribution[idx]);
    }
    fclose (file);
}

void kissat_write_scores (kissat *solver, const char *filename) {
    FILE *file = fopen (filename, "w");
    heap *scores = &solver->scores;
    unsigned idx = 0;
    for (idx = 0; idx < solver->vars; idx++) {
        fprintf (file, "%f\n", scores->score[idx]);
    }
    fclose (file);
}

// 用于qsort的比较函数
int compare (const void *a, const void *b) { return (*(int *) a - *(int *) b); }

int countDistinctExceptZeroSorted (int arr[], int size) {
    // 先对数组排序
    qsort (arr, size, sizeof (int), compare);

    int uniqueCount = 0;
    int lastNumber = 0; // 用于记录上一个处理的数，初始化为0（因为0被跳过）

    for (int i = 0; i < size; i++) {
        if (arr[i] == 0) {
            continue; // 跳过0
        }
        // 如果是第一个非零元素，或者当前元素与上一个不同，则计数
        if (uniqueCount == 0 || arr[i] != lastNumber) {
            uniqueCount++;
            lastNumber = arr[i];
        }
    }
    return uniqueCount;
}

//! 这里是共享内存操作

// 信号量操作
void sem_op (int semid, int op) {
    struct sembuf sb = {0, op, 0};
    semop (semid, &sb, 1);
}

void get_simp_data (kissat *solver) {
    //! 这里是提取特征向量的代码
    int clause_count = 0;
    unsigned l = 0;
    for (all_clauses (C)) {
        if (C->garbage || C->shrunken || C->var_count_used)
            continue;
        C->var_count_used = true;
        int decision_levels[50];
        for (l = 0; l < C->size; l++) {
            //! 1、统计每个variable在所有子句中的出现次数
            int var = C->lits[l] / 2;
            solver->appearance_count[var]++;
            //! 2、统计在短子句中出现的次数
            if (C->size <= 2)
                solver->short_clause_appearance[var]++;
            //! 3、统计极性
            if (C->lits[l] % 2 == 0)
                solver->polarity_positive[var]++;
            solver->polarity_distribution[var] =
                (double) solver->polarity_positive[var] /
                (double) solver->appearance_count[var];
            //! 4、统计在生成子句中出现的次数
            if (!C->resident)
                solver->generated_appearance[var]++;
            //! 5、统计LBD
            decision_levels[l] = solver->decision_level[var];

            //! 决策层提取的代码在inlineassign.h的78行
            //! 决策次数提取代码在下面的kissat_decide函数中
            //! 冲突子句中出现次数提取代码在search.c中
        }
        C->LBD = countDistinctExceptZeroSorted (decision_levels, l);
        clause_count++;
    }
    for (all_clauses (C)) {
        for (l = 0; l < C->size; l++) {
            int var = C->lits[l] / 2;
            if (solver->LBD_min[var] == 0) {
                solver->LBD_min[var] = C->LBD;
                continue;
            } else {
                if (C->LBD < solver->LBD_min[var])
                    solver->LBD_min[var] = C->LBD;
            }
        }
    }
}

//! 第一种思路：直接使用整个cnf文件作为输入
void apply_neurobranch (kissat *solver) {
    // 创建共享内存文件
    semctl (solver->semid, 0, SETVAL, 1);

    // printf ("C程序开始通信...\n");

    // 准备数据
    sem_op (solver->semid, -1);
    int clause_count = 0;
    int literal_count = 0;
    for (all_clauses (c)) {
        if (c->garbage || c->shrunken)
            continue;
        unsigned l = 0;
        for (l = 0; l < c->size; l++) {
            if (solver->data->features[0][literal_count] != clause_count)
                solver->data->features[0][literal_count] = clause_count;
            if (solver->data->features[1][literal_count++] != c->lits[l])
                solver->data->features[1][literal_count++] = c->lits[l];
        }
        clause_count++;
    }
    solver->data->n_vars = solver->vars;
    solver->data->n_clauses = clause_count;
    solver->data->ready = 1; // 标记数据就绪
    sem_op (solver->semid, 1);

    // printf ("C端数据已发送，等待Python处理...\n");
    printf ("%d clauses, %d literals.\n", clause_count, literal_count);

    // 等待Python处理
    while (solver->data->ready != 2) {
        usleep (0.1);
    }

    // 读取结果并置换求解器中的vsids分数
    sem_op (solver->semid, -1);
    double *nn_output = solver->data->result;
    heap *score_output = &solver->scores;
    unsigned idx = 0;
    // 用神经网络计算出的分数代替原本vsids分数
    for (idx = 0; idx < solver->vars; idx++) {
        score_output->score[idx] = nn_output[idx];
    }
    solver->data->ready = 0;
    sem_op (solver->semid, 1);
}

//! 第二种思路：使用一些较为简单的特征构建一个小型网络
void apply_neurobranch_simp (kissat *solver) {
    // 使用neurobranch_simp
    semctl (solver->semid, 0, SETVAL, 1);

    // printf ("C程序开始通信...\n");
    sem_op (solver->semid, -1);

    // 准备数据
    int l;
    for (l = 0; l < 1000; l++) {
        //! 八个特征向量填入共享内存
        solver->data_simp->features[0][l] =
            (double) solver->appearance_count[l];
        solver->data_simp->features[1][l] =
            (double) solver->conflict_appearance[l];
        solver->data_simp->features[2][l] = (double) solver->decision_num[l];
        solver->data_simp->features[3][l] =
            (double) solver->generated_appearance[l];
        solver->data_simp->features[4][l] = (double) solver->LBD_min[l];
        solver->data_simp->features[5][l] =
            (double) solver->short_clause_appearance[l];
        solver->data_simp->features[6][l] = (double) solver->decision_level[l];
        solver->data_simp->features[7][l] =
            (double) solver->polarity_distribution[l];
    }
    solver->data_simp->ready = 1;

    // 等待Python处理
    while (solver->data_simp->ready != 2) {
        usleep (0.1);
    }

    // 读取结果并置换求解器中的vsids分数
    sem_op (solver->semid, -1);
    double *nn_output = solver->data_simp->result;
    heap *score_output = &solver->scores;
    unsigned idx = 0;
    // 用神经网络计算出的分数代替原本vsids分数
    for (idx = 0; idx < solver->vars; idx++) {
        score_output->score[idx] = nn_output[idx];
    }
    solver->data->ready = 0;
    sem_op (solver->semid, 1);
}
//! 这里是共享内存操作

void kissat_decide (kissat *solver) {
    // printf ("Dicide Starts\n");
    struct timespec _start, _end;
    clock_gettime (CLOCK_MONOTONIC, &_start);
    START (decide);
    assert (solver->unassigned);
    if (solver->warming)
        INC (warming_decisions);
    else {
        INC (decisions);
        if (solver->stable)
            INC (stable_decisions);
        else
            INC (focused_decisions);
    }
    solver->level++;
    assert (solver->level != INVALID_LEVEL);

    //! 加入了模式判断逻辑，自动执行对应代码
    // printf ("train_mode: %d\n", solver->train_mode);
    solver->decided++;
    if (!solver->use_neurobranch) {
        //! 不使用neurobranch
    } else if (solver->train_mode) {
        //! train
        get_simp_data (solver);
        srand (time (NULL));
        int rand_value = rand () % 20;
        if (!solver->simple_mode) {
            if (solver->decided % 20 == rand_value) {
                //! 提取原始版本neurobranch训练数据
                //! 输出当前clauses
                char filepath[256];
                snprintf (filepath, sizeof (filepath),
                          "/home/richard/project/neurobranch_train_data/"
                          "neurobranch/data/%s/",
                          solver->input_path);
                mode_t mode = 0755;
                mkdir (filepath, mode);
                char filepath2[256];
                snprintf (filepath2, sizeof (filepath2),
                          "/home/richard/project/neurobranch_train_data/"
                          "neurobranch/label/%s/",
                          solver->input_path);
                mkdir (filepath2, mode);
                char filename[256];
                snprintf (filename, sizeof (filename), "%sdecision%d.cnf",
                          filepath, solver->decided);
                kissat_write_cnf (solver, filename);
                //! 输出当前变量的得分
                char filename2[256];
                snprintf (filename2, sizeof (filename2), "%sdecision%d.csv",
                          filepath2, solver->decided);
                kissat_write_simple_features (solver, filename2);
            }
        } else {
            if (solver->decided % 20 == rand_value) {
                //! 提取原始版本neurobranch训练数据
                //! 输出当前clauses
                char filepath[256];
                snprintf (filepath, sizeof (filepath),
                          "/home/richard/project/neurobranch_train_data/"
                          "neurobranch_simp/data/%s/",
                          solver->input_path);
                mode_t mode = 0755;
                mkdir (filepath, mode);
                char filepath2[256];
                snprintf (filepath2, sizeof (filepath2),
                          "/home/richard/project/neurobranch_train_data/"
                          "neurobranch_simp/label/%s/",
                          solver->input_path);
                mkdir (filepath2, mode);
                char filename[256];
                snprintf (filename, sizeof (filename), "%sdecision%d.csv",
                          filepath, solver->decided);
                kissat_write_simple_features (solver, filename);
                //! 输出当前变量的得分
                char filename2[256];
                snprintf (filename2, sizeof (filename2), "%sdecision%d.csv",
                          filepath2, solver->decided);
                kissat_write_scores (solver, filename2);
            }
        }
    } else { //! apply
        get_simp_data (solver);
        srand (time (NULL));
        int rand_value = rand () % 10;
        if (solver->decided % 10 == rand_value) {
            if (!solver->simple_mode)
                apply_neurobranch (solver);
            else
                apply_neurobranch_simp (solver);
        }
    }
    // printf ("neurobranch部分执行完毕\n");

    const unsigned idx = kissat_next_decision_variable (solver);
    printf ("Decided variable: %u\n", idx);
    //! 这里记录一下决策次数
    solver->decision_num[idx]++;
    const value value = kissat_decide_phase (solver, idx);
    unsigned lit = LIT (idx);
    if (value < 0)
        lit = NOT (lit);
    kissat_push_frame (solver, lit);
    assert (solver->level < SIZE_STACK (solver->frames));
    LOG ("decide literal %s", LOGLIT (lit));
    kissat_assign_decision (solver, lit);
    STOP (decide);
    clock_gettime (CLOCK_MONOTONIC, &_end);
    long time_ns = (_end.tv_sec - _start.tv_sec) * 1000000000L +
                   (_end.tv_nsec - _start.tv_nsec);
    solver->decision_time_ns += time_ns;
    // printf ("Decision Complete.\n");
}

void kissat_internal_assume (kissat *solver, unsigned lit) {
    assert (solver->unassigned);
    assert (!VALUE (lit));
    solver->level++;
    assert (solver->level != INVALID_LEVEL);
    kissat_push_frame (solver, lit);
    assert (solver->level < SIZE_STACK (solver->frames));
    LOG ("assuming literal %s", LOGLIT (lit));
    kissat_assign_decision (solver, lit);
}
