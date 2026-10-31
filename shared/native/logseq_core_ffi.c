#include "logseq_core_ffi.h"

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/mlvalues.h>
#include <caml/printexc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __ANDROID__
#include <android/log.h>
#define LOGSEQ_LOG(...) \
  __android_log_print(ANDROID_LOG_ERROR, "logseq", __VA_ARGS__)
#elif defined(__APPLE__)
#include <os/log.h>
#define LOGSEQ_LOG(...) \
  do { \
    char logseq_log_buf[2048]; \
    snprintf(logseq_log_buf, sizeof logseq_log_buf, __VA_ARGS__); \
    os_log_error(OS_LOG_DEFAULT, "%{public}s", logseq_log_buf); \
  } while (0)
#else
#define LOGSEQ_LOG(...) \
  do { \
    fprintf(stderr, "logseq: "); \
    fprintf(stderr, __VA_ARGS__); \
    fputc('\n', stderr); \
  } while (0)
#endif

static pthread_once_t logseq_runtime_once = PTHREAD_ONCE_INIT;
static pthread_t logseq_runtime_thread;
static _Thread_local char *logseq_response = NULL;

extern char *logseq_syntax_highlight(const char *request);

char *logseq_highlight_code(const char *request_json) {
  return logseq_syntax_highlight(request_json);
}

static void start_ocaml_runtime(void) {
  static char program_name[] = "logseq_mobile";
  char *argv[] = {program_name, NULL};
  caml_startup(argv);
  logseq_runtime_thread = pthread_self();
  caml_release_runtime_system();
}

static void ensure_ocaml_runtime(void) {
  pthread_once(&logseq_runtime_once, start_ocaml_runtime);
}

void logseq_initialize(void) {
  ensure_ocaml_runtime();
}

static const char *replace_response(const char *value) {
  size_t length = strlen(value);
  char *copy = malloc(length + 1);
  if (copy == NULL) {
    return
      "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
      "\"allocation_failure\",\"message\":\"Could not allocate the RPC response\"}}";
  }
  memcpy(copy, value, length + 1);
  free(logseq_response);
  logseq_response = copy;
  return logseq_response;
}

static const char *call_ocaml(const char *request_json) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(request, result);
  const value *callback = caml_named_value("logseq_mobile_call");
  if (callback == NULL) {
    response = replace_response(
      "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
      "\"missing_callback\",\"message\":\"OCaml RPC callback is not registered\"}}");
  } else {
    request = caml_copy_string(request_json == NULL ? "" : request_json);
    result = caml_callback_exn(*callback, request);
    if (Is_exception_result(result)) {
      response = replace_response(
        "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
        "\"ocaml_exception\",\"message\":\"The OCaml core raised an exception\"}}");
    } else {
      response = replace_response(String_val(result));
    }
  }
  CAMLreturnT(const char *, response);
}

const char *logseq_call(const char *request_json) {
  const char *response;
  int needs_unregister = 0;

  ensure_ocaml_runtime();

  if (!pthread_equal(pthread_self(), logseq_runtime_thread)) {
    if (!caml_c_thread_register()) {
      response = replace_response(
        "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
        "\"ocaml_thread_registration_failed\",\"message\":\"Could not register the calling thread with the OCaml runtime\"}}");
      return response;
    }
    needs_unregister = 1;
  }
  LOGSEQ_LOG("rpc enter");
  caml_acquire_runtime_system();
  LOGSEQ_LOG("rpc acquired");

  response = call_ocaml(request_json);

  LOGSEQ_LOG("rpc done");
  caml_release_runtime_system();
  if (needs_unregister) {
    caml_c_thread_unregister();
  }
  return response;
}

static int acquire_ocaml_runtime(void) {
  ensure_ocaml_runtime();
  if (pthread_equal(pthread_self(), logseq_runtime_thread)) {
    caml_acquire_runtime_system();
    return 0;
  }
  if (!caml_c_thread_register()) {
    return -1;
  }
  caml_acquire_runtime_system();
  return 1;
}

static void release_ocaml_runtime(int registration) {
  caml_release_runtime_system();
  if (registration == 1) {
    caml_c_thread_unregister();
  }
}

static const char *missing_lui_callback(void) {
  return replace_response("");
}

/* The lui_* entry points return raw patch strings, so an OCaml exception
   cannot ride back in-band — the host would try to parse it as a patch.
   An empty patch is silently skipped by the drain, which is exactly the
   wedge signature we hit when an exception wedged the pipeline: log the
   exception via the platform logger (stderr does not reach logcat on
   Android) so the failure is diagnosable instead of invisible. */
static const char *lui_no_callback(const char *name) {
  LOGSEQ_LOG("OCaml LUI callback is not registered: %s", name);
  return missing_lui_callback();
}

static const char *lui_bad_argument(const char *name) {
  LOGSEQ_LOG("NULL argument passed to %s", name);
  return missing_lui_callback();
}

static const char *lui_exception(const char *name, value result) {
  char *message = caml_format_exception(Extract_exception(result));
  LOGSEQ_LOG("OCaml exception in %s: %s",
                  name, message == NULL ? "(unprintable)" : message);
  caml_stat_free(message);
  return missing_lui_callback();
}

static const char *lui_thread_registration_failed(void) {
  LOGSEQ_LOG("could not register calling thread with the OCaml runtime");
  return missing_lui_callback();
}

static const char *call_lui0(const char *name) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value(name);
  if (callback == NULL) {
    response = lui_no_callback(name);
  } else {
    result = caml_callback_exn(*callback, Val_unit);
    response = Is_exception_result(result)
      ? lui_exception(name, result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_int(const char *name, int64_t number) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value(name);
  if (callback == NULL) {
    response = lui_no_callback(name);
  } else {
    result = caml_callback_exn(*callback, Val_long(number));
    response = Is_exception_result(result)
      ? lui_exception(name, result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_initialize(
    int32_t platform_code,
    int32_t host_code,
    int32_t authentication_code) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value("logseq_lui_init");
  if (callback == NULL) {
    response = lui_no_callback("logseq_lui_init");
  } else {
    value arguments[3] = {
      Val_long(platform_code),
      Val_long(host_code),
      Val_long(authentication_code)
    };
    result = caml_callbackN_exn(*callback, 3, arguments);
    response = Is_exception_result(result)
      ? lui_exception("logseq_lui_init", result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_text(int64_t node, const char *text) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(text_value, result);
  const value *callback = caml_named_value("logseq_lui_text_changed");
  if (callback == NULL) {
    response = lui_no_callback("logseq_lui_text_changed");
  } else if (text == NULL) {
    response = lui_bad_argument("logseq_lui_text_changed");
  } else {
    text_value = caml_copy_string(text);
    result = caml_callback2_exn(*callback, Val_long(node), text_value);
    response = Is_exception_result(result)
      ? lui_exception("logseq_lui_text_changed", result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_string(const char *name, const char *text) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(text_value, result);
  const value *callback = caml_named_value(name);
  if (callback == NULL) {
    response = lui_no_callback(name);
  } else if (text == NULL) {
    response = lui_bad_argument(name);
  } else {
    text_value = caml_copy_string(text);
    result = caml_callback_exn(*callback, text_value);
    response = Is_exception_result(result)
      ? lui_exception(name, result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_two_strings(const char *name, const char *left,
                                        const char *right) {
  const char *response;
  CAMLparam0();
  CAMLlocal3(left_value, right_value, result);
  const value *callback = caml_named_value(name);
  if (callback == NULL) {
    response = lui_no_callback(name);
  } else if (left == NULL || right == NULL) {
    response = lui_bad_argument(name);
  } else {
    left_value = caml_copy_string(left);
    right_value = caml_copy_string(right);
    result = caml_callback2_exn(*callback, left_value, right_value);
    response = Is_exception_result(result)
      ? lui_exception(name, result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_bool(int64_t node, int32_t checked) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value("logseq_lui_toggle_changed");
  if (callback == NULL) {
    response = lui_no_callback("logseq_lui_toggle_changed");
  } else {
    result = caml_callback2_exn(*callback, Val_long(node), Val_bool(checked != 0));
    response = Is_exception_result(result)
      ? lui_exception("logseq_lui_toggle_changed", result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_double(int64_t node, double number) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(number_value, result);
  const value *callback = caml_named_value("logseq_lui_value_changed");
  if (callback == NULL) {
    response = lui_no_callback("logseq_lui_value_changed");
  } else {
    number_value = caml_copy_double(number);
    result = caml_callback2_exn(*callback, Val_long(node), number_value);
    response = Is_exception_result(result)
      ? lui_exception("logseq_lui_value_changed", result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_resolve_effect(int64_t effect_id, int32_t succeeded,
                                           const char *message) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(message_value, result);
  const value *callback = caml_named_value("logseq_lui_resolve_effect");
  if (callback == NULL) {
    response = lui_no_callback("logseq_lui_resolve_effect");
  } else {
    message_value = caml_copy_string(message == NULL ? "" : message);
    result = caml_callback3_exn(
      *callback,
      Val_long(effect_id),
      Val_bool(succeeded != 0),
      message_value);
    response = Is_exception_result(result)
      ? lui_exception("logseq_lui_resolve_effect", result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_extension_event(
    int64_t node, const char *identifier, const char *name, const char *text,
    int64_t number) {
  const char *response;
  CAMLparam0();
  CAMLlocal4(identifier_value, name_value, text_value, result);
  value arguments[5];
  const value *callback = caml_named_value("logseq_lui_extension_event");
  if (callback == NULL) {
    response = lui_no_callback("logseq_lui_extension_event");
  } else if (identifier == NULL || name == NULL || text == NULL) {
    response = lui_bad_argument("logseq_lui_extension_event");
  } else {
    identifier_value = caml_copy_string(identifier);
    name_value = caml_copy_string(name);
    text_value = caml_copy_string(text);
    arguments[0] = Val_long(node);
    arguments[1] = identifier_value;
    arguments[2] = name_value;
    arguments[3] = text_value;
    arguments[4] = Val_long(number);
    result = caml_callbackN_exn(*callback, 5, arguments);
    response = Is_exception_result(result)
      ? lui_exception("logseq_lui_extension_event", result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_node_text(const char *name, int64_t node,
                                      const char *text) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(text_value, result);
  const value *callback = caml_named_value(name);
  if (callback == NULL) {
    response = lui_no_callback(name);
  } else if (text == NULL) {
    response = lui_bad_argument(name);
  } else {
    text_value = caml_copy_string(text);
    result = caml_callback2_exn(*callback, Val_long(node), text_value);
    response = Is_exception_result(result)
      ? lui_exception(name, result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_visible_range(int64_t node, int64_t first,
                                          int64_t last) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value("logseq_lui_visible_range");
  if (callback == NULL) {
    response = lui_no_callback("logseq_lui_visible_range");
  } else {
    result = caml_callback3_exn(
      *callback,
      Val_long(node),
      Val_long(first),
      Val_long(last));
    response = Is_exception_result(result)
      ? lui_exception("logseq_lui_visible_range", result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_scroll_completed(int64_t node, int64_t token,
                                             const char *outcome) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(outcome_value, result);
  const value *callback = caml_named_value("logseq_lui_scroll_completed");
  if (callback == NULL) {
    response = lui_no_callback("logseq_lui_scroll_completed");
  } else if (outcome == NULL) {
    response = lui_bad_argument("logseq_lui_scroll_completed");
  } else {
    outcome_value = caml_copy_string(outcome);
    result = caml_callback3_exn(
      *callback,
      Val_long(node),
      Val_long(token),
      outcome_value);
    response = Is_exception_result(result)
      ? lui_exception("logseq_lui_scroll_completed", result)
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

#define LUI_RUNTIME_CALL(entry_name, expression) \
  LOGSEQ_LOG("lui %s enter", entry_name); \
  int registration = acquire_ocaml_runtime(); \
  if (registration < 0) { return lui_thread_registration_failed(); } \
  LOGSEQ_LOG("lui %s acquired", entry_name); \
  const char *response = (expression); \
  LOGSEQ_LOG("lui %s done", entry_name); \
  release_ocaml_runtime(registration); \
  return response

const char *logseq_lui_initialize(
    int32_t platform_code,
    int32_t host_code,
    int32_t authentication_code) {
  LUI_RUNTIME_CALL("initialize", call_lui_initialize(
      platform_code,
      host_code,
      authentication_code));
}

const char *logseq_lui_appear(int64_t node) {
  LUI_RUNTIME_CALL("appear", call_lui_int("logseq_lui_appear", node));
}

const char *logseq_lui_press(int64_t node) {
  LUI_RUNTIME_CALL("press", call_lui_int("logseq_lui_press", node));
}

const char *logseq_lui_long_press(int64_t node) {
  LUI_RUNTIME_CALL("long_press", call_lui_int("logseq_lui_long_press", node));
}

const char *logseq_lui_text_changed(int64_t node, const char *text) {
  LUI_RUNTIME_CALL("text_changed", call_lui_text(node, text));
}

const char *logseq_lui_submit(int64_t node) {
  LUI_RUNTIME_CALL("submit", call_lui_int("logseq_lui_submit", node));
}

const char *logseq_lui_toggle_changed(int64_t node, int32_t checked) {
  LUI_RUNTIME_CALL("toggle_changed", call_lui_bool(node, checked));
}

const char *logseq_lui_change(int64_t node) {
  LUI_RUNTIME_CALL("change", call_lui_int("logseq_lui_change", node));
}

const char *logseq_lui_value_changed(int64_t node, double value) {
  LUI_RUNTIME_CALL("value_changed", call_lui_double(node, value));
}

const char *logseq_lui_dismiss(int64_t node) {
  LUI_RUNTIME_CALL("dismiss", call_lui_int("logseq_lui_dismiss", node));
}

const char *logseq_lui_double_press(int64_t node) {
  LUI_RUNTIME_CALL("double_press", call_lui_int("logseq_lui_double_press", node));
}

const char *logseq_lui_extension_event(
    int64_t node, const char *identifier, const char *name, const char *text,
    int64_t value) {
  LUI_RUNTIME_CALL(
      "extension_event",
      call_lui_extension_event(node, identifier, name, text, value));
}

const char *logseq_lui_picked(int64_t node, const char *payload) {
  LUI_RUNTIME_CALL(
      "picked", call_lui_node_text("logseq_lui_picked", node, payload));
}

const char *logseq_lui_visible_range(int64_t node, int64_t first,
                                          int64_t last) {
  LUI_RUNTIME_CALL(
      "visible_range",
      call_lui_visible_range(node, first, last));
}

const char *logseq_lui_scroll_completed(int64_t node, int64_t token,
                                             const char *outcome) {
  LUI_RUNTIME_CALL(
      "scroll_completed",
      call_lui_scroll_completed(node, token, outcome));
}

int64_t logseq_lui_root_node(void) {
  int64_t node = -1;
  LOGSEQ_LOG("lui root_node enter");
  int registration = acquire_ocaml_runtime();
  if (registration < 0) return node;
  LOGSEQ_LOG("lui root_node acquired");
  const value *callback = caml_named_value("logseq_lui_root_node");
  if (callback == NULL) {
    LOGSEQ_LOG("OCaml LUI callback is not registered: "
                    "logseq_lui_root_node");
  } else {
    value result = caml_callback_exn(*callback, Val_unit);
    if (Is_exception_result(result)) {
      char *message = caml_format_exception(Extract_exception(result));
      LOGSEQ_LOG("OCaml exception in logseq_lui_root_node: %s",
                      message == NULL ? "(unprintable)" : message);
      caml_stat_free(message);
    } else {
      node = Long_val(result);
    }
  }
  release_ocaml_runtime(registration);
  return node;
}

const char *logseq_lui_dispose(void) {
  LUI_RUNTIME_CALL("dispose", call_lui0("logseq_lui_dispose"));
}

const char *logseq_lui_take_effect(void) {
  LUI_RUNTIME_CALL("take_effect", call_lui0("logseq_lui_take_effect"));
}

const char *logseq_lui_resolve_effect(int64_t effect_id, int32_t succeeded,
                                           const char *message) {
  LUI_RUNTIME_CALL("resolve_effect", call_lui_resolve_effect(effect_id, succeeded, message));
}

const char *logseq_lui_apply_snapshot(const char *response_json) {
  LUI_RUNTIME_CALL("apply_snapshot", call_lui_string("logseq_lui_apply_snapshot", response_json));
}

const char *logseq_lui_apply_host_update(const char *kind,
                                              const char *payload_json) {
  LUI_RUNTIME_CALL(
      "apply_host_update",
      call_lui_two_strings(
          "logseq_lui_apply_host_update", kind, payload_json));
}

void logseq_metric_log(const char *message) {
  LOGSEQ_LOG("%s", message);
}

static pthread_mutex_t logseq_progress_mutex = PTHREAD_MUTEX_INITIALIZER;
static logseq_graph_import_progress_callback logseq_progress_callback = NULL;

void logseq_set_graph_import_progress_callback(logseq_graph_import_progress_callback callback) {
  pthread_mutex_lock(&logseq_progress_mutex);
  logseq_progress_callback = callback;
  pthread_mutex_unlock(&logseq_progress_mutex);
}

void logseq_graph_import_progress(const char *graph_id, const char *phase, int64_t completed, int64_t total) {
  pthread_mutex_lock(&logseq_progress_mutex);
  logseq_graph_import_progress_callback callback = logseq_progress_callback;
  pthread_mutex_unlock(&logseq_progress_mutex);
  if (callback != NULL) callback(graph_id, phase, completed, total);
}
