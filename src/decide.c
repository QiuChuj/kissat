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

// void kissat_write_cnf (kissat *solver, const char *filename) {
//   FILE *file = fopen (filename, "w");
//   unsigned clause_count = 0;
//   for (all_clauses (C)) {
//     if (!C->garbage && !C->shrunken) {
//       clause_count++;
//     }
//   }
//   fprintf (file, "p cnf %u %u\n", solver->vars, clause_count);
//   for (all_clauses (C)) {
//     if (C->garbage || C->shrunken)
//       continue;
//     for (unsigned i = 0; i < C->size; i++) {
//       unsigned lit_index = C->lits[i];
//       int var_index = lit_index / 2;
//       int sign = (lit_index % 2 == 0) ? 1 : -1;
//       fprintf (file, "%d ", sign * (var_index + 1));
//     }
//     fprintf (file, "0\n");
//   }
//   fclose (file);
// }

// void kissat_write_scores (kissat *solver, const char *filename) {
//   FILE *file = fopen (filename, "w");
//   heap *score_output = &solver->scores;
//   unsigned idx = 0;
//   for (idx = 0; idx < score_output->vars; idx++) {

//     // unsigned _pos = score_output->pos[idx];
//     fprintf (file, "%f,%u\n", score_output->score[idx],
//              score_output->pos[idx]);
//     // fprintf (file, "%u\n", score_output->pos[idx]);
//     // fprintf (file, "%u\n", score_output->stack.begin[idx]);
//   }
//   fclose (file);
// }

// unsigned kissat_pick_benchmark (char *filename) {
//   FILE *file = fopen (filename, "r");
//   char line[1024]; // 缓冲区存储读取的行
//   if (fgets (line, sizeof (line), file) == NULL) {
//     fclose (file);
//     printf ("Error: File is empty\n");
//     return 0; // 返回 0 表示错误（文件为空）
//   }
//   fclose (file); // 读取后立即关闭文件
//   // 创建行的副本，因为 strtok 会修改原始字符串
//   char line_copy[1024];
//   strncpy (line_copy, line, sizeof (line_copy));
//   line_copy[sizeof (line_copy) - 1] = '\0'; // 确保字符串终止
//   // 第一遍：计算 token 数量（数组元素个数）
//   int count = 0;
//   char *token = strtok (line_copy, ",");
//   while (token != NULL) {
//     count++;
//     token = strtok (NULL, ",");
//   }
//   if (count == 0) {
//     printf ("Error: No data found in CSV\n");
//     return 0; // 返回 0 表示错误（无数据）
//   }
//   // 第二遍：解析数值并存储到数组
//   double *values = (double *) malloc (count * sizeof (double));
//   if (values == NULL) {
//     perror ("Error: Memory allocation failed");
//     return 0; // 返回 0 表示错误（内存分配失败）
//   }
//   // 创建另一个副本用于解析数值
//   strncpy (line_copy, line, sizeof (line_copy));
//   line_copy[sizeof (line_copy) - 1] = '\0';
//   int index = 0;
//   token = strtok (line_copy, ",");
//   while (token != NULL && index < count) {
//     values[index] = atof (token); // 将字符串转换为 double
//     index++;
//     token = strtok (NULL, ",");
//   }
//   // 查找最大值元素的索引
//   double max_val = -DBL_MAX; // 初始化为最小可能的 double 值
//   unsigned max_index = 0;
//   for (int i = 0; i < count; i++) {
//     if (values[i] > max_val) {
//       max_val = values[i];
//       max_index = i;
//     }
//   }
//   free (values);    // 释放动态分配的内存
//   return max_index; // 返回最大值元素的索引（从 0 开始）
// }

//! 这里是共享内存操作

// 信号量操作
void sem_op (int semid, int op) {
    struct sembuf sb = {0, op, 0};
    semop (semid, &sb, 1);
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
    //! 这里是提取八个特征向量的代码

    // 等待Python处理
    while (solver->data->ready != 2) {
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
    solver->decided++;
    if (!solver->neurobranch_mode) {
        //! train
        //! 输出当前clauses
        char filepath[256];
        snprintf (filepath, sizeof (filepath),
                  "/home/richard/project/neurobranch/dimacs/train/clauses/%s/",
                  solver->input_path);
        mode_t mode = 0755;
        mkdir (filepath, mode);
        snprintf (filepath, sizeof (filepath),
                  "/home/richard/project/neurobranch/dimacs/train/scores/%s/",
                  solver->input_path);
        mkdir (filepath, mode);
        char filename[256];
        snprintf (filename, sizeof (filename),
                  "/home/richard/project/neurobranch/dimacs/train/clauses/%s/"
                  "decision%d.cnf",
                  solver->input_path, solver->decided);
        kissat_write_cnf (solver, filename);
        //! 输出当前变量的EVSIDS得分
        char filename2[256];
        snprintf (filename2, sizeof (filename2),
                  "/home/richard/project/neurobranch/dimacs/train/scores/%s/"
                  "decision%d.csv",
                  solver->input_path, solver->decided);
        kissat_write_scores (solver, filename2);
    } else { //! apply
        if (solver->decided % 10 == 0) {
            if (solver->neurobranch_mode == 1)
                apply_neurobranch (solver);
            if (solver->neurobranch_mode == 2)
                apply_neurobranch_simp (solver);
        }
    }

    const unsigned idx = kissat_next_decision_variable (solver);
    // printf ("Decided variable: %u\n", idx);
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
