#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "quickjs.h"
#include "chrono_bundle.h"

/* Only an NLP request creates the runtime or reads the bundled parser source. */
static pthread_mutex_t parser_lock = PTHREAD_MUTEX_INITIALIZER;
static JSRuntime *runtime;
static JSContext *context;
static JSValue parse_function;
static int initialization_count;
static double deadline;

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static int interrupted(JSRuntime *rt, void *opaque) {
    (void)rt;
    (void)opaque;
    return monotonic_seconds() > deadline;
}

static void clear_exception(void) {
    JSValue exception = JS_GetException(context);
    JS_FreeValue(context, exception);
}

static int initialize(void) {
    if (context) return 1;
    runtime = JS_NewRuntime();
    if (!runtime) return 0;
    JS_SetMemoryLimit(runtime, 24 * 1024 * 1024);
    JS_SetMaxStackSize(runtime, 512 * 1024);
    JS_SetInterruptHandler(runtime, interrupted, NULL);
    deadline = monotonic_seconds() + 2.0;
    context = JS_NewContext(runtime);
    if (!context) goto failed;
    JSValue result = JS_Eval(context, (const char *)logseq_chrono_bundle,
                             sizeof(logseq_chrono_bundle) - 1, "chrono-node.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        clear_exception();
        goto failed;
    }
    JS_FreeValue(context, result);
    JSValue global = JS_GetGlobalObject(context);
    parse_function = JS_GetPropertyStr(context, global, "logseqParseDate");
    JS_FreeValue(context, global);
    if (!JS_IsFunction(context, parse_function)) {
        JS_FreeValue(context, parse_function);
        goto failed;
    }
    initialization_count++;
    return 1;
failed:
    if (context) JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    context = NULL;
    runtime = NULL;
    return 0;
}

int logseq_nlp_initialization_count(void) {
    pthread_mutex_lock(&parser_lock);
    int count = initialization_count;
    pthread_mutex_unlock(&parser_lock);
    return count;
}

CAMLprim value logseq_nlp_init_count(value unit) {
    (void)unit;
    return Val_int(logseq_nlp_initialization_count());
}

CAMLprim value logseq_nlp_parse(value input, value reference_ms) {
    CAMLparam2(input, reference_ms);
    CAMLlocal2(answer, text);
    size_t length = caml_string_length(input);
    char *copy = malloc(length + 1);
    if (!copy) caml_raise_out_of_memory();
    memcpy(copy, String_val(input), length);
    copy[length] = 0;
    double reference = Double_val(reference_ms);
    char *output = NULL;
    int failed = 0;
    caml_enter_blocking_section();
    pthread_mutex_lock(&parser_lock);
    if (!initialize()) {
        failed = 1;
    } else {
        JS_UpdateStackTop(runtime);
        deadline = monotonic_seconds() + 0.2;
        JSValue arguments[2] = {JS_NewStringLen(context, copy, length), JS_NewFloat64(context, reference)};
        JSValue result = JS_Call(context, parse_function, JS_UNDEFINED, 2, arguments);
        JS_FreeValue(context, arguments[0]);
        JS_FreeValue(context, arguments[1]);
        if (JS_IsException(result)) {
            clear_exception();
            failed = 1;
        } else if (!JS_IsNull(result) && !JS_IsUndefined(result)) {
            const char *json = JS_ToCString(context, result);
            if (json) {
                output = strdup(json);
                JS_FreeCString(context, json);
                if (!output) failed = 1;
            } else {
                clear_exception();
                failed = 1;
            }
        }
        JS_FreeValue(context, result);
    }
    pthread_mutex_unlock(&parser_lock);
    caml_leave_blocking_section();
    free(copy);
    if (failed) {
        free(output);
        caml_failwith("Could not parse the natural-language date");
    }
    if (!output) CAMLreturn(Val_none);
    text = caml_copy_string(output);
    free(output);
    answer = caml_alloc_some(text);
    CAMLreturn(answer);
}
