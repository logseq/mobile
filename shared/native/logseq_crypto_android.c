#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

static jclass crypto_class;
static jmethodID crypto_call_method;

extern JavaVM *logseq_android_java_vm(void);

int logseq_crypto_jni_init(JNIEnv *env) {
  jclass local_class = (*env)->FindClass(env, "logseq/app/AndroidE2EECrypto");
  if (local_class == NULL) return 0;
  crypto_class = (*env)->NewGlobalRef(env, local_class);
  (*env)->DeleteLocalRef(env, local_class);
  if (crypto_class == NULL) return 0;
  crypto_call_method = (*env)->GetStaticMethodID(
    env,
    crypto_class,
    "call",
    "(Ljava/lang/String;)Ljava/lang/String;"
  );
  return crypto_call_method != NULL;
}

static char *error_response(const char *message) {
  size_t size = strlen(message) + 34;
  char *response = malloc(size);
  if (response == NULL) return NULL;
  snprintf(response, size, "{\"ok\":false,\"error\":\"%s\"}", message);
  return response;
}

static char *call_android_crypto(const char *request) {
  JavaVM *java_vm = logseq_android_java_vm();
  JNIEnv *env = NULL;
  jstring java_request;
  jstring java_response;
  const char *response_chars;
  char *response;
  int attached = 0;

  if (java_vm == NULL) return error_response("Android JVM is unavailable");
  if ((*java_vm)->GetEnv(java_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
    if ((*java_vm)->AttachCurrentThread(java_vm, &env, NULL) != JNI_OK)
      return error_response("Could not attach Android crypto thread");
    attached = 1;
  }
  java_request = (*env)->NewStringUTF(env, request);
  if (java_request == NULL || (*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    if (java_request != NULL) (*env)->DeleteLocalRef(env, java_request);
    if (attached) (*java_vm)->DetachCurrentThread(java_vm);
    return error_response("Android crypto argument allocation failed");
  }
  java_response = (jstring)(*env)->CallStaticObjectMethod(
    env,
    crypto_class,
    crypto_call_method,
    java_request
  );
  (*env)->DeleteLocalRef(env, java_request);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    response = error_response("Android crypto threw an exception");
  } else if (java_response == NULL) {
    response = error_response("Android crypto returned no response");
  } else {
    response_chars = (*env)->GetStringUTFChars(env, java_response, NULL);
    if (response_chars == NULL) {
      (*env)->ExceptionClear(env);
      response = error_response("Android crypto response allocation failed");
    } else {
      response = strdup(response_chars);
      (*env)->ReleaseStringUTFChars(env, java_response, response_chars);
    }
    (*env)->DeleteLocalRef(env, java_response);
  }
  if (attached) (*java_vm)->DetachCurrentThread(java_vm);
  return response;
}

CAMLprim value logseq_crypto_call(value request) {
  CAMLparam1(request);
  CAMLlocal1(result);
  char *request_copy = strdup(String_val(request));
  char *response;
  if (request_copy == NULL)
    CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"crypto request allocation failed\"}"));
  caml_enter_blocking_section();
  response = call_android_crypto(request_copy);
  caml_leave_blocking_section();
  free(request_copy);
  if (response == NULL)
    CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"crypto response allocation failed\"}"));
  result = caml_copy_string(response);
  free(response);
  CAMLreturn(result);
}
