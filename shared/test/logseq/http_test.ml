open Test_util

module Http = Http

let () =
  Callback.register "platform_https_test_call" (fun (fields : string array) ->
    Gc.full_major ();
    "200\n" ^ Yojson.Basic.to_string
      (`List (Array.to_list (Array.map (fun s -> `String s) fields))))

let native_https_arguments_survive_collection () =
  let url = "https://native-ffi.test/graph" in
  let body = String.make 32768 'x' ^ "中文" in
  let expected fields = Ok (Api.response 200 (Yojson.Basic.to_string
    (`List (List.map (fun s -> `String s) fields)))) in
  for index = 0 to 15 do
    let token = "token-" ^ string_of_int index in
    check_eq (expected ["POST"; url; body; token])
      (Http.send {Api.method_ = "POST"; url; body = Some body; token});
    check_eq (expected ["PUT"; url; "/tmp/图片.png"; "image/png"; token])
      (Http.upload_file {Api.request = {Api.method_ = "PUT"; url; body = None; token};
        file_path = "/tmp/图片.png"; content_type = "image/png"; headers = []})
  done

let close_quietly fd =
  try Unix.close fd with Unix.Unix_error _ -> ()

let write_string fd value =
  let rec loop offset =
    if offset < String.length value then begin
      let written =
        Unix.write_substring fd value offset (String.length value - offset)
      in
      if written = 0 then failwith "pipe write returned 0";
      loop (offset + written)
    end
  in
  loop 0

let with_timeout seconds f =
  let previous =
    Sys.signal Sys.sigalrm
      (Sys.Signal_handle (fun _ -> failwith "timed out"))
  in
  ignore (Unix.alarm seconds);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0);
      Sys.set_signal Sys.sigalrm previous)
    f

let read_keep_alive response =
  let read_fd, write_fd = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      close_quietly read_fd;
      close_quietly write_fd)
    (fun () ->
      write_string write_fd response;
      with_timeout 1 (fun () -> Http.read_response read_fd))

let response_from_parts parts =
  let read_fd, write_fd = Unix.pipe () in
  let writer =
    Thread.create
      (fun () ->
        Fun.protect
          ~finally:(fun () -> close_quietly write_fd)
          (fun () ->
            List.iter
              (fun part ->
                write_string write_fd part;
                Thread.delay 0.001)
              parts))
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      close_quietly read_fd;
      Thread.join writer)
    (fun () ->
      with_timeout 2 (fun () ->
        match Http.read_response read_fd with
        | Ok (_, body) -> Ok body
        | Error message -> Error message))

let keep_alive_does_not_wait_for_eof () =
  let response =
    read_keep_alive
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}"
  in
  check_eq
    (Ok
       ( "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive"
       , "{}" ))
    response

let chunked_keep_alive_does_not_wait_for_eof () =
  check_eq
    (Ok
       ( "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: \
          keep-alive"
       , "hello world" ))
    (read_keep_alive
       "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: \
        keep-alive\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")

let fragmented_and_invalid_responses () =
  List.iter
    (fun (parts, expected) -> check_eq expected (response_from_parts parts))
    [
      ( [ "HTTP/1.1 200 OK\r\nContent-Len"; "gth: 5\r\n\r"; "\nhe"; "llo" ]
      , Ok "hello" );
      ( [
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, Chunked\r\n\r\n";
          "2;test=yes\r";
          "\nhe\r\n3\r\nllo\r\n0\r\n\r\n";
        ]
      , Ok "hello" );
      ([ "HTTP/1.0 200 OK\r\nX-Test: yes\r\n\r\nhi"; " there" ], Ok "hi there");
      ([ "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" ], Ok "");
      ([ "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhello" ], Ok "he");
      ([ "HTTP/1.1 200 OK" ], Error "HTTP response did not contain headers");
      ( [ "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi" ]
      , Error "HTTP response ended before Content-Length bytes were read" );
      ( [ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhi" ]
      , Error "HTTP chunked body ended early" );
      ( [ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nnope\r\n" ]
      , Error "invalid HTTP chunk size: nope" );
    ]

let native_response_and_endpoint_parsing () =
  (match Http.response_of_native "201\nhello\nworld" with
   | Ok (response : Api.api_response) ->
     check_eq 201 response.status;
     check_eq "hello\nworld" response.body
   | Error message -> failwith message);
  check_eq (Error "transport failed")
    (Http.response_of_native "ERROR\ntransport failed");
  check_eq (Error "invalid native HTTP response")
    (Http.response_of_native "bad\nbody");
  List.iter
    (fun (url, scheme, host, port, path) ->
      match Http.parse_url url with
      | Ok (endpoint : Http.http_endpoint) ->
        check_eq scheme endpoint.scheme;
        check_eq host endpoint.host;
        check_eq port endpoint.port;
        check_eq path endpoint.request_path
      | Error message -> failwith message)
    [
      ("http://localhost", "http", "localhost", 80, "/");
      ("https://example.test/a?q=1", "https", "example.test", 443, "/a?q=1");
      ("http://localhost:8123/a", "http", "localhost", 8123, "/a");
    ]

let https_routes_to_native_transport () =
  match
    Http.send
      {
        Api.method_ = "GET";
        url = "https://api-staging.logseq.io/api/v1/graphs";
        body = None;
        token = "token";
      }
  with
  | Ok _ -> ()
  | Error message ->
    check (message <> "only http:// Logseq API URLs are supported")

let contains_sub hay needle =
  let len = String.length needle in
  let rec scan i =
    if i + len > String.length hay then false
    else String.sub hay i len = needle || scan (i + 1)
  in
  len = 0 || scan 0

let binary_upload_over_real_socket () =
  let server = Unix.socket ~cloexec:false Unix.PF_INET Unix.SOCK_STREAM 0 in
  let path = Filename.temp_file "logseq-upload" ".bin" in
  let payload =
    "\000" ^ String.make 5000 'x' ^ "asset-bytes"
    ^ String.make 1 (Char.chr 255)
    ^ "中"
  in
  Fun.protect
    ~finally:(fun () ->
      close_quietly server;
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Unix.setsockopt server Unix.SO_REUSEADDR true;
      Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      Unix.listen server 1;
      let port =
        match Unix.getsockname server with
        | Unix.ADDR_INET (_, port) -> port
        | _ -> failwith "expected an inet listen socket"
      in
      let channel = open_out_bin path in
      Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
        output_string channel payload);
      let result = ref (Error "upload thread did not finish") in
      let worker =
        Thread.create
          (fun () ->
            result :=
              Http.upload_file
                {
                  Api.request =
                    {
                      Api.method_ = "PUT";
                      url =
                        "http://127.0.0.1:" ^ string_of_int port
                        ^ "/assets/graph/file.png";
                      body = None;
                      token = "access-token";
                    };
                  file_path = path;
                  content_type = "image/png";
                  headers =
                    [
                      ("x-amz-meta-checksum", "abc123");
                      ("x-amz-meta-type", "png");
                    ];
                })
          ()
      in
      let client, _ = with_timeout 2 (fun () -> Unix.accept server) in
      Fun.protect
        ~finally:(fun () -> close_quietly client)
        (fun () ->
          let received = Buffer.create 256 in
          let chunk = Bytes.create 1024 in
          let request =
            with_timeout 2 (fun () ->
              let rec loop () =
                let raw = Buffer.contents received in
                if
                  contains_sub raw payload
                  && contains_sub raw "x-amz-meta-checksum: abc123"
                  && contains_sub raw "PUT /assets/graph/file.png"
                then raw
                else
                  let size = Unix.read client chunk 0 (Bytes.length chunk) in
                  if size = 0 then raw
                  else begin
                    Buffer.add_subbytes received chunk 0 size;
                    loop ()
                  end
              in
              loop ())
          in
          check (contains_sub request payload);
          check
            (contains_sub request
               ("Content-Length: " ^ string_of_int (String.length payload)));
          check (contains_sub request "x-amz-meta-checksum: abc123");
          check (contains_sub request "Content-Type: image/png");
          check
            (contains_sub request ("Host: 127.0.0.1:" ^ string_of_int port));
          write_string client
            "HTTP/1.0 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}";
          Thread.join worker;
          check_eq (Ok (Api.response 200 "{\"ok\":true}")) !result))

let cases =
  [
    case "native HTTPS arguments survive collection" native_https_arguments_survive_collection;
    case "keep alive does not wait for eof" keep_alive_does_not_wait_for_eof;
    case "chunked keep alive does not wait for eof"
      chunked_keep_alive_does_not_wait_for_eof;
    case "fragmented and invalid responses" fragmented_and_invalid_responses;
    case "native response and endpoint parsing"
      native_response_and_endpoint_parsing;
    case "https routes to native transport" https_routes_to_native_transport;
    case "binary upload over real socket" binary_upload_over_real_socket;
  ]
