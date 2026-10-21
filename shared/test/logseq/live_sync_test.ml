let failure_message f =
  try
    ignore (f ());
    None
  with Failure message -> Some message

let snapshot_urls_preserve_absolute_and_relative_addresses () =
  Test_util.check_eq
    (Live_sync.absolute_url "https://example/api" "https://cdn.example/a")
    "https://cdn.example/a";
  Test_util.check_eq
    (Live_sync.absolute_url "https://example/api" "http://cdn.example/a")
    "http://cdn.example/a";
  Test_util.check_eq
    (Live_sync.absolute_url "https://example/api/" "/snapshot")
    "https://example/snapshot";
  Test_util.check_eq
    (Live_sync.absolute_url "https://example/api" "relative")
    "relative";
  Test_util.check_eq (Live_sync.absolute_url "https://example/api" "") ""

let snapshot_download_uses_metadata_position_without_pull () =
  let server = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen server 2;
  let port = match Unix.getsockname server with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> failwith "expected inet socket" in
  let requests = ref [] in
  let worker = Thread.create (fun () ->
    for _ = 1 to 2 do
      let ready, _, _ = Unix.select [server] [] [] 2. in
      if ready <> [] then begin
        let client, _ = Unix.accept server in
        let input = Unix.in_channel_of_descr client in
        let line = String.trim (input_line input) in
        requests := line :: !requests;
        let rec headers () =
          match input_line input with "\r" | "" -> () | _ -> headers () in
        headers ();
        let status, body = match String.split_on_char ' ' line with
          | ["GET"; "/sync/graph/snapshot/download"; _] ->
            200, {|{"ok":true,"url":"/sync/graph/snapshot/stream","t":42}|}
          | ["GET"; "/sync/graph/snapshot/stream"; _] -> 200, "snapshot bytes"
          | _ -> 404, "unexpected request" in
        let response = Printf.sprintf
          "HTTP/1.0 %d OK\r\nContent-Length: %d\r\n\r\n%s"
          status (String.length body) body in
        Http.write_all client (Bytes.of_string response);
        close_in input
      end
    done) () in
  Fun.protect ~finally:(fun () -> Thread.join worker; Unix.close server) (fun () ->
    let metadata, path = Live_sync.download_snapshot
      (Live_sync.config (Printf.sprintf "http://127.0.0.1:%d" port) "token" "graph") in
    Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
      Test_util.check_eq metadata.Sync_session.baseline_t 42;
      let channel = open_in_bin path in
      let body = Fun.protect ~finally:(fun () -> close_in channel)
        (fun () -> really_input_string channel (in_channel_length channel)) in
      Test_util.check_eq body "snapshot bytes";
      Test_util.check_eq (List.rev !requests)
        ["GET /sync/graph/snapshot/download HTTP/1.0";
         "GET /sync/graph/snapshot/stream HTTP/1.0"]))

let http_results_preserve_accepted_statuses_and_step_context () =
  let created = Api.response 201 "created"
  and rejected = Api.response 409 "stale" in
  Test_util.check_eq
    (Live_sync.expect_response "create" [ 200; 201 ] (Ok created))
    created;
  Test_util.check_eq
    (Live_sync.expect_response "submit" [ 200; 409 ] (Ok rejected))
    rejected;
  Test_util.check_eq
    (failure_message (fun () ->
       Live_sync.expect_response "create" [ 200; 201 ] (Ok rejected)))
    (Some "create: HTTP 409 stale");
  Test_util.check_eq
    (failure_message (fun () ->
       Live_sync.expect_response "download" [ 200 ] (Error "offline")))
    (Some "download: offline")

let json_fields_retain_original_decoding_semantics () =
  let input = Live_sync.json_object "{\"s\":\"\",\"n\":3.9,\"b\":true}" in
  Test_util.check_eq (Live_sync.json_string "s" input) (Some "");
  Test_util.check_eq (Live_sync.json_int "n" input) (Some 3);
  Test_util.check_eq (Live_sync.json_int "b" input) None;
  Test_util.check_eq (Live_sync.json_string "missing" input) None;
  Test_util.check_eq
    (failure_message (fun () -> Live_sync.json_object "[]"))
    (Some "expected a JSON object: []")

let temporary_directories_clean_up_nested_files () =
  let path =
    Live_sync.with_temp_dir "lg-live-test" (fun path ->
      let nested = Filename.concat path "nested" in
      Unix.mkdir nested 0o755;
      let channel =
        open_out_bin (Filename.concat nested "data")
      in
      output_string channel "snapshot";
      close_out channel;
      Test_util.check (Sys.file_exists path);
      path)
  in
  Test_util.check (not (Sys.file_exists path));
  Live_sync.remove_tree path

let temporary_directories_clean_up_when_the_flow_fails () =
  let created = ref "" in
  Test_util.check_eq
    (failure_message (fun () ->
       Live_sync.with_temp_dir "lg-live-failure" (fun path ->
         created := path;
         failwith "flow failed")))
    (Some "flow failed");
  Test_util.check (not (Sys.file_exists !created))

let asset_mismatch_quotes_values_without_changing_case () =
  Test_util.check_eq
    (Live_sync.asset_mismatch "lowercase" "Mixed Case")
    "expected \"lowercase\", got \"Mixed Case\""

let cases =
  [ Test_util.case "snapshot urls preserve absolute and relative addresses"
      snapshot_urls_preserve_absolute_and_relative_addresses;
    Test_util.case "snapshot download uses metadata position without pull"
      snapshot_download_uses_metadata_position_without_pull;
    Test_util.case "http results preserve accepted statuses and step context"
      http_results_preserve_accepted_statuses_and_step_context;
    Test_util.case "json fields retain original decoding semantics"
      json_fields_retain_original_decoding_semantics;
    Test_util.case "temporary directories clean up nested files"
      temporary_directories_clean_up_nested_files;
    Test_util.case "temporary directories clean up when the flow fails"
      temporary_directories_clean_up_when_the_flow_fails;
    Test_util.case "asset mismatch quotes values without changing case"
      asset_mismatch_quotes_values_without_changing_case ]
