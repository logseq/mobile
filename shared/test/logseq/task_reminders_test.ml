open Test_util

module Ds = Datascript
module Store = Task_reminders
module Session = Rpc_session
module Runtime = Graph_runtime
module Runtime_store = Graph_sqlite
module Graph_store = Graph_store
module Effects = Outliner_effects
module Outliner = Outliner_state
module Ops = Pending_ops
module Api = Api
module Model = Cache_model

let one = Storage_codec.default_schema_attr
let string = { one with Ds.value_type = Some Ds.StringType }
let uuid = { one with Ds.value_type = Some Ds.UuidType; unique = Some Ds.Identity }
let keyword = { one with Ds.value_type = Some Ds.KeywordType }
let unique_keyword = { keyword with Ds.unique = Some Ds.Identity }
let ref_ = { one with Ds.value_type = Some Ds.RefType }
let refs = { ref_ with Ds.cardinality = Ds.Many }
let schema = [
  "block/uuid", uuid; "db/ident", unique_keyword; "block/title", one; "block/page", ref_;
  "block/parent", ref_; "block/tags", refs; "logseq.property.class/extends", refs;
  "logseq.property/status", ref_; "logseq.property/deleted-at", one;
  "logseq.property/type", keyword; "logseq.property/default-value", ref_;
  "logseq.property/scheduled", one; "logseq.property/deadline", one;
  "logseq.property.repeat/repeated?", one; "logseq.property.repeat/repeated", one;
  "logseq.property.repeat/recur-frequency", one;
  "logseq.property.repeat/recur-unit", ref_; "logseq.property.repeat/repeat-type", ref_;
  "block/journal-day", one; "logseq.property/value", one]

let task_db () =
  let tx = [
    Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid "page");
    Ds.Add (Ds.Entity_id 1, "block/title", Ds.String "Source page");
    Ds.Add (Ds.Entity_id 2, "db/ident", Ds.Keyword "logseq.class/Task");
    Ds.Add (Ds.Entity_id 3, "db/ident", Ds.Keyword "user.class/Child-task");
    Ds.Add (Ds.Entity_id 3, "logseq.property.class/extends", Ds.Ref 2);
    Ds.Add (Ds.Entity_id 4, "db/ident", Ds.Keyword "logseq.property/scheduled");
    Ds.Add (Ds.Entity_id 4, "logseq.property/type", Ds.Keyword "datetime");
    Ds.Add (Ds.Entity_id 5, "db/ident", Ds.Keyword "logseq.property/deadline");
    Ds.Add (Ds.Entity_id 5, "logseq.property/type", Ds.Keyword "datetime");
    Ds.Add (Ds.Entity_id 6, "db/ident", Ds.Keyword "logseq.property/status");
    Ds.Add (Ds.Entity_id 7, "db/ident", Ds.Keyword "logseq.property/status.todo");
    Ds.Add (Ds.Entity_id 7, "block/uuid", Ds.Uuid "status-todo");
    Ds.Add (Ds.Entity_id 7, "block/title", Ds.String "TODO");
    Ds.Add (Ds.Entity_id 6, "logseq.property/default-value", Ds.Ref 7);
    Ds.Add (Ds.Entity_id 10, "block/uuid", Ds.Uuid "ancestor");
    Ds.Add (Ds.Entity_id 10, "block/parent", Ds.Ref 1);
    Ds.Add (Ds.Entity_id 10, "logseq.property/deleted-at", Ds.Int64 1L);
    Ds.Add (Ds.Entity_id 11, "block/uuid", Ds.Uuid "status-done");
    Ds.Add (Ds.Entity_id 11, "db/ident", Ds.Keyword "logseq.property/status.done");
    Ds.Add (Ds.Entity_id 12, "db/ident", Ds.Keyword "logseq.property/empty-placeholder");
    Ds.Add (Ds.Entity_id 14, "db/ident", Ds.Keyword "logseq.property/status.doing");
    Ds.Add (Ds.Entity_id 14, "block/uuid", Ds.Uuid "status-doing");
    Ds.Add (Ds.Entity_id 15, "block/title", Ds.Int64 1794484800000L);
    Ds.Add (Ds.Entity_id 15, "logseq.property/value", Ds.String "malformed lower-priority value");
    Ds.Add (Ds.Entity_id 16, "logseq.property/value", Ds.Int64 1794484800000L);
    Ds.Add (Ds.Entity_id 17, "block/title", Ds.String "malformed higher-priority title");
    Ds.Add (Ds.Entity_id 17, "logseq.property/value", Ds.Int64 1794484800000L);
  ] in
  let task n attrs =
    [ Ds.Add (Ds.Entity_id n, "block/uuid", Ds.Uuid ("task-" ^ string_of_int n));
      Ds.Add (Ds.Entity_id n, "block/title", Ds.String ("Task " ^ string_of_int n));
      Ds.Add (Ds.Entity_id n, "block/page", Ds.Ref 1);
      Ds.Add (Ds.Entity_id n, "block/parent", Ds.Ref 1);
      Ds.Add (Ds.Entity_id n, "block/tags", Ds.Ref 3) ] @ attrs in
  let tx = tx @ List.concat_map (fun n -> task n [Ds.Add (Ds.Entity_id n, "logseq.property/scheduled", Ds.Int64 (Int64.of_int n))]) (List.init 40 (fun i -> i + 100))
    @ [Ds.Add (Ds.Entity_id 100, "block/tags", Ds.Ref 2)]
    @ task 200 [Ds.Add (Ds.Entity_id 200, "logseq.property/deadline", Ds.Int64 0L)]
    @ task 201 [Ds.Add (Ds.Entity_id 201, "logseq.property/scheduled", Ds.Int64 0L); Ds.Add (Ds.Entity_id 201, "logseq.property/deadline", Ds.Int64 8L)]
    @ task 202 [Ds.Add (Ds.Entity_id 202, "logseq.property/scheduled", Ds.Int64 1794484800000L)]
    @ task 203 [Ds.Add (Ds.Entity_id 203, "block/parent", Ds.Ref 10); Ds.Add (Ds.Entity_id 203, "logseq.property/scheduled", Ds.Int64 9L)]
    @ task 204 [Ds.Add (Ds.Entity_id 204, "logseq.property/status", Ds.Ref 11); Ds.Add (Ds.Entity_id 204, "logseq.property/scheduled", Ds.Int64 9L)]
    @ task 205 [Ds.Add (Ds.Entity_id 205, "logseq.property.repeat/repeated?", Ds.Bool false); Ds.Add (Ds.Entity_id 205, "logseq.property.repeat/recur-frequency", Ds.String "weekly"); Ds.Add (Ds.Entity_id 205, "logseq.property/scheduled", Ds.Int64 9L)]
    @ task 206 [Ds.Add (Ds.Entity_id 206, "logseq.property.repeat/repeated?", Ds.Bool true); Ds.Add (Ds.Entity_id 206, "logseq.property.repeat/recur-frequency", Ds.String "daily"); Ds.Add (Ds.Entity_id 206, "logseq.property/scheduled", Ds.Int64 9L)]
    @ task 207 [Ds.Add (Ds.Entity_id 207, "logseq.property/scheduled", Ds.Int64 1796083200000L)]
    @ task 208 [Ds.Add (Ds.Entity_id 208, "logseq.property/scheduled", Ds.Ref 12); Ds.Add (Ds.Entity_id 208, "logseq.property/deadline", Ds.Int64 10L)]
    @ task 209 [Ds.Add (Ds.Entity_id 209, "logseq.property/scheduled", Ds.Ref 15)]
    @ task 210 [Ds.Add (Ds.Entity_id 210, "logseq.property/scheduled", Ds.Ref 16)]
    @ task 211 [Ds.Add (Ds.Entity_id 211, "logseq.property/scheduled", Ds.Ref 17); Ds.Add (Ds.Entity_id 211, "logseq.property/deadline", Ds.Int64 11L)]
    @ task 212 [Ds.Add (Ds.Entity_id 212, "logseq.property/scheduled", Ds.String "malformed"); Ds.Add (Ds.Entity_id 212, "logseq.property/deadline", Ds.Int64 12L)]
    @ task 213 [Ds.Add (Ds.Entity_id 213, "logseq.property.repeat/repeated", Ds.Bool false); Ds.Add (Ds.Entity_id 213, "logseq.property/scheduled", Ds.Int64 13L)]
    @ task 214 [Ds.Add (Ds.Entity_id 214, "logseq.property.repeat/repeated", Ds.Bool false); Ds.Add (Ds.Entity_id 214, "logseq.property.repeat/repeated?", Ds.Bool true); Ds.Add (Ds.Entity_id 214, "logseq.property/scheduled", Ds.Int64 14L)] in
  Ds.db_with tx (Ds.empty_db ~schema ())

let full_inventory_includes_offscreen_and_excludes_deleted_done_and_repeat () =
  let tasks = Store.inventory (task_db ()) in
  check_eq (List.length tasks) 48;
  check (List.exists (fun task -> task.Store.uuid = "task-139") tasks);
  check_eq ~msg:"Task and subclass tags produce one reminder"
    (List.length (List.filter (fun task -> task.Store.uuid = "task-100") tasks)) 1;
  check (not (List.exists (fun task -> List.mem task.Store.uuid ["task-203"; "task-204"; "task-206"]) tasks));
  let midnight = List.find (fun task -> task.Store.uuid = "task-201") tasks in
  check_eq midnight.Store.temporal (Store.Datetime 0L);
  check (List.exists (fun task -> task.Store.uuid = "task-205") tasks);
  check (not (List.exists (fun task -> List.mem task.Store.uuid ["task-211"; "task-212"; "task-213"; "task-214"]) tasks));
  check_eq (List.find (fun task -> task.Store.uuid = "task-202") tasks).Store.temporal (Store.Datetime 1794484800000L);
  check_eq (List.find (fun task -> task.Store.uuid = "task-207") tasks).Store.temporal (Store.Datetime 1796083200000L);
  check_eq (List.find (fun task -> task.Store.uuid = "task-208") tasks).Store.temporal (Store.Datetime 10L);
  check_eq (List.find (fun task -> task.Store.uuid = "task-209") tasks).Store.temporal (Store.Datetime 1794484800000L);
  check_eq (List.find (fun task -> task.Store.uuid = "task-210") tasks).Store.temporal (Store.Datetime 1794484800000L)

let schema_typed_date_remains_date_only () =
  let db = task_db () in
  let date_db = Ds.db_with [
    Ds.Add (Ds.Entity_id 4, "logseq.property/type", Ds.Keyword "date");
    Ds.Add (Ds.Entity_id 9, "block/journal-day", Ds.Int64 20261112L);
    Ds.Add (Ds.Entity_id 220, "block/uuid", Ds.Uuid "task-date");
    Ds.Add (Ds.Entity_id 220, "block/title", Ds.String "Date-only task");
    Ds.Add (Ds.Entity_id 220, "block/page", Ds.Ref 1);
    Ds.Add (Ds.Entity_id 220, "block/parent", Ds.Ref 1);
    Ds.Add (Ds.Entity_id 220, "block/tags", Ds.Ref 3);
    Ds.Add (Ds.Entity_id 220, "logseq.property/scheduled", Ds.Ref 9)] db in
  let tasks = Store.inventory date_db in
  check_eq (List.find (fun task -> task.Store.uuid = "task-date") tasks).Store.temporal (Store.Date 20261112)

let rpc_fixture_session ?(db = task_db ()) ?(open_graph = fun _ -> Ok ()) () =
  let session = Session.create_session { Session.default_options with
    load_graph_catalog = Some (fun () -> Some "{\"graphs\":[{\"graph-id\":\"sample\",\"graph-name\":\"Sample\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}");
    graph_db = Some (fun () -> Some db);
    sync_cursor = Some (fun () -> Some 42);
    open_graph = Some open_graph;
    model_for_graph = Some (fun _ -> Model.create None) } in
  ignore (Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "configure"; "payload", `String "{\"baseUrl\":\"http://localhost\",\"graphId\":\"sample\",\"token\":\"synthetic\"}"]] )));
  let s = Session.state session in
  session.state := {s with active_graph_id = Some "sample";
    task_reminder_ready_generation = Some s.task_reminder_generation;
    task_reminder_activation_required = false};
  session

let dispatch_task_reminders session =
  Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "taskReminders"]]))

let bootstrap_graph session =
  Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "bootstrapGraph";
      "payload", `String "{\"graphId\":\"sample\",\"allowSnapshotDownload\":false}"]] ))

let select_sample_graph session =
  Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "selectGraph"; "payload", `String "sample"]]))

let open_graph_from_paths session active_path checkpoint_path =
  let payload = Yojson.Basic.to_string (`Assoc ["graphId", `String "sample";
    "activePath", `String active_path; "checkpointPath", `String checkpoint_path]) in
  Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "openGraph"; "payload", `String payload]]))

let rpc_fixture_json () = dispatch_task_reminders (rpc_fixture_session ())

let write_rpc_fixture path =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel (rpc_fixture_json ()); output_char channel '\n')

let rpc_date_fixture_json () =
  let db = Ds.db_with [
    Ds.Add (Ds.Entity_id 4, "logseq.property/type", Ds.Keyword "date");
    Ds.Add (Ds.Entity_id 9, "block/journal-day", Ds.Int64 20261112L);
    Ds.Add (Ds.Entity_id 220, "block/uuid", Ds.Uuid "task-date");
    Ds.Add (Ds.Entity_id 220, "block/title", Ds.String "Date-only task");
    Ds.Add (Ds.Entity_id 220, "block/page", Ds.Ref 1);
    Ds.Add (Ds.Entity_id 220, "block/parent", Ds.Ref 1);
    Ds.Add (Ds.Entity_id 220, "block/tags", Ds.Ref 3);
    Ds.Add (Ds.Entity_id 220, "logseq.property/scheduled", Ds.Ref 9)] (task_db ()) in
  dispatch_task_reminders (rpc_fixture_session ~db ())

let write_rpc_date_fixture path =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel (rpc_date_fixture_json ()); output_char channel '\n')

let rpc_is_complete_and_config_change_invalidates_inventory () =
  let session = rpc_fixture_session () in
  let response = Yojson.Basic.from_string (dispatch_task_reminders session) in
  let result = Yojson.Basic.Util.member "result" response in
  check (Yojson.Basic.Util.member "ready" result = `Bool true);
  check (Yojson.Basic.Util.member "complete" result = `Bool true);
  check_eq (List.length (Yojson.Basic.Util.to_list (Yojson.Basic.Util.member "tasks" result))) 48;
  ignore (Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "configure"; "payload", `String "{\"baseUrl\":\"http://localhost\",\"graphId\":\"sample\",\"token\":\"synthetic\"}"]] )));
  let warm = Yojson.Basic.from_string (bootstrap_graph session) in
  check (Yojson.Basic.Util.member "ok" warm = `Bool true);
  check (Yojson.Basic.Util.member "ready" (Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result") = `Bool true);
  ignore (Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "configure"; "payload", `String "{\"baseUrl\":\"http://other-host\",\"graphId\":\"sample\",\"token\":\"different-synthetic\"}"]] )));
  (* The reminder fence cannot change the normal warm-bootstrap decision. The
     existing graph remains usable, but the changed provider is not trusted by
     reminders until the ordinary graph-open/import path activates it. *)
  check (Yojson.Basic.Util.member "ok" (Yojson.Basic.from_string (select_sample_graph session)) = `Bool true);
  check (Yojson.Basic.Util.member "ok" (Yojson.Basic.from_string (bootstrap_graph session)) = `Bool true);
  let stale = Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result" in
  check (Yojson.Basic.Util.member "ready" stale = `Bool false);
  check_eq (Yojson.Basic.Util.to_list (Yojson.Basic.Util.member "tasks" stale)) [];
  let active_path = Filename.temp_file "reminder-active" ".sqlite" in
  let checkpoint_path = Filename.temp_file "reminder-checkpoint" ".sqlite" in
  Fun.protect ~finally:(fun () -> List.iter (fun path -> if Sys.file_exists path then Sys.remove path) [active_path; checkpoint_path])
    (fun () ->
      let activated = Yojson.Basic.from_string (open_graph_from_paths session active_path checkpoint_path) in
      check (Yojson.Basic.Util.member "ok" activated = `Bool true);
      let ready = Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result" in
      check (Yojson.Basic.Util.member "ready" ready = `Bool true);
      check (Yojson.Basic.Util.member "complete" ready = `Bool true);
      ignore (Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
        "params", `Assoc ["action", `String "configure"; "payload", `String "{\"baseUrl\":\"http://other-host\",\"graphId\":\"sample\",\"token\":\"rotated-synthetic\"}"]] )));
      let token_refresh_stale = Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result" in
      check (Yojson.Basic.Util.member "ready" token_refresh_stale = `Bool false);
      let refreshed = Yojson.Basic.from_string (bootstrap_graph session) in
      check (Yojson.Basic.Util.member "ok" refreshed = `Bool true);
      let token_refresh_ready = Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result" in
      check (Yojson.Basic.Util.member "ready" token_refresh_ready = `Bool true))

let warm_bootstrap_preserves_navigation_and_editor_on_token_refresh () =
  let opened = ref 0 in
  let session = rpc_fixture_session ~open_graph:(fun _ -> incr opened; Ok ()) () in
  let page : Model.entity_summary = {uuid = "page"; title = "Source page"} in
  let draft : Outliner.editor_draft = {uuid = "task-100"; content_uuid = "task-100";
    expected_title = "Task 100"; title = "Unsaved task text"; caret = 7} in
  let editor = {Outliner.empty with editing = Some draft; zoomed = ["task-100"]} in
  let route : Session_types.node_route = {uuid = "task-100"; is_tag = false; is_property = false;
    page; scroll_target = None; zoom_to_block = true; related_blocks = []; state = editor} in
  let before = Session.state session in
  session.state := {before with node_routes = [route]; outliner_state = editor;
    selected_sidebar_page = Some page};
  let check_warm token =
    let payload = Yojson.Basic.to_string (`Assoc ["baseUrl", `String "http://localhost";
      "graphId", `String "sample"; "token", `String token]) in
    ignore (Session.call session (Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1;
      "method", `String "dispatch"; "params", `Assoc ["action", `String "configure";
        "payload", `String payload]])));
    if token <> "synthetic" then
      check (Yojson.Basic.Util.member "ready"
        (Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result") = `Bool false);
    let response = Yojson.Basic.from_string (bootstrap_graph session) in
    check (Yojson.Basic.Util.member "ok" response = `Bool true);
    check_eq (Yojson.Basic.Util.member "kind"
      (response |> Yojson.Basic.Util.member "result" |> Yojson.Basic.Util.member "graphBootstrap")) (`String "ready");
    check_eq ~msg:"warm bootstrap never reopens the active graph" !opened 0;
    let after = Session.state session in
    check ~msg:"warm activation preserves the existing graph model" (after.model == before.model);
    check_eq after.node_routes [route];
    check_eq after.outliner_state editor;
    check_eq after.selected_sidebar_page (Some page);
    check_eq (Session_types.projection_server_t session) (Some 42);
    let inventory = Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result" in
    check (Yojson.Basic.Util.member "ready" inventory = `Bool true);
    check_eq (List.length (Yojson.Basic.Util.to_list (Yojson.Basic.Util.member "tasks" inventory))) 48
  in
  check_warm "synthetic";
  check_warm "rotated-synthetic";
  check (Yojson.Basic.Util.member "ok" (Yojson.Basic.from_string (select_sample_graph session)) = `Bool true);
  let selected = Session.state session in
  (* Explicit selection keeps its existing navigation reset. Warm activation
     afterward must not perform an additional graph reopen/reset. *)
  check_eq selected.node_routes [];
  check_eq selected.selected_sidebar_page None;
  check_eq (Outliner.editing_uuid selected.outliner_state) None;
  check (Yojson.Basic.Util.member "ready"
    (Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result") = `Bool false);
  check (Yojson.Basic.Util.member "ok" (Yojson.Basic.from_string (bootstrap_graph session)) = `Bool true);
  let reactivated = Session.state session in
  check_eq ~msg:"reselecting the active graph never reopens storage" !opened 0;
  check (reactivated.model == selected.model);
  check_eq reactivated.node_routes selected.node_routes;
  check_eq reactivated.outliner_state selected.outliner_state;
  check_eq (Session_types.projection_server_t session) (Some 42);
  check (Yojson.Basic.Util.member "ready"
    (Yojson.Basic.from_string (dispatch_task_reminders session) |> Yojson.Basic.Util.member "result") = `Bool true)

let with_task_runtime ?(db = task_db ()) f =
  let path = Filename.temp_file "task-reminder-runtime" ".sqlite" in
  try
    Runtime_store.prepare_staging path;
    let runtime = Runtime.create path 42 (Ds.conn_from_db db) Runtime.default_options in
    f runtime;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [path; Graph_store.staging_path path]
  with error ->
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [path; Graph_store.staging_path path];
    raise error

let runtime_rpc_session runtime =
  let session = Session.create_session {Session.default_options with graph_db = Some (fun () -> Some (Runtime.db runtime))} in
  session.state := {(Session.state session) with
    config = Some {Api.base_url = "http://localhost"; graph_id = "sample"; graph_name = Some "Sample"; token = "synthetic"};
    available_graphs = [{Api.id = "sample"; name = "Sample"; schema_version = None; role = None; e2ee = false; ready = true}];
    active_graph_id = Some "sample"; task_reminder_generation = 1;
    task_reminder_ready_generation = Some 1; task_reminder_activation_required = false};
  session

let rpc_tasks session =
  let result = dispatch_task_reminders session |> Yojson.Basic.from_string |> Yojson.Basic.Util.member "result" in
  check (Yojson.Basic.Util.member "ready" result = `Bool true);
  Yojson.Basic.Util.to_list (Yojson.Basic.Util.member "tasks" result)

let contains_task tasks uuid = List.exists (fun task -> Yojson.Basic.Util.member "uuid" task = `String uuid) tasks

let stage_outliner_command runtime uuid command =
  let db = Runtime.db runtime in
  let eid = Option.get (Ds.entid db "block/uuid" (Ds.Uuid uuid)) in
  let block = Option.get (Graph_read.block (fun text -> Ok text) db eid) in
  let context = Outliner.context ~graph_id:"sample" ~db [block] [] [] in
  match Effects.interpret 42 (fun () -> 100) (fun () -> "reminder-status") context [command] with
  | Error message -> failwith message
  | Ok {Effects.operations = [operation]; _} -> (match Runtime.stage runtime operation with Ok () -> () | Error message -> failwith message)
  | Ok _ -> failwith "Expected one staged status operation"

let projected_rpc_tracks_runtime_status_and_temporal_edits () = with_task_runtime (fun runtime ->
  let session = runtime_rpc_session runtime in
  check (contains_task (rpc_tasks session) "task-100");
  let complete = Outliner.Set_task_status_value {Outliner.status_uuid = "task-100";
    status = Ops.Ref_ident "logseq.property/status.done"} in
  stage_outliner_command runtime "task-100" complete;
  check (not (contains_task (rpc_tasks session) "task-100")));
  let done_db = Ds.db_with [Ds.Add (Ds.Entity_id 100, "logseq.property/status", Ds.Ref 11)] (task_db ()) in
  with_task_runtime ~db:done_db (fun runtime ->
  let session = runtime_rpc_session runtime in
  let reopen = Outliner.Set_task_status_value {Outliner.status_uuid = "task-100";
    status = Ops.Ref_ident "logseq.property/status.todo"} in
  stage_outliner_command runtime "task-100" reopen;
  check (contains_task (rpc_tasks session) "task-100");
  let edit = Runtime.queued_operation runtime "reminder-date-edit" (Ops.Set_property {
    uuid = "task-100"; attr = "logseq.property/scheduled";
    expected = Some (Ops.Int_value 100); value = Some (Ops.Instant_value 1794484800000)}) in
  check_ok (Runtime.stage runtime edit);
  let edited = List.find (fun task -> Yojson.Basic.Util.member "uuid" task = `String "task-100") (rpc_tasks session) in
  check (Yojson.Basic.Util.member "temporal" edited = `Assoc ["kind", `String "datetime"; "timestampMs", `Int 1794484800000]))

let cases = [
  "full inventory and eligibility", `Quick, full_inventory_includes_offscreen_and_excludes_deleted_done_and_repeat;
  "schema typed date", `Quick, schema_typed_date_remains_date_only;
  "RPC and scope invalidation", `Quick, rpc_is_complete_and_config_change_invalidates_inventory;
  "warm bootstrap preserves navigation on token refresh", `Quick, warm_bootstrap_preserves_navigation_and_editor_on_token_refresh;
  "runtime-backed RPC inventory", `Quick, projected_rpc_tracks_runtime_status_and_temporal_edits]
