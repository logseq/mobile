#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <string.h>

/* Match the mobile primitive's OCaml value ABI, including rooted arguments. */
CAMLprim value logseq_crypto_call(value request) {
  CAMLparam1(request);
  CAMLlocal1(resp);
  resp = caml_callback(*caml_named_value("platform_crypto_test_call"), request);
  CAMLreturn(resp);
}

CAMLprim value logseq_https_send(value method, value url, value body, value token) {
  CAMLparam4(method, url, body, token);
  CAMLlocal2(fields, result);
  if (strncmp(String_val(url), "https://native-ffi.test/",
              sizeof("https://native-ffi.test/") - 1) != 0) {
    CAMLreturn(caml_copy_string("ERROR\nHTTPS unavailable in core tests"));
  }
  fields = caml_alloc_tuple(4);
  Store_field(fields, 0, method);
  Store_field(fields, 1, url);
  Store_field(fields, 2, body);
  Store_field(fields, 3, token);
  result = caml_callback(*caml_named_value("platform_https_test_call"), fields);
  CAMLreturn(result);
}

CAMLprim value logseq_https_upload_file(value method, value url, value path,
                                      value content_type, value token) {
  CAMLparam5(method, url, path, content_type, token);
  CAMLlocal2(fields, result);
  if (strncmp(String_val(url), "https://native-ffi.test/",
              sizeof("https://native-ffi.test/") - 1) != 0) {
    CAMLreturn(caml_copy_string("ERROR\nHTTPS unavailable in core tests"));
  }
  fields = caml_alloc_tuple(5);
  Store_field(fields, 0, method);
  Store_field(fields, 1, url);
  Store_field(fields, 2, path);
  Store_field(fields, 3, content_type);
  Store_field(fields, 4, token);
  result = caml_callback(*caml_named_value("platform_https_test_call"), fields);
  CAMLreturn(result);
}
