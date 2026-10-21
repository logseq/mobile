#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <caml/mlvalues.h>

extern jint JNI_OnLoad(JavaVM *, void *);
static int failure_mode, exception_pending, last_crypto;
static const struct JNINativeInterface_ methods;
static JNIEnv environment = &methods;
static jint get_env(JavaVM *vm, void **env, jint version) {
  (void)vm; (void)version; *env = &environment; return JNI_OK;
}
static const struct JNIInvokeInterface_ vm_methods = { .GetEnv = get_env };
static JavaVM vm = &vm_methods;
static jclass find_class(JNIEnv *env, const char *name) {
  (void)env; (void)name; return (jclass)1;
}
static jobject global_ref(JNIEnv *env, jobject object) { (void)env; return object; }
static void delete_ref(JNIEnv *env, jobject object) { (void)env; (void)object; }
static jmethodID method_id(JNIEnv *env, jclass cls, const char *name, const char *signature) {
  (void)env; (void)cls; (void)signature;
  return (jmethodID)(strcmp(name, "call") == 0 ? 3L : 1L);
}
static jstring new_string(JNIEnv *env, const char *input) {
  (void)env; (void)input;
  if (failure_mode == 1) { exception_pending = 1; return NULL; }
  return (jstring)1;
}
static jobject call_static(JNIEnv *env, jclass cls, jmethodID method, ...) {
  (void)env; (void)cls;
  /* CheckJNI rejects invoking Java with a pending allocation exception. */
  if (exception_pending) abort();
  last_crypto = method == (jmethodID)3;
  if (failure_mode == 3) { exception_pending = 1; return NULL; }
  return failure_mode == 4 ? NULL : (jobject)1;
}
static jboolean exception_check(JNIEnv *env) { (void)env; return exception_pending; }
static void exception_clear(JNIEnv *env) { (void)env; exception_pending = 0; }
static const char *string_chars(JNIEnv *env, jstring string, jboolean *copy) {
  (void)env; (void)string; (void)copy;
  if (failure_mode == 2) { exception_pending = 1; return NULL; }
  return last_crypto ? "{\"ok\":true}" : "200\n{}";
}
static void release_chars(JNIEnv *env, jstring string, const char *chars) {
  (void)env; (void)string; (void)chars;
}
static const struct JNINativeInterface_ methods = {
  .FindClass = find_class, .NewGlobalRef = global_ref, .DeleteLocalRef = delete_ref,
  .GetStaticMethodID = method_id, .NewStringUTF = new_string,
  .CallStaticObjectMethod = call_static, .ExceptionCheck = exception_check,
  .ExceptionClear = exception_clear, .GetStringUTFChars = string_chars,
  .ReleaseStringUTFChars = release_chars
};
CAMLprim value test_jni_mode(value mode) {
  failure_mode = Int_val(mode); exception_pending = 0;
  if (JNI_OnLoad(&vm, NULL) != JNI_VERSION_1_6) abort();
  return Val_unit;
}
CAMLprim value test_jni_exception_pending(value unit) {
  (void)unit; return Val_bool(exception_pending);
}
