module Ds = Datascript
module Runtime = Graph_runtime
module Session = Rpc_session
module Json = Yojson.Basic

let member = Json.Util.member
let graph_id = "outliner-perf"
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
    "block/journal-day", indexed; status, ref_attr;
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
  let definitions = entity 1 ["db/ident", Ds.Keyword "logseq.class/Task"] @
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
        ref_ "block/page" page_id; ref_ "block/parent" parent;
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

let with_session db f =
  let path = Filename.temp_file "outliner-workload" ".sqlite" in
  Fun.protect ~finally:(fun () ->
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
      [path; path ^ "-wal"; path ^ "-shm"; Graph_store.staging_path path])
    (fun () ->
      Graph_sqlite.prepare_staging path;
      let runtime = Runtime.create_base path 42 (Ds.conn_from_db db) Runtime.default_options in
      let session = Session.create_session {Session.default_options with
        outliner_projection_limit = Some 32;
        load_graph_catalog = Some (fun () -> Some {|{"graphs":[{"graph-id":"outliner-perf","graph-name":"Outliner benchmark","graph-e2ee?":false,"graph-ready-for-use?":true}]}|});
        sync_cursor = Some (fun () -> Some 42);
        graph_db = Some (fun () -> Some (Runtime.db runtime));
        graph_blocks = Some (fun () -> Some (Runtime.blocks runtime));
        graph_page_blocks = Some (fun uuid -> Some (Runtime.blocks_for_page runtime uuid));
        graph_sidebar_pages = Some (fun () -> Some (Runtime.sidebar_pages runtime));
        graph_tag_pages = Some (fun () -> Some (Runtime.tag_pages runtime));
        graph_node_destination = Some (Runtime.node_destination runtime);
        empty_journals = Some (fun () -> Runtime.empty_journals runtime);
        stage_operation = Some (Runtime.stage runtime);
        pending_operations = Some (fun () -> Runtime.pending_operations runtime);
        prepare_operation = Some (Runtime.prepare_sync runtime)
      } in
      ignore (result (dispatch session "configure"
        {|{"baseUrl":"http://127.0.0.1:8787","graphId":"outliner-perf","token":"fixture"}|}));
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

let scenarios = [
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
