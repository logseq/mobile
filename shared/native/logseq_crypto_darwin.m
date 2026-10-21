#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

extern char *logseq_crypto_json(const char *request);

CAMLprim value logseq_crypto_call(value request) {
  CAMLparam1(request);
  CAMLlocal1(result);
  /* The runtime may move the request while Swift runs without its lock. */
  char *request_copy = strdup(String_val(request));
  char *response = NULL;
  if (request_copy == NULL) {
    CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"crypto request allocation failed\"}"));
  }
  caml_enter_blocking_section();
  response = logseq_crypto_json(request_copy);
  caml_leave_blocking_section();
  free(request_copy);
  if (response == NULL) {
    CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"crypto bridge returned null\"}"));
  }
  result = caml_copy_string(response);
  free(response);
  CAMLreturn(result);
}
