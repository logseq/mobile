open Test_util
module J = Yojson.Basic
module U = Yojson.Basic.Util

let call session action fields = Rpc_test.dispatch_json session action (J.to_string (`Assoc fields))
let result value = Rpc_test.response_result value
let session () = Rpc_session.create_session Rpc_session.default_options

let download_plan_uses_one_shared_protocol () =
  let plan = result (call (session ()) "snapshotDownloadPlan" [
    "baseUrl", `String "https://sync.example.com/api/"; "graphId", `String "graph id"]) in
  check_eq (U.member "cursorURL" plan) `Null;
  check_eq (U.member "metadataURL" plan) (`String "https://sync.example.com/sync/graph%20id/snapshot/download")

let metadata_reconciles_cursor_schema_and_encoding () =
  let response metadata schema = call (session ()) "resolveSnapshotDownload" [
    "metadataBody", `String metadata; "graphSchemaVersion", schema] in
  List.iter (fun t ->
    let resolved = result (response
      (Printf.sprintf {|{"ok":true,"url":"/download/file","t":%d,"schema-version":"  "}|} t)
      (`String "65.33")) in
    let metadata = U.member "metadataBody" resolved |> U.to_string |> J.from_string in
    check_eq (U.member "t" metadata) (`Int t);
    check_eq (U.member "schema-version" metadata) (`String "65.33");
    check_eq (U.member "downloadURL" resolved) (`String "/download/file");
    check_eq (U.member "contentEncoding" resolved) (`String "identity")) [0; 42];
  let resolved = result (response
    {|{"ok":true,"url":"/file","t":42,"schema-version":"65.34","content-encoding":" GZIP "}|}
    (`String "65.33")) in
  let metadata = U.member "metadataBody" resolved |> U.to_string |> J.from_string in
  check_eq (U.member "schema-version" metadata) (`String "65.34");
  check_eq (U.member "contentEncoding" resolved) (`String "gzip");
  List.iter (fun metadata ->
    check_eq (U.member "ok" (response metadata `Null)) (`Bool false)) [
    {|{"ok":false,"url":"/file","t":42}|};
    {|{"ok":true,"url":"/file"}|};
    {|{"ok":true,"url":"/file","t":-1}|};
    {|{"ok":true,"url":"/file","t":1.5}|};
    {|{"ok":true,"url":"/file","t":"42"}|};
    {|{"ok":true,"url":"/file","t":null}|};
    {|{"ok":true,"url":"/file","t":42,"content-encoding":"br"}|};
    {|{"ok":true,"url":"","t":42}|};
    "invalid JSON"]

let bootstrap_reports_download_or_offline_failure () =
  let session = Rpc_test.plain_session () in
  let fields = ["graphId", `String "plain-1"; "activePath", `String "/missing/graph.sqlite";
    "checkpointPath", `String "/missing/sync.checkpoint"] in
  let decision = result (call session "bootstrapGraph" fields) in
  check_eq (U.member "kind" (U.member "graphBootstrap" decision)) (`String "download");
  check_eq (U.member "ok" (call session "bootstrapGraph" (("allowSnapshotDownload", `Bool false) :: fields))) (`Bool false);
  check_eq (U.member "ok" (call session "bootstrapGraph" (("graphId", `String "other") :: List.remove_assoc "graphId" fields))) (`Bool false)

let late_initial_download_cannot_switch_the_selected_graph () =
  let session = Rpc_test.plain_session () in
  let imported = call session "importSnapshot" ["graphId", `String "other";
    "activePath", `String "/tmp/other"; "checkpointPath", `String "/tmp/checkpoint";
    "metadataBody", `String "{}"; "downloadPath", `String "/tmp/download"] in
  check_eq (U.member "code" (U.member "error" imported)) (`String "graph_changed")

let locked_graph_defers_download_and_sync_to_unlock () =
  let session = Rpc_session.create_session { Rpc_session.default_options with
    load_graph_catalog = Some (fun () -> Some Rpc_test.encrypted_graph_catalog) } in
  ignore (Rpc_test.configure_encrypted_session session);
  ignore (Rpc_test.dispatch_json session "selectGraph" "encrypted-1");
  let plan = result (call session "bootstrapGraph" ["graphId", `String "encrypted-1";
    "activePath", `String "/missing/encrypted.sqlite"; "checkpointPath", `String "/missing/checkpoint"])
    |> U.member "graphBootstrap" in
  check_eq (U.member "kind" plan) (`String "locked");
  check_eq (U.member "syncAllowed" plan) (`Bool false)

let newer_bootstrap_rejects_an_older_download_of_the_same_graph () =
  let session = Rpc_test.plain_session () in
  let fields = ["graphId", `String "plain-1"; "activePath", `String "/missing/graph.sqlite";
    "checkpointPath", `String "/missing/checkpoint"] in
  let first = result (call session "bootstrapGraph" fields) |> U.member "graphBootstrap" in
  ignore (result (call session "bootstrapGraph" fields));
  let response = call session "importSnapshot" (("generation", U.member "generation" first) :: fields) in
  check_eq (U.member "code" (U.member "error" response)) (`String "graph_changed")

let cached_graph_activation_and_reuse_are_owned_by_the_core () =
  let active = Filename.temp_file "bootstrap" ".sqlite" in
  let checkpoint = Filename.temp_file "bootstrap" ".checkpoint" in
  Fun.protect ~finally:(fun () -> Sys.remove active; Sys.remove checkpoint) (fun () ->
    let opens = ref 0 in
    let model = Cache_model.create None in
    let session = Rpc_session.create_session { Rpc_session.default_options with
      load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
      open_graph = Some (fun _ -> incr opens; Ok ());
      model_for_graph = Some (fun _ -> model);
      sync_cursor = Some (fun () -> Some 42) } in
    ignore (Rpc_test.configure_plain_session session);
    let fields = ["graphId", `String "plain-1"; "activePath", `String active;
      "checkpointPath", `String checkpoint; "allowSnapshotDownload", `Bool false] in
    List.iter (fun _ ->
      let plan = result (call session "bootstrapGraph" fields) |> U.member "graphBootstrap" in
      check_eq (U.member "kind" plan) (`String "ready")) [1; 2];
    check_eq !opens 1)

let cases = [
  case "locked graph defers download and sync to unlock" locked_graph_defers_download_and_sync_to_unlock;
  case "newer bootstrap rejects an older download of the same graph" newer_bootstrap_rejects_an_older_download_of_the_same_graph;
  case "cached graph activation and reuse are owned by the core" cached_graph_activation_and_reuse_are_owned_by_the_core;
  case "download plan uses one shared protocol" download_plan_uses_one_shared_protocol;
  case "metadata reconciles cursor schema and encoding" metadata_reconciles_cursor_schema_and_encoding;
  case "bootstrap reports download or offline failure" bootstrap_reports_download_or_offline_failure;
  case "late initial download cannot switch the selected graph" late_initial_download_cannot_switch_the_selected_graph;
]
