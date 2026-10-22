open Test_util
module D = Datascript
module J = Yojson.Basic
module R = Result_view_test
module Q = Query_block_test
let member = Q.member
let format_attr = "logseq.property.journal/title-format"
let journal_class db = Option.get (D.entid db "db/ident" (D.Keyword "logseq.class/Journal"))
let stored_format runtime = Graph_read.value (Graph_runtime.db runtime) (journal_class (Graph_runtime.db runtime)) format_attr
let set_format ?(graph = "plain-1") session format = Rpc_test.dispatch_json session "setJournalTitleFormat"
  (J.to_string (`Assoc ["graphId", `String graph; "format", `String format]))
let success response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true)
let stored_title db uuid =
  let id = Option.get (D.entid db "block/uuid" (D.Uuid uuid)) in
  match D.Db.datoms db D.Eavt ~e:id ~a:"block/title" () |> Seq.uncons with
  | Some (d, _) -> d.D.v | None -> D.Nil
let display_title db uuid =
  let id = Option.get (D.entid db "block/uuid" (D.Uuid uuid)) in
  Option.map (fun (node : Cache_model.entity_summary) -> node.title) (Graph_read.entity_summary (fun s -> Ok s) db id)

let existing_journals_reformat_without_identity_changes () = R.with_runtime (fun session runtime _ ->
  success (Rpc_test.dispatch_json session "ensureJournal" "20261023");
  let uuid = Rpc_wire.journal_page_uuid 20261023 in
  let raw = stored_title (Graph_runtime.db runtime) uuid in
  let response = set_format session "yyyy-MM-dd" in success response;
  check_eq ~msg:"the preference is the master's graph property" (stored_format runtime) (Some (D.String "yyyy-MM-dd"));
  check_eq ~msg:"changing display format never renames or duplicates stored journals" (stored_title (Graph_runtime.db runtime) uuid) raw;
  check_eq ~msg:"existing journal objects read through the chosen format" (display_title (Graph_runtime.db runtime) uuid) (Some "2026-10-23");
  check_eq ~msg:"settings receive the graph preference" (member "journalTitleFormat" (member "result" response)) (`String "yyyy-MM-dd");
  success (set_format session "yyyy年MM月dd日");
  check_eq (display_title (Graph_runtime.db runtime) uuid) (Some "2026年10月23日"))

let new_captures_and_restart_keep_the_graph_format () = R.with_runtime (fun session runtime conn ->
  success (set_format session "yyyy-MM-dd");
  let now = 1792719000000 in
  let day = Cache_model.journal_day_for_ms now in
  let expected = Printf.sprintf "%04d-%02d-%02d" (day / 10000) (day / 100 mod 100) (day mod 100) in
  let uuid = "82000000-0000-4000-8000-000000000001" in
  success (Rpc_test.dispatch_json session "send" (J.to_string (`Assoc ["uuid", `String uuid; "text", `String "Format capture"; "now", `Int now])));
  let page = Rpc_wire.journal_page_uuid day in
  check_eq ~msg:"new journal creation uses the same preference" (stored_title (Graph_runtime.db runtime) page) (D.String expected);
  check_eq (Editor_command_test.value runtime uuid "block/title") (Some (D.String "Format capture"));
  let restored = Graph_runtime.create runtime.path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
  check_eq ~msg:"the preference survives pending-log restart" (stored_format restored) (Some (D.String "yyyy-MM-dd"));
  check_eq (display_title (Graph_runtime.db restored) page) (Some expected);
  Composer_tag_test.sync_all runtime conn;
  check_eq ~msg:"confirmed sync retains the graph property" (stored_format runtime) (Some (D.String "yyyy-MM-dd")))

let property_values_and_reference_labels_share_the_format () = R.with_runtime (fun session runtime _ ->
  success (set_format session "dd-MM-yyyy");
  let db = Graph_runtime.db runtime in
  let property = Result_view.property_json db ~owner:Q.alpha ~attr:R.due ~encode_block:(fun _ -> `Null) in
  check_eq ~msg:"date property labels follow the graph preference" (member "text" property) (`String "01-10-2026");
  check_eq ~msg:"native day-picker wire values remain calendar dates" (member "editorValue" property) (`String "2026-10-01");
  let title = Graph_read.display_title (fun s -> Ok s) db ("[[" ^ R.day_a ^ "]]") in
  check ~msg:"journal references display the preferred title" (String_kit.index_of ~sub:"01-10-2026" ~start:0 title <> None);
  check ~msg:"journal reference labels never show UUIDs" (String_kit.index_of ~sub:R.day_a ~start:0 title = None))

let invalid_and_stale_changes_never_write () = R.with_runtime (fun session runtime _ ->
  let before = stored_format runtime in
  List.iter (fun (graph, format) ->
    let pending = Graph_runtime.pending_operations runtime in
    let result = set_format ~graph session format in
    check_eq ~msg:"reject unsupported or stale graph preferences" (member "ok" result) (`Bool false);
    check_eq (Graph_runtime.pending_operations runtime) pending;
    check_eq (stored_format runtime) before)
    ["other-graph", "yyyy-MM-dd"; "plain-1", ""; "plain-1", "Unsupported"; "plain-1", "yyyy-MM"])

let all_journal_creation_paths_use_the_preference () = R.with_runtime (fun session runtime conn ->
  success (set_format session "yyyy-MM-dd");
  success (Rpc_test.dispatch_json session "ensureJournal" "20261102");
  check_eq (stored_title (Graph_runtime.db runtime) (Rpc_wire.journal_page_uuid 20261102)) (D.String "2026-11-02");
  let response = Rpc_test.dispatch_json session "nodeProperty" (J.to_string (`Assoc [
    "blockUuid", `String Q.alpha;
    "attr", `String R.due; "value", `String "2026-11-03";
    "expected", member "raw" (Result_view.property_json (Graph_runtime.db runtime) ~owner:Q.alpha ~attr:R.due ~encode_block:(fun _ -> `Null))])) in
  success response;
  let db = Graph_runtime.db runtime in
  let page = Option.get (Graph_read.journal_page_uuid db 20261103) in
  check_eq (stored_title db page) (D.String "2026-11-03");
  Composer_tag_test.sync_all runtime conn;
  let restored = Graph_runtime.create runtime.path (Graph_runtime.state runtime).server_t conn {Graph_runtime.default_options with auto_create_today = true} in
  let day = Cache_model.journal_day_for_ms (int_of_float (Unix.gettimeofday () *. 1000.)) in
  let page = Option.get (Graph_read.journal_page_uuid (Graph_runtime.db restored) day) in
  check_eq ~msg:"automatic today creation uses the graph preference" (display_title (Graph_runtime.db restored) page)
    (Some (Printf.sprintf "%04d-%02d-%02d" (day / 10000) (day / 100 mod 100) (day mod 100))))

let failed_storage_keeps_the_previous_graph_preference () = R.with_runtime (fun _ runtime _ ->
  let before = stored_format runtime in
  let session = Rpc_session.create_session {Rpc_session.default_options with
    load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
    graph_db = Some (fun () -> Some (Graph_runtime.db runtime)); sync_cursor = Some (fun () -> Some 42);
    prepare_operation = Some (Graph_runtime.prepare_sync runtime);
    stage_operation = Some (fun _ -> Error "Storage unavailable")} |> Rpc_test.configure_plain_session in
  let response = set_format session "yyyy-MM-dd" in
  check_eq (member "ok" response) (`Bool false);
  check ~msg:"date-format failures report the actual storage error"
    (String_kit.index_of ~sub:"Storage unavailable" ~start:0 (J.to_string response) <> None);
  check_eq (stored_format runtime) before)

let settings_share_native_date_format_choices () =
  List.iter (fun backend -> R.with_runtime (fun session _ _ ->
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      App_test.send app Model.OpenSettings; App_test.flush app;
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      check ~msg:"both hosts expose an editable date-format preference" (find "picker.settings.date-format" <> -1);
      let option = find "settings.date-format.option.yyyy-MM-dd" in
      check ~msg:"format choices use the shared native menu" (option <> -1);
      App_test.dispatch app (if App_test.node host option = Some Lui_protocol.Radio then Lui_protocol.Change option else Lui_protocol.Press option); App_test.flush app;
      let effects = (App.model app).pending_effects |> List.map (fun eff -> J.from_string (Native_bridge.encode_effect eff)) in
      let mutation = List.find_opt (fun eff -> member "kind" eff = `String "set-journal-title-format") effects in
      check ~msg:"choosing a date format uses the graph mutation boundary" (mutation <> None);
      let payload = J.from_string (R.text (member "text" (Option.get mutation))) in
      check_eq (member "graphId" payload) (`String "plain-1");
      check_eq (member "format" payload) (`String "yyyy-MM-dd")))) [App_test.ios_backend; App_test.kotlin_backend]

let open_destinations_refresh_without_reopening () = R.with_runtime (fun _ runtime _ ->
  let day = 20261023 in
  let uuid = Rpc_wire.journal_page_uuid day in
  let session = Rpc_session.create_session {Rpc_session.default_options with
    load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
    graph_db = Some (fun () -> Some (Graph_runtime.db runtime));
    sync_cursor = Some (fun () -> Some (Graph_runtime.state runtime).server_t);
    stage_operation = Some (Graph_runtime.stage runtime); prepare_operation = Some (Graph_runtime.prepare_sync runtime);
    graph_node_destination = Some (fun uuid -> Graph_read.node_destination (fun s -> Ok s) (Graph_runtime.db runtime) uuid);
    graph_sidebar_pages = Some (fun () -> Some {Graph_read.favorites = [];
      recent_pages = Option.to_list (Option.bind (D.entid (Graph_runtime.db runtime) "block/uuid" (D.Uuid uuid))
        (Graph_read.entity_summary (fun s -> Ok s) (Graph_runtime.db runtime)))});
    graph_page_blocks = Some (fun uuid -> Some (Graph_runtime.blocks_for_page runtime uuid));
    graph_blocks = Some (fun () -> Some (Graph_runtime.blocks_for_page runtime uuid))}
    |> Rpc_test.configure_plain_session in
  success (Rpc_test.dispatch_json session "ensureJournal" (string_of_int day));
  success (Rpc_test.dispatch_json session "selectPage" uuid);
  success (Rpc_test.dispatch_json session "openNode" (J.to_string (`Assoc ["uuid", `String uuid])));
  let response = member "result" (set_format session "dd-MM-yyyy") in
  check_eq ~msg:"the already selected sidebar page updates immediately"
    (member "title" (member "selectedPage" response)) (`String "23-10-2026");
  let route = List.hd (Q.items "nodeRoutes" response) in
  check_eq ~msg:"an existing navigation destination updates immediately"
    (member "title" (member "page" route)) (`String "23-10-2026");
  let rows = Q.items "outlinerRows" route in
  check ~msg:"journal block headers update with the page title"
    (List.for_all (fun row -> member "journalTitle" (member "block" row) = `String "23-10-2026") rows))

let all_master_formats_and_invalid_legacy_days_are_safe () = R.with_runtime (fun session runtime conn ->
  List.iter (fun format ->
    success (set_format session format);
    check ~msg:("master format renders the journal: " ^ format)
      (Option.fold ~none:false ~some:(fun title -> String.trim title <> "") (display_title (Graph_runtime.db runtime) R.day_a)))
    Journal.built_in_journal_title_formatters;
  ignore (D.transact_conn conn [Q.put R.day_a "block/journal-day" (D.Int64 20261399L)]);
  Graph_runtime.rebase runtime 42 [] [R.day_a];
  check_eq ~msg:"invalid legacy journal days retain the readable stored title"
    (display_title (Graph_runtime.db runtime) R.day_a) (Some "October 1st, 2026"))

let graph_switch_resets_preferences_but_partial_updates_preserve_them () =
  let projection fields = Result.get_ok (Response_snapshot.decode_response (J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc fields]))) in
  let apply current projection = Model.update current (Model.ApplyCoreSnapshot projection) in
  let initial = Model.initial () in
  let first = apply initial (projection ["selectedGraphId", `String "a"; "journalTitleFormat", `String "yyyy-MM-dd"]) in
  check_eq first.journal_title_format "yyyy-MM-dd";
  let patched = apply first (projection ["selectedGraphId", `String "a"; "isPendingSyncPatch", `Bool true]) in
  check_eq patched.journal_title_format "yyyy-MM-dd";
  let switched = apply patched (projection ["selectedGraphId", `String "b"]) in
  check_eq ~msg:"a graph cannot inherit the previous graph's date preference" switched.journal_title_format Journal.default_format

let date_commands_keep_stable_journal_references_after_format_changes () = R.with_runtime (fun session runtime _ ->
  success (set_format session "dd-MM-yyyy");
  List.iter (fun (date, uuid, label) ->
    ignore (Editor_command_test.run session "Date picker");
    let response = Editor_command_test.submit session date in
    let title = member "title" (Editor_command_test.draft response) in
    check_eq ~msg:"date commands insert stable references even when the stored title uses an older format"
      title (`String ("[[" ^ uuid ^ "]]"));
    Editor_command_test.save session;
    let block = List.find (fun (block : Cache_model.block) -> block.uuid = Q.alpha)
      (Graph_runtime.blocks_for_page runtime Q.page) in
    check ~msg:"saved date references remain navigable and display the graph format"
      (List.exists (fun (node : Cache_model.entity_summary) -> node.uuid = uuid && node.title = label) block.references))
    ["2026-10-01", R.day_a, "01-10-2026";
     "2026-11-05", Rpc_wire.journal_page_uuid 20261105, "05-11-2026"])

let search_reindexes_journals_and_references_when_format_changes () =
  Graph_runtime_test.with_search_runtime (R.fixture ()) (fun _ conn runtime ->
    let session = Rpc_session.create_session {Rpc_session.default_options with
      load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
      graph_db = Some (fun () -> Some (Graph_runtime.db runtime));
      sync_cursor = Some (fun () -> Some (Graph_runtime.state runtime).server_t);
      stage_operation = Some (Graph_runtime.stage runtime); prepare_operation = Some (Graph_runtime.prepare_sync runtime)}
      |> Rpc_test.configure_plain_session in
    success (Rpc_test.dispatch_json session "ensureJournal" "20261023");
    let page = Rpc_wire.journal_page_uuid 20261023 in
    Composer_tag_test.sync_all runtime conn;
    ignore (D.transact_conn conn [Q.put Q.alpha "block/title" (D.String ("See [[" ^ page ^ "]]"));
      Q.put Q.alpha "block/refs" (D.Ref_to (Q.ref_uuid page))]);
    Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [Q.alpha];
    let before, _ = Graph_runtime.search_page runtime ~offset:0 ~limit:20 "20261023" in
    check ~msg:"the search index is already live before changing format"
      (List.exists (fun (hit : Search_index.indexed_search_hit) -> hit.uuid = page) before);
    success (set_format session "dd-MM-yyyy");
    let hits, _ = Graph_runtime.search_page runtime ~offset:0 ~limit:20 "23-10-2026" in
    check ~msg:"the new journal format becomes searchable immediately"
      (List.exists (fun (hit : Search_index.indexed_search_hit) -> hit.uuid = page && hit.title = "23-10-2026") hits);
    check ~msg:"references in indexed block titles follow the chosen journal format"
      (List.exists (fun (hit : Search_index.indexed_search_hit) -> hit.uuid = Q.alpha && String_kit.includes ~sub:"23-10-2026" hit.title) hits))

let cases = [
  case "search refreshes journal and reference labels on format changes" search_reindexes_journals_and_references_when_format_changes;
  case "date commands preserve existing and new journal identities" date_commands_keep_stable_journal_references_after_format_changes;
  case "open destinations refresh date labels immediately" open_destinations_refresh_without_reopening;
  case "all master formats and malformed legacy days render safely" all_master_formats_and_invalid_legacy_days_are_safe;
  case "date format preferences remain scoped to the graph" graph_switch_resets_preferences_but_partial_updates_preserve_them;
  case "existing journals reformat without changing identity" existing_journals_reformat_without_identity_changes;
  case "captures and restart retain graph date format" new_captures_and_restart_keep_the_graph_format;
  case "properties and journal references share date format" property_values_and_reference_labels_share_the_format;
  case "invalid and stale date preferences never write" invalid_and_stale_changes_never_write;
  case "all journal creation paths use the chosen format" all_journal_creation_paths_use_the_preference;
  case "failed storage preserves the graph preference" failed_storage_keeps_the_previous_graph_preference;
  case "native settings share graph date format choices" settings_share_native_date_format_choices;
]
