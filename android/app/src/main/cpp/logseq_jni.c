// Thin JNI shim between com.logseq.app.NativeCore and the
// liblogseq_core.so C ABI (shared/native/logseq_core_ffi.h).
//
// Symbols are resolved with dlopen/dlsym at first use so this shim links
// without the prebuilt core being present at CMake configure time —
// gradle produces the core .so during task execution via
// scripts/build-android-native.sh, after externalNativeBuild configures.
//
// String payloads cross the boundary as jbyteArray holding UTF-8 bytes:
// the core reads and returns standard UTF-8, while NewStringUTF uses
// modified UTF-8 and would corrupt 4-byte sequences (e.g. emoji) and any
// embedded NULs the wire format escapes. Kotlin decodes with
// Charsets.UTF_8.

#include <dlfcn.h>
#include <jni.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

typedef const char *(*lui_fn_iii)(int, int, int);
typedef const char *(*lui_fn_none)(void);
typedef const char *(*lui_fn_l)(long long);
typedef const char *(*lui_fn_ls)(long long, const char *);
typedef const char *(*lui_fn_li)(long long, int);
typedef const char *(*lui_fn_ld)(long long, double);
typedef const char *(*lui_fn_lll)(long long, long long, long long);
typedef const char *(*lui_fn_llls)(long long, long long, long long, const char *);
typedef const char *(*lui_fn_lls)(long long, long long, const char *);
typedef const char *(*lui_fn_lsssl)(long long, const char *, const char *, const char *, long long);
typedef const char *(*lui_fn_lis)(long long, int, const char *);
typedef const char *(*lui_fn_s)(const char *);
typedef const char *(*lui_fn_ss)(const char *, const char *);
typedef const char *(*lui_fn_sssss)(const char *, const char *, const char *, const char *, const char *);

static void *core_handle = NULL;

static void *core_symbol(const char *name) {
  if (!core_handle) {
    core_handle = dlopen("liblogseq_core.so", RTLD_NOW | RTLD_GLOBAL);
    if (!core_handle) return NULL;
  }
  return dlsym(core_handle, name);
}

static char *jbytes_to_cstr(JNIEnv *env, jbyteArray bytes) {
  if (!bytes) return NULL;
  jsize length = (*env)->GetArrayLength(env, bytes);
  char *buffer = malloc((size_t)length + 1);
  if (!buffer) return NULL;
  (*env)->GetByteArrayRegion(env, bytes, 0, length, (jbyte *)buffer);
  buffer[length] = '\0';
  return buffer;
}

static jbyteArray cstr_to_jbytes(JNIEnv *env, const char *text) {
  if (!text) return NULL;
  jsize length = (jsize)strlen(text);
  jbyteArray bytes = (*env)->NewByteArray(env, length);
  if (!bytes) return NULL;
  (*env)->SetByteArrayRegion(env, bytes, 0, length, (const jbyte *)text);
  return bytes;
}

static JavaVM *progress_vm = NULL;
static jclass progress_receiver = NULL;
static jmethodID progress_method = NULL;

static void graph_import_progress(const char *graph_id, const char *phase,
                                  int64_t completed, int64_t total) {
  JNIEnv *env = NULL;
  int attached = 0;
  if (!progress_vm || !progress_receiver || !progress_method) return;
  if ((*progress_vm)->GetEnv(progress_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
    if ((*progress_vm)->AttachCurrentThread(progress_vm, &env, NULL) != JNI_OK) return;
    attached = 1;
  }
  jbyteArray graph = cstr_to_jbytes(env, graph_id);
  jbyteArray stage = cstr_to_jbytes(env, phase);
  if (graph && stage) {
    (*env)->CallStaticVoidMethod(env, progress_receiver, progress_method,
                                graph, stage, (jlong)completed, (jlong)total);
  }
  if (graph) (*env)->DeleteLocalRef(env, graph);
  if (stage) (*env)->DeleteLocalRef(env, stage);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
  }
  if (attached) (*progress_vm)->DetachCurrentThread(progress_vm);
}

JNIEXPORT jboolean JNICALL Java_com_logseq_app_NativeCore_installGraphImportProgressCallback(
    JNIEnv *env, jclass clazz, jclass receiver) {
  (void)clazz;
  typedef void (*callback_fn)(const char *, const char *, int64_t, int64_t);
  typedef void (*register_fn)(callback_fn);
  register_fn install = (register_fn)core_symbol("logseq_set_graph_import_progress_callback");
  if (!install) return JNI_FALSE;
  jmethodID method = (*env)->GetStaticMethodID(env, receiver, "receive", "([B[BJJ)V");
  if (!method || (*env)->GetJavaVM(env, &progress_vm) != JNI_OK) return JNI_FALSE;
  progress_receiver = (*env)->NewGlobalRef(env, receiver);
  if (!progress_receiver) return JNI_FALSE;
  progress_method = method;
  install(graph_import_progress);
  return JNI_TRUE;
}

static jbyteArray call_none(JNIEnv *env, const char *symbol) {
  lui_fn_none fn = (lui_fn_none)core_symbol(symbol);
  return fn ? cstr_to_jbytes(env, fn()) : NULL;
}

static jbyteArray call_l(JNIEnv *env, const char *symbol, jlong a) {
  lui_fn_l fn = (lui_fn_l)core_symbol(symbol);
  return fn ? cstr_to_jbytes(env, fn(a)) : NULL;
}

static jbyteArray call_ls(JNIEnv *env, const char *symbol, jlong a, jbyteArray b) {
  lui_fn_ls fn = (lui_fn_ls)core_symbol(symbol);
  if (!fn) return NULL;
  char *bs = jbytes_to_cstr(env, b);
  const char *result = fn(a, bs);
  jbyteArray out = cstr_to_jbytes(env, result);
  free(bs);
  return out;
}

static jbyteArray call_s(JNIEnv *env, const char *symbol, jbyteArray a) {
  lui_fn_s fn = (lui_fn_s)core_symbol(symbol);
  if (!fn) return NULL;
  char *as = jbytes_to_cstr(env, a);
  const char *result = fn(as);
  jbyteArray out = cstr_to_jbytes(env, result);
  free(as);
  return out;
}

static jbyteArray call_ss(JNIEnv *env, const char *symbol, jbyteArray a, jbyteArray b) {
  lui_fn_ss fn = (lui_fn_ss)core_symbol(symbol);
  if (!fn) return NULL;
  char *as = jbytes_to_cstr(env, a);
  char *bs = jbytes_to_cstr(env, b);
  const char *result = fn(as, bs);
  jbyteArray out = cstr_to_jbytes(env, result);
  free(as);
  free(bs);
  return out;
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiInitialize(
    JNIEnv *env, jclass clazz, jint platform, jint host, jint authentication) {
  (void)clazz;
  lui_fn_iii fn = (lui_fn_iii)core_symbol("logseq_lui_initialize");
  return fn ? cstr_to_jbytes(env, fn(platform, host, authentication)) : NULL;
}

JNIEXPORT jlong JNICALL Java_com_logseq_app_NativeCore_luiRootNode(
    JNIEnv *env, jclass clazz) {
  (void)env; (void)clazz;
  typedef long long (*root_fn)(void);
  root_fn fn = (root_fn)core_symbol("logseq_lui_root_node");
  return fn ? (jlong)fn() : 0;
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiAppear(
    JNIEnv *env, jclass clazz, jlong node) {
  (void)clazz;
  return call_l(env, "logseq_lui_appear", node);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiPress(
    JNIEnv *env, jclass clazz, jlong node) {
  (void)clazz;
  return call_l(env, "logseq_lui_press", node);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiLongPress(
    JNIEnv *env, jclass clazz, jlong node) {
  (void)clazz;
  return call_l(env, "logseq_lui_long_press", node);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiSubmit(
    JNIEnv *env, jclass clazz, jlong node) {
  (void)clazz;
  return call_l(env, "logseq_lui_submit", node);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiChange(
    JNIEnv *env, jclass clazz, jlong node) {
  (void)clazz;
  return call_l(env, "logseq_lui_change", node);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiDismiss(
    JNIEnv *env, jclass clazz, jlong node) {
  (void)clazz;
  return call_l(env, "logseq_lui_dismiss", node);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiDoublePress(
    JNIEnv *env, jclass clazz, jlong node) {
  (void)clazz;
  return call_l(env, "logseq_lui_double_press", node);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiTextChanged(
    JNIEnv *env, jclass clazz, jlong node, jbyteArray text) {
  (void)clazz;
  return call_ls(env, "logseq_lui_text_changed", node, text);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiToggleChanged(
    JNIEnv *env, jclass clazz, jlong node, jint checked) {
  (void)clazz;
  lui_fn_li fn = (lui_fn_li)core_symbol("logseq_lui_toggle_changed");
  return fn ? cstr_to_jbytes(env, fn(node, checked)) : NULL;
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiValueChanged(
    JNIEnv *env, jclass clazz, jlong node, jdouble value) {
  (void)clazz;
  lui_fn_ld fn = (lui_fn_ld)core_symbol("logseq_lui_value_changed");
  return fn ? cstr_to_jbytes(env, fn(node, value)) : NULL;
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiPicked(
    JNIEnv *env, jclass clazz, jlong node, jbyteArray payload) {
  (void)clazz;
  return call_ls(env, "logseq_lui_picked", node, payload);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiVisibleRange(
    JNIEnv *env, jclass clazz, jlong node, jlong first, jlong last) {
  (void)clazz;
  lui_fn_lll fn = (lui_fn_lll)core_symbol("logseq_lui_visible_range");
  return fn ? cstr_to_jbytes(env, fn(node, first, last)) : NULL;
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiScrollCompleted(
    JNIEnv *env, jclass clazz, jlong node, jlong token, jbyteArray outcome) {
  (void)clazz;
  lui_fn_lls fn = (lui_fn_lls)core_symbol("logseq_lui_scroll_completed");
  if (!fn) return NULL;
  char *outcome_s = jbytes_to_cstr(env, outcome);
  const char *result = fn(node, token, outcome_s);
  jbyteArray out = cstr_to_jbytes(env, result);
  free(outcome_s);
  return out;
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiExtensionEvent(
    JNIEnv *env, jclass clazz, jlong node, jbyteArray identifier, jbyteArray name,
    jbyteArray text, jlong value) {
  (void)clazz;
  lui_fn_lsssl fn = (lui_fn_lsssl)core_symbol("logseq_lui_extension_event");
  if (!fn) return NULL;
  char *id_s = jbytes_to_cstr(env, identifier);
  char *name_s = jbytes_to_cstr(env, name);
  char *text_s = jbytes_to_cstr(env, text);
  const char *result = fn(node, id_s, name_s, text_s, value);
  jbyteArray out = cstr_to_jbytes(env, result);
  free(id_s);
  free(name_s);
  free(text_s);
  return out;
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiDispose(
    JNIEnv *env, jclass clazz) {
  (void)clazz;
  return call_none(env, "logseq_lui_dispose");
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiTakeEffect(
    JNIEnv *env, jclass clazz) {
  (void)clazz;
  return call_none(env, "logseq_lui_take_effect");
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiResolveEffect(
    JNIEnv *env, jclass clazz, jlong effectId, jint succeeded, jbyteArray message) {
  (void)clazz;
  lui_fn_lis fn = (lui_fn_lis)core_symbol("logseq_lui_resolve_effect");
  if (!fn) return NULL;
  char *message_s = jbytes_to_cstr(env, message);
  const char *result = fn(effectId, succeeded, message_s);
  jbyteArray out = cstr_to_jbytes(env, result);
  free(message_s);
  return out;
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiApplySnapshot(
    JNIEnv *env, jclass clazz, jbyteArray response) {
  (void)clazz;
  return call_s(env, "logseq_lui_apply_snapshot", response);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_luiApplyHostUpdate(
    JNIEnv *env, jclass clazz, jbyteArray kind, jbyteArray payload) {
  (void)clazz;
  return call_ss(env, "logseq_lui_apply_host_update", kind, payload);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_logseqCall(
    JNIEnv *env, jclass clazz, jbyteArray request) {
  (void)clazz;
  return call_s(env, "logseq_call", request);
}

JNIEXPORT jbyteArray JNICALL Java_com_logseq_app_NativeCore_highlightCode(
    JNIEnv *env, jclass clazz, jbyteArray request) {
  (void)clazz;
  typedef char *(*highlight_fn)(const char *);
  highlight_fn fn = (highlight_fn)core_symbol("logseq_highlight_code");
  if (!fn) return NULL;
  char *input = jbytes_to_cstr(env, request);
  char *result = fn(input);
  jbyteArray output = cstr_to_jbytes(env, result);
  free(input);
  free(result);
  return output;
}
