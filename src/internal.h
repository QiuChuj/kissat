#ifndef _internal_h_INCLUDED
#define _internal_h_INCLUDED

#include "arena.h"
#include "array.h"
#include "assign.h"
#include "averages.h"
#include "check.h"
#include "classify.h"
#include "clause.h"
#include "cover.h"
#include "extend.h"
#include "flags.h"
#include "format.h"
#include "frames.h"
#include "heap.h"
#include "kimits.h"
#include "kissat.h"
#include "literal.h"
#include "mode.h"
#include "options.h"
#include "phases.h"
#include "profile.h"
#include "proof.h"
#include "queue.h"
#include "random.h"
#include "reluctant.h"
#include "rephase.h"
#include "smooth.h"
#include "stack.h"
#include "statistics.h"
#include "value.h"
#include "vector.h"
#include "watch.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/stat.h>  // 包含mkdir函数声明
#include <sys/types.h> // 包含mode_t类型定义
#include <time.h>
#include <unistd.h>

typedef struct datarank datarank;

struct datarank {
    unsigned data;
    unsigned rank;
};

typedef struct import import;

struct import {
    unsigned lit;
    bool extension;
    bool imported;
    bool eliminated;
};

typedef struct termination termination;

struct termination {
#ifdef COVERAGE
    volatile uint64_t flagged;
#else
    volatile bool flagged;
#endif
    volatile void *state;
    int (*volatile terminate) (void *);
};

// clang-format off

typedef STACK (value) eliminated;
typedef STACK (import) imports;
typedef STACK (datarank) dataranks;
typedef STACK (watch) statches;
typedef STACK (watch *) patches;

// clang-format on

struct kitten;

//! 定义neurobranch数据结构
struct shared_data {
    int features[2][20000];
    double result[500];
    int ready;
    unsigned n_vars;
    unsigned n_clauses;
};

//! 定义neurobranch_simp数据结构
struct shared_data_simp {
    double features[9][1000];
    double result[1000];
    // double reward;
    // bool used[1000];
    int ready;
    unsigned n_vars;
    unsigned n_clauses;
};

struct kissat {
#if !defined(NDEBUG) || defined(METRICS)
    bool backbone_computing;
#endif
#ifdef LOGGING
    bool compacting;
#endif
    bool extended;
    bool inconsistent;
    bool iterating;
    bool preprocessing;
    bool probing;
#ifndef QUIET
    bool sectioned;
#endif
    bool stable;
#if !defined(NDEBUG) || defined(METRICS)
    bool transitive_reducing;
    bool vivifying;
#endif
    bool warming;
    bool watching;

    bool large_clauses_watched_after_binary_clauses;

    termination termination;

    unsigned vars;
    unsigned size;
    unsigned active;
    unsigned randec;
    int decided;
    //! 设置时间变量用于计时
    struct timespec start, end;
    long decision_time_ns;
    //! 设置超时标记
    bool timeout;
    //! 输入路径
    char input_path[256];
    char data_path[256];
    char label_path[256];
    //! neurobranch模式变量
    int clause_count;
    int rand_value;
    int use_neurobranch;
    int train_mode;
    int simple_mode;
    key_t key;
    int shmid;
    struct shared_data *data;
    struct shared_data_simp *data_simp;
    int semid;
    //! simple版的八个特征向量
    int appearance_count[1000];
    int conflict_appearance[1000];
    int decision_num[1000];
    int generated_appearance[1000];
    int LBD_min[1000];
    int short_clause_appearance[1000];
    unsigned decision_level[1000];
    double polarity_distribution[1000];
    int polarity_positive[1000];
    int in_trail[1000];

    ints export;
    ints units;
    imports import;
    extensions extend;
    unsigneds witness;

    assigned *assigned;
    flags *flags;

    mark *marks;

    //! 这里是一个指针数组，表示每个变量的值。
    value *values;
    phases phases;

    eliminated eliminated;
    unsigneds etrail;

    links *links;
    queue queue;

    //! 这里是一个堆，存储变量的得分。
    heap scores;
    double scinc;

    heap schedule;
    double scoreshift;

    //! 决策层
    unsigned level;
    frames frames;

    //! 这里是所有已经赋值的文字的轨迹。
    unsigned_array trail;
    unsigned *propagate;

    unsigned best_assigned;
    unsigned target_assigned;
    unsigned unflushed;
    unsigned unassigned;

    unsigneds delayed;

#if defined(LOGGING) || !defined(NDEBUG)
    unsigneds resolvent;
#endif
    unsigned resolvent_size;
    unsigned antecedent_size;

    dataranks ranks;

    unsigneds analyzed;
    unsigneds levels;
    unsigneds minimize;
    unsigneds poisoned;
    unsigneds promote;
    unsigneds removable;
    unsigneds shrinkable;

    clause conflict;

    bool clause_satisfied;
    bool clause_shrink;
    bool clause_trivial;

    unsigneds clause;
    unsigneds shadow;

    arena arena;
    vectors vectors;
    reference first_reducible;
    reference last_irredundant;
    watches *watches;

    reference last_learned[4];

    sizes sorter;

    generator random;
    averages averages[2];
    unsigned tier1[2], tier2[2];
    reluctant reluctant;

    bounds bounds;
    classification classification;
    delays delays;
    enabled enabled;
    limited limited;
    limits limits;
    remember last;
    unsigned walked;

    mode mode;

    uint64_t ticks;

    format format;

    statches antecedents[2];
    statches gates[2];
    patches xorted[2];
    unsigneds resolvents;
    bool resolve_gate;

    struct kitten *kitten;
#ifdef METRICS
    uint64_t *gate_eliminated;
#else
    bool gate_eliminated;
#endif
    bool sweep_incomplete;
    unsigneds sweep_schedule;

#if !defined(NDEBUG) || !defined(NPROOFS)
    unsigneds added;
    unsigneds removed;
#endif

#if !defined(NDEBUG) || !defined(NPROOFS) || defined(LOGGING)
    ints original;
    size_t offset_of_last_original_clause;
#endif

#ifndef QUIET
    profiles profiles;
#endif

#ifndef NOPTIONS
    options options;
#endif

#ifndef NDEBUG
    checker *checker;
#endif

#ifndef NPROOFS
    proof *proof;
#endif

    statistics statistics;
};

#define VARS (solver->vars)
#define LITS (2 * solver->vars)

#if 0
#define TIEDX (GET_OPTION (focusedtiers) ? 0 : solver->stable)
#define TIER1 (solver->tier1[TIEDX])
#define TIER2 (solver->tier2[TIEDX])
#else
#define TIER1 (solver->tier1[0])
#define TIER2 (solver->tier2[1])
#endif

//! 变量的得分
#define SCORES (&solver->scores)

static inline unsigned kissat_assigned (kissat *solver) {
    assert (VARS >= solver->unassigned);
    return VARS - solver->unassigned;
}

#define all_variables(IDX) \
    unsigned IDX = 0, IDX##_END = solver->vars; \
    IDX != IDX##_END; \
    ++IDX

#define all_literals(LIT) \
    unsigned LIT = 0, LIT##_END = LITS; \
    LIT != LIT##_END; \
    ++LIT

#define all_clauses(C) \
    clause *C = (clause *) BEGIN_STACK (solver->arena), \
           *const C##_END = (clause *) END_STACK (solver->arena), *C##_NEXT; \
    C != C##_END && (C##_NEXT = kissat_next_clause (C), true); \
    C = C##_NEXT

#define capacity_last_learned \
    (sizeof solver->last_learned / sizeof *solver->last_learned)

#define real_end_last_learned (solver->last_learned + capacity_last_learned)

#define really_all_last_learned(REF_PTR) \
    reference *REF_PTR = solver->last_learned, \
              *REF_PTR##_END = real_end_last_learned; \
    REF_PTR != REF_PTR##_END; \
    REF_PTR++

void kissat_reset_last_learned (kissat *solver);

#endif
