external https_send_primitive : string -> string -> string -> string -> string
  = "logseq_https_send"

external https_upload_file_primitive :
  string -> string -> string -> string -> string -> string
  = "logseq_https_upload_file"

let https_send_raw method_ url body token =
  try https_send_primitive method_ url body token
  with error -> "ERROR\n" ^ Printexc.to_string error

let https_upload_file_raw method_ url path content_type token =
  try https_upload_file_primitive method_ url path content_type token
  with error -> "ERROR\n" ^ Printexc.to_string error

type http_endpoint =
  { scheme : string
  ; host : string
  ; port : int
  ; request_path : string
  }

let request_timeout_seconds = 30.0

let unix_error_message error =
  match error with
  | Unix.Unix_error (code, operation, argument) ->
    operation ^ "(" ^ argument ^ "): " ^ Unix.error_message code
  | _ -> Printexc.to_string error

let split_first_line value =
  match String.index_opt value '\n' with
  | Some index ->
    ( String.sub value 0 index
    , String.sub value (index + 1) (String.length value - index - 1) )
  | None -> (value, "")

let response_of_native raw =
  let status, body = split_first_line raw in
  if status = "ERROR" then Error body
  else
    match int_of_string_opt status with
    | Some code -> Ok (Api.response code body)
    | None -> Error "invalid native HTTP response"

let parse_url url =
  let scheme, rest, default_port =
    if String_kit.starts_with ~prefix:"http://" url then
      ("http", String.sub url 7 (String.length url - 7), 80)
    else if String_kit.starts_with ~prefix:"https://" url then
      ("https", String.sub url 8 (String.length url - 8), 443)
    else ("", "", 0)
  in
  if scheme = "" then
    Error "only http:// and https:// Logseq API URLs are supported"
  else
    let slash =
      match String.index_opt rest '/' with
      | Some index -> index
      | None -> String.length rest
    in
    let authority = String.sub rest 0 slash in
    let path =
      if slash = String.length rest then "/"
      else String.sub rest slash (String.length rest - slash)
    in
    let host, port =
      match String.rindex_opt authority ':' with
      | Some colon ->
        ( String.sub authority 0 colon
        , int_of_string
            (String.sub authority (colon + 1)
               (String.length authority - colon - 1)) )
      | None -> (authority, default_port)
    in
    if host = "" then Error "Logseq API URL host is empty"
    else Ok { scheme; host; port; request_path = path }

let write_all fd payload =
  let length = Bytes.length payload in
  let rec loop offset =
    if offset < length then begin
      let written = Unix.write fd payload offset (length - offset) in
      if written = 0 then failwith "socket write returned 0";
      loop (offset + written)
    end
  in
  loop 0

let read_all fd =
  let result = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    let size = Unix.read fd chunk 0 (Bytes.length chunk) in
    if size = 0 then Buffer.contents result
    else begin
      Buffer.add_subbytes result chunk 0 size;
      loop ()
    end
  in
  loop ()

let find_substring needle value =
  let rec loop index =
    if index + String.length needle > String.length value then None
    else if String.sub value index (String.length needle) = needle then
      Some index
    else loop (index + 1)
  in
  loop 0

let split_response response =
  match find_substring "\r\n\r\n" response with
  | Some index ->
    Ok
      ( String.sub response 0 index
      , String.sub response (index + 4) (String.length response - index - 4) )
  | None -> Error "HTTP response did not contain headers"

let header_field name headers =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun line ->
      match String.index_opt line ':' with
      | Some colon ->
        if
          String.lowercase_ascii (String_kit.trim (String.sub line 0 colon))
          = name
        then
          Some
            (String.lowercase_ascii
               (String_kit.trim
                  (String.sub line (colon + 1)
                     (String.length line - colon - 1))))
        else None
      | None -> None)
    (String.split_on_char '\n' headers)

let content_length_of_headers headers =
  match header_field "content-length" headers with
  | Some value -> int_of_string_opt value
  | None -> None

let transfer_encoding_is_chunked headers =
  match header_field "transfer-encoding" headers with
  | Some value ->
    List.exists
      (fun part -> String_kit.trim part = "chunked")
      (String.split_on_char ',' value)
  | None -> false

let host_header endpoint =
  if endpoint.port = (if endpoint.scheme = "https" then 443 else 80) then
    endpoint.host
  else endpoint.host ^ ":" ^ string_of_int endpoint.port

let hex_length value =
  match int_of_string_opt ("0x" ^ String_kit.trim value) with
  | Some length when length >= 0 -> Ok length
  | _ -> Error ("invalid HTTP chunk size: " ^ value)

let rec ensure_buffer fd result chunk needed =
  if Buffer.length result >= needed then Ok ()
  else
    let size = Unix.read fd chunk 0 (Bytes.length chunk) in
    if size = 0 then Error "HTTP chunked body ended early"
    else begin
      Buffer.add_subbytes result chunk 0 size;
      ensure_buffer fd result chunk needed
    end

let rec chunk_line_end fd result chunk offset =
  match
    find_substring "\r\n"
      (String.sub (Buffer.contents result) offset
         (Buffer.length result - offset))
  with
  | Some relative -> Ok (offset + relative)
  | None ->
    (match ensure_buffer fd result chunk (Buffer.length result + 1) with
     | Ok () -> chunk_line_end fd result chunk offset
     | Error _ as error -> error)

let read_chunked_body fd initial =
  let ( let* ) = Result.bind in
  let result = Buffer.create (String.length initial + 4096) in
  let chunk = Bytes.create 4096 in
  Buffer.add_string result initial;
  let rec loop offset parts =
    let* crlf = chunk_line_end fd result chunk offset in
    let line =
      String.sub (Buffer.contents result) offset (crlf - offset)
    in
    let line =
      match String.index_opt line ';' with
      | Some index -> String.sub line 0 index
      | None -> line
    in
    let* size = hex_length line in
    if size = 0 then Ok (String.concat "" parts)
    else
      let start = crlf + 2 in
      let finish = start + size in
      let* () = ensure_buffer fd result chunk (finish + 2) in
      loop (finish + 2)
        (parts
         @ [ String.sub (Buffer.contents result) start (finish - start) ])
  in
  loop 0 []

let rec read_header_end fd result chunk =
  match find_substring "\r\n\r\n" (Buffer.contents result) with
  | Some index -> Ok index
  | None ->
    let size = Unix.read fd chunk 0 (Bytes.length chunk) in
    if size = 0 then Error "HTTP response did not contain headers"
    else begin
      Buffer.add_subbytes result chunk 0 size;
      read_header_end fd result chunk
    end

let read_length_body fd chunk initial length =
  let result = Buffer.create length in
  Buffer.add_string result initial;
  let rec loop () =
    let current = Buffer.length result in
    if current >= length then
      Ok (String.sub (Buffer.contents result) 0 length)
    else
      let size =
        Unix.read fd chunk 0 (min (length - current) (Bytes.length chunk))
      in
      if size = 0 then
        Error "HTTP response ended before Content-Length bytes were read"
      else begin
        Buffer.add_subbytes result chunk 0 size;
        loop ()
      end
  in
  loop ()

let read_response fd =
  let ( let* ) = Result.bind in
  let result = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let* finish = read_header_end fd result chunk in
  let raw = Buffer.contents result in
  let headers = String.sub raw 0 finish in
  let initial = String.sub raw (finish + 4) (String.length raw - finish - 4) in
  let* body =
    match content_length_of_headers headers with
    | Some length -> read_length_body fd chunk initial length
    | None ->
      if transfer_encoding_is_chunked headers then
        read_chunked_body fd initial
      else Ok (initial ^ read_all fd)
  in
  Ok (headers, body)

let status_of_headers headers =
  match String.index_opt headers '\r' with
  | Some finish ->
    let line = String.sub headers 0 finish in
    (match String.split_on_char ' ' line with
     | _ :: code :: _ -> Ok (int_of_string code)
     | _ -> Error ("invalid HTTP status line: " ^ line))
  | None -> Error "HTTP status line is missing"

let configure_socket fd =
  Unix.clear_nonblock fd;
  Unix.setsockopt_float fd Unix.SO_RCVTIMEO request_timeout_seconds;
  Unix.setsockopt_float fd Unix.SO_SNDTIMEO request_timeout_seconds

let finish_nonblocking_connect fd =
  let _, writable, _ =
    Unix.select [] [ fd ] [] request_timeout_seconds
  in
  if writable = [] then Error "HTTP connect timed out after 30s"
  else
    match Unix.getsockopt_error fd with
    | Some error -> Error (Unix.error_message error)
    | None ->
      configure_socket fd;
      Ok fd

let connect_address fd address =
  try
    Unix.connect fd address.Unix.ai_addr;
    configure_socket fd;
    Ok fd
  with
  | Unix.Unix_error ((Unix.EINPROGRESS | Unix.EWOULDBLOCK | Unix.EAGAIN), _, _) ->
    finish_nonblocking_connect fd
  | error -> Error (unix_error_message error)

let try_addresses addresses unresolved =
  let rec loop index first_error =
    if index = List.length addresses then
      Error (match first_error with Some e -> e | None -> unresolved)
    else
      let address = List.nth addresses index in
      let fd =
        Unix.socket address.Unix.ai_family address.ai_socktype
          address.ai_protocol
      in
      Unix.set_nonblock fd;
      match connect_address fd address with
      | Ok fd -> Ok fd
      | Error message ->
        Unix.close fd;
        loop (index + 1)
          (match first_error with
           | Some error -> Some error
           | None -> Some message)
  in
  loop 0 None

let connect endpoint =
  let service = string_of_int endpoint.port in
  let addresses =
    Unix.getaddrinfo endpoint.host service
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  in
  try_addresses addresses
    ("could not resolve " ^ endpoint.host ^ ":" ^ service)

let send_http_body (request : Api.api_request) endpoint content_type
    extra_headers body =
  let ( let* ) = Result.bind in
  let* fd = connect endpoint in
  try
    let headers =
      String.concat "\r\n"
        ([ request.method_ ^ " " ^ endpoint.request_path ^ " HTTP/1.0"
         ; "Host: " ^ host_header endpoint
         ; "Authorization: Bearer " ^ request.token
         ; "Accept: application/json"
         ; "Content-Type: " ^ content_type
         ; "Connection: close"
         ; "Content-Length: " ^ string_of_int (String.length body)
         ]
         @ List.map
             (fun (name, value) -> name ^ ": " ^ value)
             extra_headers
         @ [ ""; body ])
    in
    write_all fd (Bytes.of_string headers);
    let* _headers, body = read_response fd in
    let* status = status_of_headers _headers in
    Unix.close fd;
    Ok (Api.response status body)
  with error ->
    Unix.close fd;
    Error (unix_error_message error)

let send_http request endpoint extra_headers body =
  send_http_body request endpoint "application/json" extra_headers body

let send_https (request : Api.api_request) =
  let status, body =
    split_first_line
      (https_send_raw request.method_ request.url
         (match request.body with Some body -> body | None -> "")
         request.token)
  in
  if status = "ERROR" then Error body
  else
    match int_of_string_opt status with
    | Some code -> Ok (Api.response code body)
    | None -> Error ("invalid HTTPS status: " ^ status)

let send (request : Api.api_request) =
  let ( let* ) = Result.bind in
  let* endpoint = parse_url request.url in
  if endpoint.scheme = "https" then send_https request
  else
    send_http request endpoint []
      (match request.body with Some body -> body | None -> "")

let read_file_bytes path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        Ok (really_input_string channel (in_channel_length channel)))
  with error ->
    Error ("could not read upload file: " ^ unix_error_message error)

let upload_http (upload : Api.api_file_upload) endpoint =
  let ( let* ) = Result.bind in
  let* body = read_file_bytes upload.file_path in
  send_http_body upload.request endpoint upload.content_type upload.headers body

let upload_file (upload : Api.api_file_upload) =
  let ( let* ) = Result.bind in
  let* endpoint = parse_url upload.request.url in
  if endpoint.scheme = "https" then
    response_of_native
      (https_upload_file_raw upload.request.method_ upload.request.url
         upload.file_path upload.content_type upload.request.token)
  else upload_http upload endpoint
