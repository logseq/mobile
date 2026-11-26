module Ds = Datascript
module Runtime = Graph_runtime
module Session = Rpc_session
module Json = Yojson.Basic

let member = Json.Util.member
let graph_id = "outliner-perf"
let actor = 10
let fixture_token = "fixture.eyJzdWIiOiJiZWMwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMTAifQ.fixture"
let status = "logseq.property/status"
let status_ident name = status ^ "." ^ name
let uuid id = Printf.sprintf "bec00000-0000-4000-8000-%012d" id
let journal = 100
let today = uuid journal
let row page index = 1000 + (page * 100) + index
let block index = uuid (row 0 index)

let fixture () =
  let spec = Storage_codec.default_schema_attr in
  let indexed = {spec with Ds.indexed = true} in
  let ref_attr = {indexed with Ds.value_type = Some Ds.RefType} in
  let schema = [
    "block/uuid", {indexed with Ds.unique = Some Ds.Identity; value_type = Some Ds.UuidType};
    "db/ident", {indexed with Ds.unique = Some Ds.Identity; value_type = Some Ds.KeywordType};
    "block/page", ref_attr; "block/parent", ref_attr; "block/link", ref_attr;
    "block/tags", {ref_attr with Ds.cardinality = Ds.Many};
    "block/refs", {ref_attr with Ds.cardinality = Ds.Many};
    "block/journal-day", indexed; status, ref_attr; Created_by.property, ref_attr;
    Journal_task_dates.scheduled, indexed; Journal_task_dates.deadline, indexed;
  ] in
  let local = Dev_query.Date_time_util.journal_day_to_local_ms in
  let day = Cache_model.journal_day_for_ms (Session_types.now_ms ()) in
  let relative offset = Option.get (Dev_query.Date_time_util.journal_day_plus day offset) in
  let timestamp offset = Ds.Int64 (local (relative offset)) in
  let add id attr value = Ds.Add (Ds.Entity_id id, attr, value) in
  let entity id attrs = List.map (fun (attr, value) -> add id attr value)
    (("block/uuid", Ds.Uuid (uuid id)) :: attrs) in
  let text attr value = attr, Ds.String value in
  let ref_ attr id = attr, Ds.Ref id in
  let orders = Fractional_order.n_between None None 60 |> Result.get_ok |> Array.of_list in
  let choices = ["todo"; "doing"; "done"] in
  let definitions = entity actor [] @ entity 1 ["db/ident", Ds.Keyword "logseq.class/Task"] @
    List.concat (List.mapi (fun i name -> entity (2 + i)
      ["db/ident", Ds.Keyword (status_ident name); text "block/title" name]) choices) in
  let journals = List.concat (List.init 100 (fun page ->
    let page_id = journal + page in
    let page_day = relative (-page) in
    let title = Journal.day_title page_day in
    entity page_id [
      text "block/name" (String.lowercase_ascii title); text "block/title" title;
      "block/journal-day", Ds.Int64 (Int64.of_int page_day);
      "block/updated-at", timestamp (-page)
    ] @ List.concat (List.init (if page = 0 then 60 else 10) (fun i ->
      let id = row page i in
      let parent = if i = 4 then row page 3 else page_id in
      let task = page <> 0 || i >= 10 in
      let attrs = if not task then [] else [
        ref_ "block/tags" 1; ref_ status (2 + (i mod 3));
        (if i mod 2 = 0 then Journal_task_dates.scheduled else Journal_task_dates.deadline),
        timestamp (if i mod 3 = 1 || i mod 4 >= 2 then 2 else -2)
      ] in
      entity id ([
        text "block/title" (Printf.sprintf "Journal %d block %d" page i);
        text "block/order" orders.(i);
        ref_ "block/page" page_id; ref_ "block/parent" parent; ref_ Created_by.property actor;
        "block/created-at", timestamp (-page); "block/updated-at", timestamp (-page)
      ] @ attrs))))) in
  Ds.db_with (definitions @ journals) (Ds.empty_db ~schema ())

let call session method_ params =
  Session.call session (Json.to_string (`Assoc [
    "apiVersion", `Int 1; "method", `String method_; "params", `Assoc params]))

let dispatch session action payload =
  call session "dispatch" ["action", `String action; "payload", `String payload]

let event session kind fields =
  dispatch session "outlinerEvent" (Json.to_string (`Assoc (("type", `String kind) :: fields)))

let result raw =
  let response = Json.from_string raw in
  if member "ok" response <> `Bool true then failwith raw;
  member "result" response

let with_session ?show_journal_tasks ?show_notifications db f =
  let path = Filename.temp_file "outliner-workload" ".sqlite" in
  Fun.protect ~finally:(fun () ->
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [path; path ^ "-wal"; path ^ "-shm"; Graph_store.staging_path path])
    (fun () ->
      Graph_sqlite.prepare_staging path;
      let conn = Ds.conn_from_db db in
      let runtime = Runtime.create_base path 42 conn Runtime.default_options in
      let journal_tasks = Journal_task_dates.create_cache () in
      let apply_sync_event body =
        let ( let* ) = Result.bind in
        let* journal = Journal_sync.decode body in
        let* applied = Journal_sync.apply Result.ok conn (Runtime.state runtime).server_t journal in
        Runtime.rebase ~agenda_update:(journal_tasks, applied)
          ~changed_attributes:applied.changed_attributes
          runtime journal.t applied.operation_ids applied.changed_uuids;
        Ok () in
      let session = Session.create_session ~journal_tasks {Session.default_options with
        outliner_projection_limit = Some 32;
        show_journal_tasks;
        show_notifications;
        load_graph_catalog = Some (fun () -> Some {|{"graphs":[{"graph-id":"outliner-perf","graph-name":"Outliner benchmark","graph-e2ee?":false,"graph-ready-for-use?":true}]}|});
        sync_cursor = Some (fun () -> Some (Runtime.state runtime).server_t);
        apply_sync_event = Some apply_sync_event;
        graph_db = Some (fun () -> Some (Runtime.db runtime));
        graph_blocks = Some (fun () -> Some (Runtime.blocks runtime));
        graph_page_blocks = Some (fun uuid -> Some (Runtime.blocks_for_page runtime uuid));
        graph_sidebar_pages = Some (fun () -> Some (Runtime.sidebar_pages runtime));
        graph_tag_pages = Some (fun () -> Some (Runtime.tag_pages runtime));
        graph_node_destination = Some (Runtime.node_destination runtime);
        empty_journals = Some (fun () -> Runtime.empty_journals runtime);
        stage_operation = Some (Runtime.stage ~journal_tasks runtime);
        pending_operations = Some (fun () -> Runtime.pending_operations runtime);
        prepare_operation = Some (Runtime.prepare_sync runtime)
      } in
      ignore (result (dispatch session "configure"
        (Printf.sprintf {|{"baseUrl":"http://127.0.0.1:8787","graphId":"outliner-perf","token":"%s"}|} fixture_token)));
      f session)

let open_today session = dispatch session "selectPage" today
let open_journal session = call session "snapshot" []
let at kind index session = event session kind ["uuid", `String (block index)]
let tap session index = ignore (result (at "tapBlock" index session))
let type_text session = event session "textChanged"
  ["uuid", `String (block 2); "title", `String "Updated text"; "caretUTF16Offset", `Int 12]
let toolbar action index session = event session "blockToolbar"
  ["uuid", `String (block index); "action", `String action]
let enter session = event session "returnPressed" []
let save session = event session "saveEditing" []
let backspace session = event session "backspacePressed" ["selectionLength", `Int 0]
let toggle_task session = event session "setTaskStatus"
  ["uuid", `String (block 10); "statusIdent", `String (status_ident "done")]

let prepare session = ignore (result (open_today session))
let editing session = prepare session; tap session 2
let move_caret_to_start session =
  ignore (result (event session "caretMoved" ["caretUTF16Offset", `Int 0]))
let merging session =
  editing session;
  move_caret_to_start session
let saving session = editing session; ignore (result (type_text session))
let expand session = prepare session; ignore (result (at "toggleCollapsed" 3 session))

let external_task = uuid (row 1 0)
let tap_external_task session = event session "tapBlock" ["uuid", `String external_task]
let edit_external_task session = ignore (result (tap_external_task session))
let type_external_task session = event session "textChanged"
  ["uuid", `String external_task; "title", `String "Updated task"; "caretUTF16Offset", `Int 12]
let save_external_task session =
  edit_external_task session;
  ignore (result (type_external_task session))

let connected session =
  let opened = result (dispatch session "beginSyncTransport" "{}") in
  let generation = member "generation" (member "syncTransport" opened) in
  let transport fields = dispatch session "syncTransportEvent" (Json.to_string
    (`Assoc (["graphId", `String graph_id; "generation", generation] @ fields))) in
  ignore (result (transport ["type", `String "opened"]));
  transport

let receive_journal session =
  let transport = connected session in
  let open Dev_sync.Wire in
  let tx = Dev_sync.Transit_codec.to_string (Array [
    Array [Keyword "db/add"; Array [Keyword "block/uuid"; Uuid (block 2)];
      Keyword "block/title"; String "Remote edit"]
  ]) in
  let body = Json.to_string (`Assoc ["type", `String "pull/ok"; "t", `Int 43;
    "txs", `List [`Assoc ["t", `Int 43; "tx", `String tx]]]) in
  fun () -> transport ["type", `String "frame"; "body", `String body]

let confirm_pending session transport =
  let request = member "pendingSyncRequest" (result (dispatch session "beginPendingSync" "{}")) in
  let batch = Json.from_string (Json.Util.to_string (member "body" request)) in
  let before = Json.Util.to_int (member "t-before" batch) in
  let txs = Json.Util.to_list (member "txs" batch) in
  let entries = List.mapi (fun index tx -> `Assoc ["t", `Int (before + index + 1);
    "tx-id", member "tx-id" tx; "tx", member "tx" tx]) txs in
  let server_t = before + List.length entries in
  let body = Json.to_string (`Assoc ["type", `String "tx/batch/ok"; "t", `Int server_t;
    "t-before", `Int before; "txs", `List entries]) in
  let frame = transport ["type", `String "frame"; "body", `String body] in
  let commands = Json.Util.to_list (member "commands" (member "syncTransport" (result frame))) in
  let completion = List.find (fun command -> member "type" command = `String "pending-result") commands in
  let ack = dispatch session "completePendingSync" (Json.to_string
    (`Assoc ["id", member "id" completion; "status", `Int 200; "body", member "body" completion])) in
  assert (member "appliedServerT" (result ack) = `Int server_t);
  frame, ack

let repeat_enter session transport count =
  let rec repeat previous remaining =
    if remaining = 0 then []
    else
      let edit = enter session in
      let editing = member "uuid" (member "editing" (member "outlinerState" (result edit))) in
      assert (editing <> `Null && editing <> previous);
      let frame, ack = confirm_pending session transport in
      edit :: frame :: ack :: repeat editing (remaining - 1) in
  repeat (`String (block 2)) count

let external_task_status session = event session "setTaskStatus"
  ["uuid", `String external_task; "statusIdent", `String (status_ident "doing")]

let external_task_date session =
  let today = Cache_model.journal_day_for_ms (Session_types.now_ms ()) in
  let offset days = Option.get (Dev_query.Date_time_util.journal_day_plus today days) in
  let timestamp days = `Int (Int64.to_int (Dev_query.Date_time_util.journal_day_to_local_ms (offset days))) in
  dispatch session "nodeProperty" (Json.to_string (`Assoc ["action", `String "saveTaskDates";
    "targets", `List [`Assoc ["uuid", `String external_task; "scheduled", timestamp (-2)]];
    "changes", `Assoc ["scheduled", timestamp 3]]))

let scenarios = [
  "tap_external_task", (fun _ -> ()), tap_external_task;
  "type_external_task", edit_external_task, type_external_task;
  "save_external_task", save_external_task, save;
  "status_external_task", (fun _ -> ()), external_task_status;
  "date_external_task", (fun _ -> ()), external_task_date;
  "open_journal", (fun _ -> ()), open_journal;
  "open_today_page", (fun _ -> ()), open_today;
  "tap_to_edit", prepare, at "tapBlock" 2;
  "type", editing, type_text;
  "save", saving, save;
  "enter", editing, enter;
  "indent", prepare, toolbar "indent" 2;
  "outdent", prepare, toolbar "outdent" 4;
  "backspace_merge", merging, backspace;
  "move_up", prepare, toolbar "moveUp" 2;
  "move_down", prepare, toolbar "moveDown" 2;
  "toggle_task_status", prepare, toggle_task;
  "collapse", prepare, at "toggleCollapsed" 3;
  "expand", expand, at "toggleCollapsed" 3;
]
