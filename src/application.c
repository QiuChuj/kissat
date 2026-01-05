#include "application.h"
#include "check.h"
#include "colors.h"
#include "config.h"
#include "error.h"
#include "internal.h"
#include "keatures.h"
#include "krite.h"
#include "parse.h"
#include "print.h"
#include "proof.h"
#include "resources.h"
#include "witness.h"

#include <errno.h>
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

#define SOLVER_NAME "Kissat SAT Solver"

typedef struct application application;

struct application {
    kissat *solver;
    int worker_id;
    const char *input_path;
    const char *output_path;
#ifndef NPROOFS
    const char *proof_path;
    file proof_file;
    int binary;
#endif
#if !defined(NPROOFS) || !defined(KISSAT_HAS_COMPRESSION)
    bool force;
#endif
    int time;
    int conflicts;
    int decisions;
    strictness strict;
    bool partial;
    bool witness;
    int max_var;
};

static void init_app (application *application, kissat *solver) {
    memset (application, 0, sizeof *application);
    application->solver = solver;
    application->witness = true;
    application->conflicts = -1;
    application->decisions = -1;
    application->strict = NORMAL_PARSING;
    application->worker_id = -1;
}

static void print_common_dimacs_and_proof_usage (void) {
    printf ("\n");
    printf ("Furthermore '<dimacs>' is the input file in DIMACS format.\n");
#ifndef NPROOFS
    printf ("If '<proof>' is specified then a proof trace is written.\n");
#endif
}

static void print_complete_dimacs_and_proof_usage (void) {
    printf ("\n");
    printf ("Furthermore '<dimacs>' is the input file in DIMACS format.\n");
#ifdef KISSAT_HAS_COMPRESSION
    printf ("The solver reads from '<stdin>' if '<dimacs>' is unspecified.\n");
    printf ("If the path has a '.bz2', '.gz', '.lzma', '7z' or '.xz' suffix\n");
    printf ("then the solver tries to find a corresponding decompression\n");
    printf ("tool ('bzip2', 'gzip', 'lzma', '7z', or 'xz') to decompress\n");
    printf ("the input file on-the-fly after checking that the input file\n");
    printf ("has the correct format (starts with the corresponding\n");
    printf ("signature bytes).\n");
#endif
    printf ("\n");
#ifndef NPROOFS
    printf ("If '<proof>' is specified then a proof trace is written to the\n");
    printf ("given file.  If the file name is '-' then the proof is written\n");
    printf (
        "to '<stdout>'. In this case the ASCII version of the DRAT format\n");
    printf (
        "is used.  For real files the binary proof format is used unless\n");
    printf ("'--no-binary' is specified.\n");
    printf ("\n");
#ifdef KISSAT_HAS_COMPRESSION
    printf ("Writing of compressed proof files follows the same principle\n");
    printf ("as reading compressed files. The compression format is based\n");
    printf ("on the file suffix and it is checked that the corresponding\n");
    printf ("compression utility can be found.\n");
#else
    printf ("The solver was built without compression support. Therefore\n");
    printf ("compressed reading and writing are not available. This is\n");
    printf ("usually enforced by the '-p' (pedantic) configuration. If you\n");
    printf ("need compressed reading and writing then configure and build\n");
    printf ("the solver without '-p'. This will also speed-up file I/O.\n");
#endif
#else
    printf ("The solver was built without proof support. If you need proofs\n");
    printf ("use a configuration without '--no-proofs' nor '--ultimate'.\n");
#endif
}

static void print_force_usage (void) {
#if !defined(NPROOFS) && defined(KISSAT_HAS_COMPRESSION)
    printf ("  -f      force writing proofs (to existing CNF alike file)\n");
#elif !defined(NPROOFS) && !defined(KISSAT_HAS_COMPRESSION)
    printf ("  -f      force writing proofs or reading compressed files\n");
#elif defined(NPROOFS) && !defined(KISSAT_HAS_COMPRESSION)
    printf ("  -f      force reading compressed as uncompressed files\n");
#endif
}

static void print_common_usage (void) {
    printf ("usage: kissat [ <option> ... ] [ <dimacs> "
#ifndef NPROOFS
            "[ <proof> ] "
#endif
            "]\n"
            "\n"
            "where '<option>' is one of the following common options:\n"
            "\n"
            "  -h      print this list of common command line options\n"
            "  --help  print complete list of command line options\n");
    printf ("\n");
    print_force_usage ();
#if !defined(QUIET) && defined(LOGGING)
    printf ("  -l      increase logging level (implies '-v' twice)\n");
#endif
    printf ("  -n      do not print satisfying assignment\n");
#ifndef QUIET
    printf ("\n");
    printf ("  -q      suppress all messages\n");
    printf ("  -s      print complete statistics\n");
    printf ("  -v      increase verbose level\n");
#endif
    print_common_dimacs_and_proof_usage ();
}

static void print_complete_usage (void) {
    printf ("usage: kissat [ <option> ... ] [ <dimacs> "
#ifndef NPROOFS
            "[ <proof> ] "
#endif
            "]\n"
            "\n"
            "where '<option>' is one of the following common options:\n"
            "\n"
            "  --help  print this list of all command line options\n"
            "  -h      print only reduced list of command line options\n");
    printf ("\n");
    print_force_usage ();
#if !defined(QUIET) && defined(LOGGING)
    printf ("  -l      print logging messages"
#ifndef NOPTIONS
            " (see also '--log')"
#endif
            "\n");
#endif
    printf ("  -n      do not print satisfying assignment\n");
#ifndef QUIET
    printf ("\n");
    printf ("  -q      suppress all messages"
#ifndef NOPTIONS
            " (see also '--quiet')"
#endif
            "\n");
    printf ("  -s      print all statistics"
#ifndef NOPTIONS
            " (see also '--statistics')"
#endif
            "\n");
    printf ("  -v      increase verbose level"
#ifndef NOPTIONS
            " (see also '--verbose')"
#endif
            "\n");
#endif
    printf ("\n");
    printf ("Further '<option>' can be one of the "
            "following less frequent options:\n");
    printf ("\n");
    printf ("  --banner             print solver information\n");
    printf ("  --build              print build information\n");
    printf ("  --color              "
            "use colors (default if connected to terminal)\n");
    printf ("  --no-color           "
            "no colors (default if not connected to terminal)\n");
    printf ("  --compiler           print compiler information\n");
    printf ("  --copyright          print copyright information\n");
#if !defined(NOPTIONS) && defined(EMBEDDED)
    printf ("  --embedded           print embedded option list\n");
#endif
#ifndef NPROOFS
    printf ("  --force              same as '-f' (force writing proof)\n");
#endif
    printf ("  --id                 print 'git' identifier (SHA-1 hash)\n");
#ifndef NOPTIONS
    printf ("  --range              print option range list\n");
#endif
    printf ("  --relaxed            relaxed parsing"
            " (ignore DIMACS header)\n");
    printf ("  --strict             stricter parsing"
            " (no empty header lines)\n");
    printf ("  --version            print version\n");
    printf ("\n");
    printf ("The following solving limits can be enforced:\n");
    printf ("\n");
    printf ("  --conflicts=<limit>\n");
    printf ("  --decisions=<limit>\n");
    printf ("  --time=<seconds>\n");
    printf ("\n");
    printf (
        "Satisfying assignments have by default values for all variables\n");
    printf ("unless '--partial' is specified, then only values are printed\n");
    printf ("for variables which are necessary to satisfy the formula.\n");
    printf ("\n");
#ifndef NOPTIONS
    printf ("The following predefined 'configurations' (option settings) are "
            "supported:\n");
    printf ("\n");
    kissat_configuration_usage ();
    printf ("\n");
    printf ("Or '<option>' is one of the following long options:\n\n");
    kissat_options_usage ();
#else
    printf ("The solver was configured without options ('--no-options').\n");
    printf ("Thus all internal options are fixed and can not be changed.\n");
    printf ("If you want to change them at run-time use a configuration\n");
    printf ("without '--no-options'. Note, that '--extreme', '-competition'\n");
    printf ("as well as '--ultimate' all enforce '--no-options' as well.\n");
#ifdef SAT
    printf ("The '--sat' option is ignored since set at compile time.\n");
#elif UNSAT
    printf ("The '--unsat' option is ignored since set at compile time.\n");
#else
    printf ("The '--default' option is ignored but allowed.\n");
#endif
#endif
    print_complete_dimacs_and_proof_usage ();
}

static bool parsed_one_option_and_return_zero_exit_code (char *arg) {
    if (!strcmp (arg, "-h")) {
        print_common_usage ();
        return true;
    }
    if (!strcmp (arg, "--help")) {
        print_complete_usage ();
        return true;
    }
    if (!strcmp (arg, "--banner")) {
        kissat_banner (0, SOLVER_NAME);
        return true;
    }
    if (!strcmp (arg, "--build")) {
        kissat_build (0);
        return true;
    }
    if (!strcmp (arg, "--copyright")) {
        for (const char **p = kissat_copyright (), *line; (line = *p); p++)
            printf ("%s\n", line);
        return true;
    }
    if (!strcmp (arg, "--compiler")) {
        printf ("%s\n", kissat_compiler ());
        return true;
    }
#if !defined(NOPTIONS) && defined(EMBEDDED)
    if (!strcmp (arg, "--embedded")) {
        kissat_print_embedded_option_list ();
        return true;
    }
#endif
    if (!strcmp (arg, "--id")) {
        printf ("%s\n", kissat_id ());
        return true;
    }
#ifndef NOPTIONS
    if (!strcmp (arg, "--range")) {
        kissat_print_option_range_list ();
        return true;
    }
#endif
    if (!strcmp (arg, "--version")) {
        printf ("%s\n", kissat_version ());
        return true;
    }
    return false;
}

static const char *single_first_option_table[] = {
    "-h",         "--help", "--banner", "--build", "--copyright", "--compiler",
#if !defined(NOPTIONS) && defined(EMBEDDED)
    "--embedded",
#endif
    "--id",
#ifndef NOPTIONS
    "--range",
#endif
    "--version"};

static bool single_first_option (const char *arg) {
    const unsigned size = sizeof single_first_option_table / sizeof (char *);
    for (unsigned i = 0; i < size; i++)
        if (!strcmp (single_first_option_table[i], arg))
            return true;
    return false;
}

#define ERROR(...) \
    do { \
        kissat_error (__VA_ARGS__); \
        return false; \
    } while (0)

#ifndef NPROOFS

static bool most_likely_existing_cnf_file (const char *path) {
    if (!kissat_file_readable (path))
        return false;

    if (kissat_has_suffix (path, ".dimacs"))
        return true;
    if (kissat_has_suffix (path, ".dimacs.7z"))
        return true;
    if (kissat_has_suffix (path, ".dimacs.bz2"))
        return true;
    if (kissat_has_suffix (path, ".dimacs.gz"))
        return true;
    if (kissat_has_suffix (path, ".dimacs.lzma"))
        return true;
    if (kissat_has_suffix (path, ".dimacs.xz"))
        return true;

    if (kissat_has_suffix (path, ".cnf"))
        return true;
    if (kissat_has_suffix (path, ".cnf.7z"))
        return true;
    if (kissat_has_suffix (path, ".cnf.bz2"))
        return true;
    if (kissat_has_suffix (path, ".cnf.gz"))
        return true;
    if (kissat_has_suffix (path, ".cnf.lzma"))
        return true;
    if (kissat_has_suffix (path, ".cnf.xz"))
        return true;

    return false;
}

#endif

#ifndef NPROOFS

#define LONG_FALSE_OPTION(ARG, NAME) \
    (!strcmp ((ARG), "--no-" NAME) || !strcmp ((ARG), "--" NAME "=0") || \
     !strcmp ((ARG), "--" NAME "=false"))

#endif

#define LONG_TRUE_OPTION(ARG, NAME) \
    (!strcmp ((ARG), "--" NAME) || !strcmp ((ARG), "--" NAME "=1") || \
     !strcmp ((ARG), "--" NAME "=true"))

static bool parse_options (application *application, int argc, char **argv) {
    kissat *solver = application->solver;
    const char *strict_option = 0;
#ifndef NOPTIONS
    const char *configuration = 0;
#endif
#if !defined(NPROOFS) || !defined(KISSAT_HAS_COMPRESSION)
    const char *force_option = 0;
#endif
    const char *conflicts_option = 0;
    const char *decisions_option = 0;
    const char *time_option = 0;
    const char *valstr;
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (single_first_option (arg))
            ERROR ("option '%s' only allowed as %s argument", arg,
                   i == 1 ? "single" : "first");
#if !defined(NPROOFS) || !defined(KISSAT_HAS_COMPRESSION)
        else if (!strcmp (arg, "-f") || LONG_TRUE_OPTION (arg, "force") ||
                 LONG_TRUE_OPTION (arg, "forced")) {
            if (application->force) {
                assert (force_option);
                if (!strcmp (force_option, arg))
                    ERROR ("multiple '%s' options", force_option);
                else
                    ERROR ("'%s' and '%s' have the same effect", force_option,
                           arg);
            }
            application->force = true;
            force_option = arg;
        }
#endif
        else if (LONG_TRUE_OPTION (arg, "relax") ||
                 LONG_TRUE_OPTION (arg, "relaxed")) {
            if (strict_option) {
                if (application->strict != RELAXED_PARSING)
                    ERROR ("can not combine contradictory '%s' and '%s'",
                           strict_option, arg);
                else if (!strcmp (strict_option, arg))
                    ERROR ("multiple '%s' options", strict_option);
                else
                    ERROR ("'%s' and '%s' have the same effect", strict_option,
                           arg);
            }
            application->strict = RELAXED_PARSING;
            strict_option = arg;
        } else if (LONG_TRUE_OPTION (arg, "strict") ||
                   LONG_TRUE_OPTION (arg, "stricter") ||
                   LONG_TRUE_OPTION (arg, "pedantic")) {
            if (strict_option) {
                if (application->strict != PEDANTIC_PARSING)
                    ERROR ("can not combine contradictory '%s' and '%s'",
                           strict_option, arg);
                else if (!strcmp (strict_option, arg))
                    ERROR ("multiple '%s' options", strict_option);
                else
                    ERROR ("'%s' and '%s' have the same effect", strict_option,
                           arg);
            }
            application->strict = PEDANTIC_PARSING;
            strict_option = arg;
        }
#if defined(LOGGING) && !defined(QUIET) && !defined(NOPTIONS)
        else if (!strcmp (arg, "-l")) {
            int value = GET_OPTION (log);
            if (value < INT_MAX)
                value++;
            kissat_set_option (solver, "log", value);
        }
#endif
        else if (!strcmp (arg, "-n"))
            application->witness = false;
#if !defined(QUIET) && !defined(NOPTIONS)
        else if (!strcmp (arg, "-q"))
            kissat_set_option (solver, "quiet", 1);
        else if (!strcmp (arg, "-s"))
            kissat_set_option (solver, "statistics", 1);
        else if (!strcmp (arg, "-v")) {
            int value = GET_OPTION (verbose);
            if (value < INT_MAX)
                value++;
            kissat_set_option (solver, "verbose", value);
        }
#endif
        else if (!strcmp (arg, "--color") || !strcmp (arg, "--colors") ||
                 !strcmp (arg, "--colour") || !strcmp (arg, "--colours"))
            kissat_force_colors ();
        else if (!strcmp (arg, "--no-color") || !strcmp (arg, "--no-colors") ||
                 !strcmp (arg, "--no-colour") || !strcmp (arg, "--no-colours"))
            kissat_force_no_colors ();
        else if ((valstr = kissat_parse_option_name (arg, "time"))) {
            int val;
            if (kissat_parse_option_value (valstr, &val) && val > 0) {
                if (time_option)
                    ERROR ("multiple '%s' and '%s'", time_option, arg);
                application->time = val;
                alarm (val);
            } else
                ERROR ("invalid argument in '%s' (try '-h')", arg);
        } else if ((valstr = kissat_parse_option_name (arg, "conflicts"))) {
            int val;
            if (kissat_parse_option_value (valstr, &val) && val >= 0) {
                if (conflicts_option)
                    ERROR ("multiple '%s' and '%s'", conflicts_option, arg);
                kissat_set_conflict_limit (solver, val);
                application->conflicts = val;
                conflicts_option = arg;
            } else
                ERROR ("invalid argument in '%s' (try '-h')", arg);
        } else if ((valstr = kissat_parse_option_name (arg, "decisions"))) {
            int val;
            if (kissat_parse_option_value (valstr, &val) && val >= 0) {
                if (decisions_option)
                    ERROR ("multiple '%s' and '%s'", decisions_option, arg);
                kissat_set_decision_limit (solver, val);
                application->decisions = val;
                decisions_option = arg;
            } else
                ERROR ("invalid argument in '%s' (try '-h')", arg);
        } else if (!strcmp (arg, "--partial"))
            application->partial = true;
#ifndef NPROOFS
        else if (LONG_FALSE_OPTION (arg, "binary"))
            application->binary = -1;
#endif
#ifndef NOPTIONS
        else if (arg[0] == '-' && arg[1] == '-' &&
                 kissat_has_configuration (arg + 2)) {
            if (configuration)
                ERROR ("multiple configurations '%s' and '%s'", configuration,
                       arg);
            kissat_set_configuration (solver, arg + 2);
            configuration = arg;
        } else if (arg[0] == '-' && arg[1] == '-') {
            char name[kissat_options_max_name_buffer_size];
            int value;
            if (!kissat_options_parse_arg (arg, name, &value))
                ERROR ("invalid long option '%s' (try '-h')", arg);
            kissat_set_option (solver, name, value);
        }
#else
#ifdef SAT
        else if (!strcmp (arg, "--sat"))
            ;
#elif defined(UNSAT)
        else if (!strcmp (arg, "--unsat"))
            ;
#else
        else if (!strcmp (arg, "--default"))
            ;
#endif
        else if (arg[0] == '-' && arg[1] == '-')
            ERROR ("invalid long option '%s' "
                   "(configured with '--no-options')",
                   arg);
#endif
        else if (!strcmp (arg, "-o")) {

            if (++i == argc)
                ERROR ("argument to '-o' missing (try '-h')");
            arg = argv[i];
            if (application->output_path)
                ERROR ("multiple output options '-o %s' and '-o %s' (try '-h')",
                       application->output_path, arg);
            application->output_path = arg;
        }
#ifdef NOPTIONS
        else if (arg[0] == '-' && !arg[2] &&
                 (arg[1] == 'l' || arg[1] == 'q' || arg[1] == 's' ||
                  arg[1] == 'v'))
            ERROR ("invalid short option '%s' "
                   "(configured with '--no-options')",
                   arg);
#endif
#ifdef QUIET
        else if (arg[0] == '-' && !arg[2] &&
                 (arg[1] == 'q' || arg[1] == 's' || arg[1] == 'v'))
            ERROR ("invalid short option '%s' (configured with '-q')", arg);
#endif
#ifndef LOGGING
        else if (!strcmp (arg, "-l"))
            ERROR ("invalid short option '%s' "
                   "(configured without '-l' or '-g')",
                   arg);
#endif
        else if (arg[0] == '-' && arg[1])
            ERROR ("invalid short option '%s' (try '-h')", arg);
#ifndef NPROOFS
        else if (application->proof_path)
            ERROR ("three file arguments '%s', '%s' and '%s' (try '-h')",
                   application->input_path, application->proof_path, arg);
#endif
        //! 这里添加一个自定义参数worker_id，用于多处理器worker的区分
        /* 新增：如果已经有 input_path 且还没有设置 worker_id，
                   则把当前这个非选项参数当成 worker_id 来解析 */
        else if (application->input_path && application->worker_id == -1) {
            char *end;
            long wid = strtol (arg, &end, 10);
            if (*end || wid < 0 || wid > INT_MAX)
                ERROR ("invalid worker id '%s' (must be non-negative integer)",
                       arg);
            application->worker_id = (int) wid;
        }
        /* 原来的逻辑：如果已经有 input_path，则当成 proof_path 处理
           （有 NPROOFS 时则报“两文件参数”错误） */
        else if (application->input_path) {
#ifndef NPROOFS
            const char *input_path = application->input_path;
            if (!strcmp (input_path, arg))
                ERROR ("will not read and write '%s' at the same time",
                       input_path);
#ifdef KISSAT_HAS_COMPRESSION
            {
                char *real_input_path = realpath (input_path, 0);
                if (real_input_path) {
                    char *real_arg_path = realpath (arg, 0);
                    if (real_arg_path) {
                        if (!strcmp (real_input_path, real_arg_path)) {
                            if (strcmp (arg, real_arg_path) &&
                                strcmp (input_path, real_input_path))
                                ERROR ("will not read and write '%s' and '%s' "
                                       "pointing to the same file '%s'",
                                       input_path, arg, real_input_path);
                            else
                                ERROR ("will not read and write '%s' and '%s' "
                                       "pointing to the same file",
                                       input_path, arg);
                        }
                        free (real_arg_path);
                    }
                    free (real_input_path);
                } else
                    ERROR ("can not get absolute path of '%s' (unexpectedly)",
                           input_path);
            }
#endif
            if (!application->force && most_likely_existing_cnf_file (arg))
                ERROR ("not writing proof to '%s' file (use '-f')", arg);
            if (!kissat_file_writable (arg))
                ERROR ("can not write proof to '%s'", arg);
            application->proof_path = arg;
#else
            ERROR ("two file arguments '%s' and '%s' without proof support "
                   "(try '-h')",
                   application->input_path, arg);
#endif
        } else {
            if (!kissat_file_readable (arg))
                ERROR ("can not read '%s'", arg);
            application->input_path = arg;
        }
    }
#ifndef KISSAT_HAS_COMPRESSION
    if (!application->force && application->input_path &&
        kissat_looks_like_a_compressed_file (application->input_path))
        ERROR ("reading apparently compressed '%s' not supported "
               "(use '-f' to force reading without decompression)",
               application->input_path);
#endif
#if !defined(QUIET) && !defined(NOPTIONS)
    if (kissat_get_option (solver, "quiet")) {
        if (kissat_get_option (solver, "statistics"))
            ERROR ("can not use '--quiet' ('-q') with '--statistics' ('-s')");
        if (kissat_get_option (solver, "verbose"))
            ERROR ("can not use '--quiet' ('-q') with '--verbose' ('-v')");
    }
#endif
    return true;
}

static bool parse_input (application *application) {
#ifndef QUIET
    double entered = kissat_process_time ();
#endif
    kissat *solver = application->solver;
    uint64_t lineno;
    file file;
    //! 这里是获取输入文件的路径
    const char *path = application->input_path;
    if (!path)
        kissat_read_already_open_file (&file, stdin, "<stdin>");
    else if (!kissat_open_to_read_file (&file, path))
        ERROR ("failed to open '%s' for reading", path);
    kissat_section (solver, "parsing");
    kissat_message (solver, "opened and reading %sDIMACS file:",
                    file.compressed ? "compressed " : "");
    kissat_line (solver);
    kissat_message (solver, "  %s", file.path);
    kissat_line (solver);
    const char *error = kissat_parse_dimacs (solver, application->strict, &file,
                                             &lineno, &application->max_var);
    kissat_close_file (&file);
    if (error)
        ERROR ("%s:%" PRIu64 ": parse error: %s", file.path, lineno, error);
#ifndef QUIET
    kissat_message (solver, "closing input after reading %s",
                    FORMAT_BYTES (file.bytes));
    if (file.compressed) {
        assert (path);
        size_t bytes = kissat_file_size (path);
        kissat_message (solver, "inflated input file of size %s by %.2f",
                        FORMAT_BYTES (bytes),
                        kissat_average (file.bytes, bytes));
    }
    kissat_message (solver, "finished parsing after %.2f seconds",
                    kissat_process_time () - entered);
#endif
    return true;
}

#ifndef NPROOFS

static bool write_proof (application *application) {
    const char *path = application->proof_path;
    if (!path)
        return true;
    file *file = &application->proof_file;
    bool binary = true;
    if (!strcmp (path, "-")) {
        binary = false;
        kissat_write_already_open_file (file, stdout, "<stdout>");
    } else if (!kissat_open_to_write_file (file, path))
        ERROR ("failed to open and write proof to '%s'", path);
    else if (application->binary < 0)
        binary = false;
    kissat_init_proof (application->solver, file, binary);
#ifndef QUIET
    kissat *solver = application->solver;
    kissat_section (solver, "proving");
    kissat_message (solver, "%swriting proof to %sDRAT file:",
                    file->close ? "opened and " : "",
                    file->compressed ? "compressed " : "");
    kissat_line (solver);
    kissat_message (solver, "  %s", file->path);
#endif
    return true;
}

static void close_proof (application *application) {
    const char *path = application->proof_path;
    if (!path)
        return;
    kissat_release_proof (application->solver);
    kissat_close_file (&application->proof_file);
}

#endif

#ifndef QUIET

#ifndef NOPTIONS
static void print_option (kissat *solver, int value, const opt *o) {
    char buffer[96];
    const bool b = (o->low == 0 && o->high == 1);
    const char *val_str = FORMAT_VALUE (b, value);
    const char *def_str = FORMAT_VALUE (b, o->value);
    sprintf (buffer, "%s=%s", o->name, val_str);
    kissat_message (solver, "--%-30s (%s default '%s')", buffer,
                    (value == o->value ? "same as" : "different from"),
                    def_str);
}
#endif

#ifndef NOPTIONS
static void print_options (kissat *solver) {
    const int verbosity = kissat_verbosity (solver);
    if (verbosity < 0)
        return;
    size_t printed = 0;
    for (all_options (o)) {
        const int value = *kissat_options_ref (&solver->options, o);
        if (o->value != value || verbosity > 0) {
            if (!printed++)
                kissat_section (solver, "options");

            print_option (solver, value, o);
        }
    }
}
#endif

static void print_limits (application *application) {
    kissat *solver = application->solver;
    const int verbosity = kissat_verbosity (solver);
    if (verbosity < 1 && application->conflicts < 0 &&
        application->decisions < 0)
        return;

    kissat_section (solver, "limits");
    if (!application->time && application->conflicts < 0 &&
        application->decisions < 0)
        kissat_message (solver, "no time, conflict nor decision limit set");
    else {
        if (application->time)
            kissat_message (solver, "time limit set to %d seconds",
                            application->time);
        else if (verbosity > 0)
            kissat_message (solver, "no time limit");

        if (application->conflicts >= 0)
            kissat_message (solver, "conflict limit set to %d conflicts",
                            application->conflicts);
        else if (verbosity > 0)
            kissat_message (solver, "no conflict limit");

        if (application->decisions >= 0)
            kissat_message (solver, "decision limit set to %d decisions",
                            application->decisions);
        else if (verbosity > 0)
            kissat_message (solver, "no decision limit");
    }
}

#endif

static void get_csv_filename_with_worker_id (char *buffer, size_t size,
                                             const char *base_path,
                                             int worker_id) {
    // 如果没有 worker_id (或者为0，且你希望单进程时也用 _0)，
    // 或者你希望单进程时不用后缀，可以加判断。
    // 这里采用统一逻辑：如果是并行环境，worker_id 会是 0, 1, 2...
    // 假设 base_path 是 ".../neurobranch_simp_results.csv"
    // 我们想改成 ".../neurobranch_simp_results_0.csv"

    // 简单做法：去掉 .csv 后缀，拼上 _id.csv
    // 1. 找到最后一个点
    const char *dot = strrchr (base_path, '.');
    if (!dot) {
        // 没有后缀，直接追加
        snprintf (buffer, size, "%s_%d.csv", base_path, worker_id);
    } else {
        // 有后缀，插在后缀前
        int len_prefix = dot - base_path;
        // 保护性拷贝
        if (len_prefix >= size)
            len_prefix = size - 1;

        char prefix[512];
        strncpy (prefix, base_path, len_prefix);
        prefix[len_prefix] = '\0';

        snprintf (buffer, size, "%s_%d.csv", prefix, worker_id);
    }
}

void log_solver_statistics (const char *cnf_filename, int res, double time_ms,
                            double time_ms1, double time_ms2,
                            unsigned long long decisions,
                            unsigned long long conflicts, int mode,
                            int worker_id) {
    const char *base_csv_filename = NULL;
    char final_csv_filename[1024];

    // 1. 确定基础路径
    if (mode == 1) {
        base_csv_filename =
            "/home/richard/project/kissat/results/neurobranch_results.csv";
    } else if (mode == 2) {
        base_csv_filename =
            "/home/richard/project/kissat/results/neurobranch_simp_results.csv";
    } else {
        base_csv_filename =
            "/home/richard/project/kissat/results/kissat_results.csv";
    }

    // 2. 如果处于并行模式（即有 NEUROBRANCH_WORKER_ID），则修改文件名
    if (worker_id != -1) {
        get_csv_filename_with_worker_id (final_csv_filename,
                                         sizeof (final_csv_filename),
                                         base_csv_filename, worker_id);
    } else {
        // 单进程模式，直接用原路径
        strncpy (final_csv_filename, base_csv_filename,
                 sizeof (final_csv_filename));
    }

    // 3. 打开文件
    FILE *file = fopen (final_csv_filename, "a");
    if (file == NULL) {
        fprintf (stderr, "Error opening results CSV file: %s\n",
                 final_csv_filename);
        perror ("Reason");
        return;
    }

    char result[10];
    if (res == 20)
        strcpy (result, "UNSAT");
    else if (res == 10)
        strcpy (result, "SAT");
    else
        strcpy (result, "UNKNOWN");

    fprintf (file, "%s,%s,%.2f,%.2f,%.2f,%llu,%llu\n", cnf_filename, result,
             time_ms, time_ms1, time_ms2, decisions, conflicts);
    fclose (file);
}

void get_filename (const char *path, char *result) {
    unsigned start = 0, end = 0;
    unsigned q = 0;
    for (q = 0; q < strlen (path); q++) {
        if (path[q] == '/')
            start = q + 1;
        else if (path[q] == '.') {
            end = q;
            break;
        }
    }
    for (q = 0; q < end - start; q++) {
        result[q] = path[start + q];
    }
}

void get_mode (kissat *solver) {
    const char *filename = "/home/richard/project/kissat/config/config.json";
    FILE *file = fopen (filename, "r");

    if (!file) {
        fprintf (stderr, "错误: 无法打开配置文件 %s\n", filename);
        return;
    }

    // 读取整个文件内容
    // printf ("1\n");
    fseek (file, 0, SEEK_END);
    long file_size = ftell (file);
    fseek (file, 0, SEEK_SET);
    // printf ("2\n");

    char *content = (char *) malloc (file_size + 1);
    if (!content) {
        fprintf (stderr, "错误: 内存分配失败\n");
        fclose (file);
        return;
    }
    // printf ("3\n");

    fread (content, 1, file_size, file);
    content[file_size] = '\0';
    fclose (file);
    // printf ("4\n");

    // 读取train_mode
    char *mode_pos = strstr (content, "\"train_mode\"");
    char *colon_pos = strchr (mode_pos, ':');
    char *value_start = colon_pos + 1;
    while (*value_start && isspace (*value_start)) {
        value_start++;
    }
    char *end_ptr;
    long mode_value = strtol (value_start, &end_ptr, 10);
    solver->train_mode = (int) mode_value;
    // printf ("5\n");

    // 读取simple_mode
    char *_mode_pos = strstr (content, "\"simple_mode\"");
    char *_colon_pos = strchr (_mode_pos, ':');
    char *_value_start = _colon_pos + 1;
    while (*_value_start && isspace (*_value_start)) {
        _value_start++;
    }
    char *_end_ptr;
    long _mode_value = strtol (_value_start, &_end_ptr, 10);
    solver->simple_mode = (int) _mode_value;
    // printf ("6\n");

    // 读取use_neurobranch
    char *_mode_pos_ = strstr (content, "\"use_neurobranch\"");
    char *_colon_pos_ = strchr (_mode_pos_, ':');
    char *_value_start_ = _colon_pos_ + 1;
    while (*_value_start_ && isspace (*_value_start_)) {
        _value_start_++;
    }
    char *_end_ptr_;
    long _mode_value_ = strtol (_value_start_, &_end_ptr_, 10);
    solver->use_neurobranch = (int) _mode_value_;
    // printf ("7\n");

    // 读取use_neurobranch
    // char *_mode_pos__ = strstr (content, "\"reinforce_mode\"");
    // char *_colon_pos__ = strchr (_mode_pos__, ':');
    // char *_value_start__ = _colon_pos__ + 1;
    // while (*_value_start__ && isspace (*_value_start__)) {
    //     _value_start_++;
    // }
    // char *_end_ptr__;
    // long _mode_value__ = strtol (_value_start__, &_end_ptr__, 10);
    // solver->reinforce_mode = (int) _mode_value__;

    free (content);
}

static int run_application (kissat *solver, int argc, char **argv,
                            bool *cancel_alarm_ptr) {
    *cancel_alarm_ptr = false;
    if (argc == 2)
        if (parsed_one_option_and_return_zero_exit_code (argv[1]))
            return 0;
    application application;
    //! 初始化worker_id
    init_app (&application, solver);
    bool ok = parse_options (&application, argc, argv);
    if (application.time > 0)
        *cancel_alarm_ptr = true;
    if (!ok)
        return 1;
#ifndef QUIET
    kissat_section (solver, "banner");
    if (!GET_OPTION (quiet)) {
        kissat_banner ("c ", SOLVER_NAME);
        fflush (stdout);
    }
#endif
#ifndef NPROOFS
    if (!write_proof (&application))
        return 1;
#endif
    if (!parse_input (&application)) {
#ifndef NPROOFS
        close_proof (&application);
#endif
        return 1;
    }
#ifndef QUIET
#ifndef NOPTIONS
    print_options (solver);
#endif
    print_limits (&application);
    kissat_section (solver, "solving");
#endif
    //! 初始化
    // printf ("初始化1：\n");
    int clause_count = 0;
    // printf ("初始化2：\n");
    for (all_clauses (C)) {
        C->resident = true;
    }
    // printf ("初始化3：\n");
    get_mode (solver);
    // printf ("初始化4：\n");
    solver->decided = 0;
    // printf ("初始化5：\n");
    get_filename (application.input_path, solver->input_path);
    int mode = 0;
    if (!solver->use_neurobranch) {
        //! 如果不使用neurobranch就不建共享内存
    } else if (solver->train_mode) {
        //! 如果处于训练模式，初始化训练数据和标签的存储路径
        srand (time (NULL));
        solver->rand_value = rand () % 10;
        // if (solver->reinforce_mode) {
        //     //! 强化学习offline训练模式
        //     //! 分别记录state，action，reward这三组数据，便于后面的训练
        //     snprintf (solver->data_path, sizeof (solver->data_path),
        //               "/home/richard/project/neurobranch_train_data/"
        //               "neurobranch_reinforce/state/%s/",
        //               solver->input_path);
        //     mode_t mode = 0755;
        //     mkdir (solver->data_path, mode);
        //     snprintf (solver->label_path, sizeof (solver->label_path),
        //               "/home/richard/project/neurobranch_train_data/"
        //               "neurobranch_reinforce/action/%s/",
        //               solver->input_path);
        //     mkdir (solver->label_path, mode);
        //     snprintf (solver->label_path, sizeof (solver->label_path),
        //               "/home/richard/project/neurobranch_train_data/"
        //               "neurobranch_reinforce/reward/%s/",
        //               solver->input_path);
        //     mkdir (solver->label_path, mode);
        // } else
        if (solver->simple_mode) {
            snprintf (solver->data_path, sizeof (solver->data_path),
                      "/home/richard/project/neurobranch_train_data/"
                      "neurobranch_simp/data/%s/",
                      solver->input_path);
            mode_t mode = 0755;
            mkdir (solver->data_path, mode);
            snprintf (solver->label_path, sizeof (solver->label_path),
                      "/home/richard/project/neurobranch_train_data/"
                      "neurobranch_simp/label/%s/",
                      solver->input_path);
            mkdir (solver->label_path, mode);
        } else {
            snprintf (solver->data_path, sizeof (solver->data_path),
                      "/home/richard/project/neurobranch_train_data/"
                      "neurobranch/data/%s/",
                      solver->input_path);
            mode_t mode = 0755;
            mkdir (solver->data_path, mode);
            snprintf (solver->label_path, sizeof (solver->label_path),
                      "/home/richard/project/neurobranch_train_data/"
                      "neurobranch/label/%s/",
                      solver->input_path);
            mkdir (solver->label_path, mode);
        }
    } else if (solver->simple_mode == 0) {
        //! 如果使用原始版本neurobranch，并且是apply模式，构建第一种共享内存
        mode = 1;
        // printf ("开始创建共享内存\n");
        system ("touch /tmp/neurobranch");
        solver->key = ftok ("/tmp/neurobranch", 83);
        solver->shmid =
            shmget (solver->key, sizeof (struct shared_data), 0666 | IPC_CREAT);
        solver->data = (struct shared_data *) shmat (solver->shmid, NULL, 0);
        solver->semid = semget (solver->key, 1, 0666 | IPC_CREAT);
        // printf ("共享内存创建成功\n");
    } else if (solver->simple_mode == 1) {
        //! 如果使用简化版本neurobranch，并且是apply模式，构建第二种共享内存
        mode = 2;

        // //! 这里要进行并行运算，注意共享内存文件的命名

        // 构造唯一路径
        char shm_path[256];
        solver->worker_id = application.worker_id;
        sprintf (shm_path, "/tmp/neurobranch_simp_%d", solver->worker_id);

        // 创建文件以供 ftok 使用
        char cmd[256];
        sprintf (cmd, "touch %s", shm_path);
        system (cmd);
        printf ("%s\n", cmd);

        // system ("touch /tmp/neurobranch_simp");

        solver->key = ftok (shm_path, 84);
        // solver->key = ftok ("/tmp/neurobranch_simp", 84);
        if (solver->key == (key_t) -1) {
            perror ("ftok(/tmp/neurobranch_simp, 84) failed");
            exit (1);
        }

        solver->shmid = shmget (solver->key, sizeof (struct shared_data_simp),
                                IPC_CREAT | 0666);
        if (solver->shmid == -1) {
            perror ("shmget(shared_data_simp) failed");
            exit (1);
        }

        solver->data_simp = shmat (solver->shmid, NULL, 0);
        if (solver->data_simp == (void *) -1) {
            perror ("shmat(shared_data_simp) failed");
            fprintf (stderr, "errno = %d (%s)\n", errno, strerror (errno));
            exit (1);
        }

        printf ("data_simp pointer = %p\n", (void *) solver->data_simp);
        fflush (stdout);

        memset (solver->data_simp, 0, sizeof (struct shared_data_simp));

        solver->semid = semget (solver->key, 1, 0666 | IPC_CREAT);
        if (solver->semid == -1) {
            perror ("semget failed");
            exit (1);
        }
    }
    //! 计时，写入time.csv
    // struct timespec start, end;
    clock_gettime (CLOCK_MONOTONIC, &solver->start);
    solver->timeout = false;
    // printf ("\nc Start Solving……\n");
    int res = kissat_solve (solver);
    clock_gettime (CLOCK_MONOTONIC, &solver->end);
    long time_ns = (solver->end.tv_sec - solver->start.tv_sec) * 1000000000L +
                   (solver->end.tv_nsec - solver->start.tv_nsec);
    long time_ns1 = solver->decision_time_ns;
    double time_ms = time_ns / 1000000.0;
    double time_ms1 = time_ns1 / 1000000.0;
    double time_ms2 = time_ms - time_ms1;
    if (solver->use_neurobranch) {
        if (!solver->train_mode) {
            if (!solver->simple_mode)
                shmdt (solver->data);
            else
                shmdt (solver->data_simp);
            shmctl (solver->shmid, IPC_RMID, NULL);
        }
    }

    // FILE *fp = fopen ("/home/richard/project/kissat/time.csv", "a+");
    // if (solver->timeout) {
    //   fprintf (fp, "timeout\n");
    // } else {
    //   fprintf (fp, "%.3e\n", time_ms);
    // }
    // fclose (fp);

    // if (solver->timeout == false) {
    //   FILE *fp1 = fopen ("/home/richard/project/kissat/in_limit.csv",
    //   "a+"); fprintf (fp1, "%s\n", application.input_path); fclose (fp1);
    // } else {
    //   FILE *fp2 =
    //       fopen ("/home/richard/project/kissat/beyond_limit.csv", "a+");
    //   fprintf (fp2, "%s\n", application.input_path);
    //   fclose (fp2);
    // }

    log_solver_statistics (application.input_path, res, time_ms, time_ms1,
                           time_ms2, solver->statistics.decisions,
                           solver->statistics.conflicts, mode,
                           solver->worker_id);

#ifndef NPROOFS
    close_proof (&application);
#endif
    kissat_section (solver, "result");
    if (application.output_path && !strcmp (application.output_path, "-")) {
        const char *status;
        if (res == 20)
            status = "UNSATISFIABLE";
        else if (res == 10)
            status = "SATISFIABLE";
        else
            status = "UNKNOWN";
        kissat_message (solver,
                        "not printing 's %s' status line "
                        "when writing DIMACS to '<stdout>'",
                        status);
    } else {
        if (res == 20) {
            printf ("s UNSATISFIABLE\n");
            fflush (stdout);
        } else if (res == 10) {
#ifndef NDEBUG
            if (GET_OPTION (check))
                kissat_check_satisfying_assignment (solver);
#endif
            printf ("s SATISFIABLE\n");
            fflush (stdout);
            // if (application.witness)
            //   kissat_print_witness (solver, application.max_var,
            //                         application.partial);
        } else {
            printf ("s UNKNOWN\n");
            fflush (stdout);
        }
    }
    if (application.output_path) {
        // TODO want to use 'struct file' from 'file.h'?
        const char *path = application.output_path;
        bool close_file;
        FILE *file;
        if (!strcmp (path, "-")) {
            close_file = false;
            file = stdout;
        } else {
            close_file = true;
            file = fopen (path, "w");
            if (!file)
                ERROR ("could not write DIMACS file '%s'", path);
        }
        kissat_write_dimacs (solver, file);
        if (close_file)
            fclose (file);
    }
#ifndef QUIET
    kissat_print_statistics (solver);
#endif
#ifndef QUIET
    kissat_section (solver, "shutting down");
    kissat_message (solver, "exit %d", res);
#endif
    return res;
}

int kissat_application (kissat *solver, int argc, char **argv) {
    bool cancel_alarm;
    int res = run_application (solver, argc, argv, &cancel_alarm);
    if (cancel_alarm)
        alarm (0);
    return res;
}
