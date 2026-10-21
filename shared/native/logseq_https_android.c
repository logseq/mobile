#include <jni.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

static JavaVM *java_vm;
static jclass transport_class;
static jmethodID send_method;
static jmethodID upload_method;

extern int logseq_crypto_jni_init(JNIEnv *env);

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
  JNIEnv *env = NULL;
  jclass local_class;
  (void)reserved;
  java_vm = vm;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
  local_class = (*env)->FindClass(env, "logseq/app/AndroidHttpTransport");
  if (local_class == NULL) return JNI_ERR;
  transport_class = (*env)->NewGlobalRef(env, local_class);
  (*env)->DeleteLocalRef(env, local_class);
  send_method = (*env)->GetStaticMethodID(env, transport_class, "send", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
  upload_method = (*env)->GetStaticMethodID(env, transport_class, "uploadFile", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
  return send_method != NULL && upload_method != NULL && logseq_crypto_jni_init(env)
    ? JNI_VERSION_1_6
    : JNI_ERR;
}

JavaVM *logseq_android_java_vm(void) {
  return java_vm;
}

static value call_transport(jmethodID method_id, const char **arguments, int count) {
  CAMLparam0();
  CAMLlocal1(result);
  JNIEnv *env = NULL;
  jstring java_arguments[5];
  jstring java_result;
  const char *response;
  int attached = 0;
  int index;

  if (java_vm == NULL) CAMLreturn(caml_copy_string("ERROR\nAndroid JVM is unavailable"));
  if ((*java_vm)->GetEnv(java_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
    if ((*java_vm)->AttachCurrentThread(java_vm, &env, NULL) != JNI_OK)
      CAMLreturn(caml_copy_string("ERROR\nCould not attach Android HTTP thread"));
    attached = 1;
  }
  for (index = 0; index < count; index++) {
    java_arguments[index] = (*env)->NewStringUTF(env, arguments[index]);
    if (java_arguments[index] == NULL || (*env)->ExceptionCheck(env)) {
      (*env)->ExceptionClear(env);
      for (int created = 0; created <= index; created++) {
        if (java_arguments[created] != NULL)
          (*env)->DeleteLocalRef(env, java_arguments[created]);
      }
      if (attached) (*java_vm)->DetachCurrentThread(java_vm);
      CAMLreturn(caml_copy_string("ERROR\nAndroid HTTP argument allocation failed"));
    }
  }
  if (count == 4)
    java_result = (jstring)(*env)->CallStaticObjectMethod(env, transport_class, method_id,
      java_arguments[0], java_arguments[1], java_arguments[2], java_arguments[3]);
  else
    java_result = (jstring)(*env)->CallStaticObjectMethod(env, transport_class, method_id,
      java_arguments[0], java_arguments[1], java_arguments[2], java_arguments[3], java_arguments[4]);
  for (index = 0; index < count; index++) (*env)->DeleteLocalRef(env, java_arguments[index]);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    result = caml_copy_string("ERROR\nAndroid HTTP transport threw an exception");
  } else if (java_result == NULL) {
    result = caml_copy_string("ERROR\nAndroid HTTP transport returned no response");
  } else {
    response = (*env)->GetStringUTFChars(env, java_result, NULL);
    if (response == NULL) {
      (*env)->ExceptionClear(env);
      result = caml_copy_string("ERROR\nAndroid HTTP response allocation failed");
    } else {
      result = caml_copy_string(response);
      (*env)->ReleaseStringUTFChars(env, java_result, response);
    }
    (*env)->DeleteLocalRef(env, java_result);
  }
  if (attached) (*java_vm)->DetachCurrentThread(java_vm);
  CAMLreturn(result);
}

CAMLprim value logseq_https_send(value method, value url, value body, value token) {
  CAMLparam4(method, url, body, token);
  const char *arguments[] = {String_val(method), String_val(url), String_val(body), String_val(token)};
  CAMLreturn(call_transport(send_method, arguments, 4));
}

CAMLprim value logseq_https_upload_file(value method, value url, value file_path,
                                              value content_type, value token) {
  CAMLparam5(method, url, file_path, content_type, token);
  const char *arguments[] = {String_val(method), String_val(url), String_val(file_path), String_val(content_type), String_val(token)};
  CAMLreturn(call_transport(upload_method, arguments, 5));
}
