(** Minimal HTTP/1.0 client over Unix sockets; HTTPS delegates to the host
    platform through OCaml C primitives. *)

type http_endpoint =
  { scheme : string
  ; host : string
  ; port : int
  ; request_path : string
  }

val https_send_raw : string -> string -> string -> string -> string
val https_upload_file_raw :
  string -> string -> string -> string -> string -> string
val request_timeout_seconds : float
val split_first_line : string -> string * string
val response_of_native : string -> (Api.api_response, string) result
val parse_url : string -> (http_endpoint, string) result
val write_all : Unix.file_descr -> bytes -> unit
val read_all : Unix.file_descr -> string
val find_substring : string -> string -> int option
val split_response : string -> (string * string, string) result
val header_field : string -> string -> string option
val content_length_of_headers : string -> int option
val transfer_encoding_is_chunked : string -> bool
val host_header : http_endpoint -> string
val read_response : Unix.file_descr -> (string * string, string) result
val status_of_headers : string -> (int, string) result
val connect : http_endpoint -> (Unix.file_descr, string) result
val send_http_body :
  Api.api_request ->
  http_endpoint ->
  string ->
  (string * string) list ->
  string ->
  (Api.api_response, string) result
val send_http :
  Api.api_request ->
  http_endpoint ->
  (string * string) list ->
  string ->
  (Api.api_response, string) result
val send_https : Api.api_request -> (Api.api_response, string) result
val send : Api.api_request -> (Api.api_response, string) result
val read_file_bytes : string -> (string, string) result
val upload_http :
  Api.api_file_upload -> http_endpoint -> (Api.api_response, string) result
val upload_file : Api.api_file_upload -> (Api.api_response, string) result
