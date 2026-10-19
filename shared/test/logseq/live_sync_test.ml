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

let pull_cursor_only_changes_on_recognized_success () =
  let metadata =
    { Sync_session.url = "/snapshot";
      content_encoding = None;
      baseline_t = 7;
      schema_version = Some "1";
      row_count = Some 12 }
  in
  Test_util.check_eq
    (Live_sync.merge_pull_cursor metadata
       "{\"type\":\"pull/ok\",\"t\":9}")
    { metadata with baseline_t = 9 };
  Test_util.check_eq
    (Live_sync.merge_pull_cursor metadata
       "{\"type\":\"pull/ok\",\"t\":9.8}")
    { metadata with baseline_t = 9 };
  List.iter
    (fun body ->
       Test_util.check_eq (Live_sync.merge_pull_cursor metadata body)
         metadata)
    [
      "invalid";
      "[]";
      "null";
      "{}";
      "{\"type\":\"pull/error\",\"t\":9}";
      "{\"type\":\"pull/ok\",\"t\":\"9\"}";
    ]

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
    Test_util.case "pull cursor only changes on recognized success"
      pull_cursor_only_changes_on_recognized_success;
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
