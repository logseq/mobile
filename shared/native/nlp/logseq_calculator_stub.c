#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "quickjs.h"
#include "calculator_bundle.h"

/* Decimal calculations are independent from the date and syntax runtimes. */
static pthread_mutex_t calculator_lock = PTHREAD_MUTEX_INITIALIZER;
static JSRuntime *runtime;
static JSContext *context;
static JSValue calculate_function;
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
    JSValue result = JS_Eval(context, (const char *)logseq_calculator_bundle,
        sizeof(logseq_calculator_bundle) - 1, "calculator.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        clear_exception();
        goto failed;
    }
    JS_FreeValue(context, result);
    JSValue global = JS_GetGlobalObject(context);
    calculate_function = JS_GetPropertyStr(context, global, "logseqCalculatorLines");
    JS_FreeValue(context, global);
    if (!JS_IsFunction(context, calculate_function)) {
        JS_FreeValue(context, calculate_function);
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

/* Each block receives its own variable and formatting environment. */
char *logseq_calculator_evaluate(const char *request) {
    if (!request || strlen(request) > 1024 * 1024) return strdup("[]");
    char *output = NULL;
    pthread_mutex_lock(&calculator_lock);
    if (initialize()) {
        JS_UpdateStackTop(runtime);
        deadline = monotonic_seconds() + 0.2;
        JSValue argument = JS_NewString(context, request);
        JSValue result = JS_Call(context, calculate_function, JS_UNDEFINED, 1, &argument);
        JS_FreeValue(context, argument);
        if (JS_IsException(result)) {
            clear_exception();
        } else {
            const char *json = JS_ToCString(context, result);
            if (json) {
                output = strdup(json);
                JS_FreeCString(context, json);
            } else clear_exception();
        }
        JS_FreeValue(context, result);
    }
    pthread_mutex_unlock(&calculator_lock);
    return output ? output : strdup("[]");
}

CAMLprim value logseq_calculator_results(value request) {
    CAMLparam1(request);
    CAMLlocal1(answer);
    char *copy = strdup(String_val(request));
    caml_enter_blocking_section();
    char *json = logseq_calculator_evaluate(copy);
    caml_leave_blocking_section();
    free(copy);
    answer = caml_copy_string(json ? json : "[]");
    free(json);
    CAMLreturn(answer);
}

CAMLprim value logseq_calculator_init_count(value unit) {
    (void)unit;
    pthread_mutex_lock(&calculator_lock);
    int count = initialization_count;
    pthread_mutex_unlock(&calculator_lock);
    return Val_int(count);
}
