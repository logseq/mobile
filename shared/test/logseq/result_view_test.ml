open Test_util
module Ds = Datascript
module Q = Query_block_test
module Session = Rpc_session
module Json = Yojson.Basic
let member = Q.member
let items = Q.items
let text = function `String value -> value | _ -> ""
let put = Q.put
let ref_uuid = Q.ref_uuid
let owner = Q.owner
let alpha = Q.alpha
let beta = Q.beta
let gamma = "20000000-0000-4000-8000-000000000001"
let score = "user.property/Score"
let summary = "user.property/Summary"
let ready = "user.property/Ready"
let due = "user.property/Due"
let many_score = "user.property/ManyScores"
let score_property = "20000000-0000-4000-8000-000000000002"
let summary_property = "20000000-0000-4000-8000-000000000003"
let views_page = "20000000-0000-4000-8000-000000000004"
let list_view = "20000000-0000-4000-8000-000000000005"
let table_view = "20000000-0000-4000-8000-000000000006"
let gallery_view = "20000000-0000-4000-8000-000000000007"
let broken_view = "20000000-0000-4000-8000-000000000008"
let value_a = "20000000-0000-4000-8000-000000000009"
let value_b = "20000000-0000-4000-8000-000000000010"
let text_a = "20000000-0000-4000-8000-000000000011"
let text_b = "20000000-0000-4000-8000-000000000012"
let day_a = "20000000-0000-4000-8000-000000000013"
let day_b = "20000000-0000-4000-8000-000000000014"

let entity n uuid title = [Ds.Add (Ds.Entity_id (910000 + n), "block/uuid", Ds.Uuid uuid);
  put uuid "block/title" (Ds.String title)]
let sorting keys = Ds.Vector (List.map (fun (attr, asc) -> Ds.Map
  [Ds.Keyword "id", Ds.Keyword attr; Ds.Keyword "asc?", Ds.Bool asc]) keys)
let filters ?(or_ = false) clauses = Ds.Map [Ds.Keyword "or?", Ds.Bool or_;
  Ds.Keyword "filters", Ds.Vector (List.map (fun (attr, op, value) ->
    Ds.Vector [Ds.Keyword attr; Ds.Keyword op; value]) clauses)]

let fixture () =
  let db = Q.fixture "#Project" in
  let ref_attr = {Storage_codec.default_schema_attr with Ds.value_type = Some Ds.RefType; indexed = true} in
  let db = {db with Ds.schema = [score, ref_attr; summary, ref_attr;
    ready, {ref_attr with Ds.value_type = None}; due, ref_attr;
    many_score, {ref_attr with Ds.cardinality = Ds.Many};
    "logseq.property/view-for", ref_attr; "logseq.property.view/type", ref_attr] @ db.schema} in
  let db = List.fold_left (fun db (n, name) ->
    let ident = "logseq.property.view/type." ^ name in
    if Ds.entid db "db/ident" (Ds.Keyword ident) <> None then db
    else Ds.db_with [Ds.Add (Ds.Entity_id n, "db/ident", Ds.Keyword ident)] db)
    db [919001, "list"; 919002, "table"; 919003, "gallery"] in
  let property n uuid title attr typ = entity n uuid title @ [
    put uuid "block/name" (Ds.String (String.lowercase_ascii title));
    put uuid "db/cardinality" (Ds.Keyword (if attr = many_score then "db.cardinality/many" else "db.cardinality/one"));
    put uuid "db/ident" (Ds.Keyword attr); put uuid "logseq.property/type" (Ds.Keyword typ);
    put uuid "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Property"))]
    @ (if typ = "checkbox" then [] else [put uuid "db/valueType" (Ds.Keyword "db.type/ref")]) in
  let value n uuid property scalar = [Ds.Add (Ds.Entity_id (910000 + n), "block/uuid", Ds.Uuid uuid);
    put uuid "logseq.property/created-from-property" (Ds.Ref_to (ref_uuid property));
    put uuid (match scalar with Ds.String _ -> "block/title" | _ -> "logseq.property/value") scalar] in
  let view n uuid title typ order = entity n uuid title @ [
    put uuid "block/page" (Ds.Ref_to (ref_uuid views_page));
    put uuid "block/parent" (Ds.Ref_to (ref_uuid views_page));
    put uuid "block/order" (Ds.String order);
    put uuid "logseq.property/view-for" (Ds.Ref_to (ref_uuid owner));
    put uuid "logseq.property.view/feature-type" (Ds.Keyword "query-result");
    put uuid "logseq.property.view/type" (Ds.Ref_to (Ds.Ident ("logseq.property.view/type." ^ typ)))] in
  Ds.db_with (entity 1 gamma "Gamma result" @ [
    put gamma "block/page" (Ds.Ref_to (ref_uuid Q.page));
    put gamma "block/parent" (Ds.Ref_to (ref_uuid Q.page)); put gamma "block/order" (Ds.String "a4");
    put gamma "block/refs" (Ds.Ref_to (ref_uuid Q.project));
    put beta "block/refs" (Ds.Ref_to (ref_uuid Q.project))]
    @ property 2 score_property "Score" score "number"
    @ property 3 summary_property "Summary" summary "default"
    @ property 15 "20000000-0000-4000-8000-000000000015" "Ready" ready "checkbox"
    @ property 16 "20000000-0000-4000-8000-000000000016" "Due" due "date"
    @ property 17 "20000000-0000-4000-8000-000000000017" "Scores" many_score "number"
    @ entity 4 views_page "$$$views" @ [put views_page "block/name" (Ds.String "$$$views")]
    @ value 9 value_a score_property (Ds.Int64 20L)
    @ value 10 value_b score_property (Ds.Int64 10L)
    @ value 11 text_a summary_property (Ds.String "Research")
    @ value 12 text_b summary_property (Ds.String "Writing")
    @ entity 13 day_a "October 1st, 2026" @ [put day_a "block/journal-day" (Ds.Int64 20261001L)]
    @ entity 14 day_b "October 3rd, 2026" @ [put day_b "block/journal-day" (Ds.Int64 20261003L)]
    @ [put alpha score (Ds.Ref_to (ref_uuid value_a)); put beta score (Ds.Ref_to (ref_uuid value_b));
       put alpha summary (Ds.Ref_to (ref_uuid text_a)); put beta summary (Ds.Ref_to (ref_uuid text_b));
       put alpha due (Ds.Ref_to (ref_uuid day_a)); put beta due (Ds.Ref_to (ref_uuid day_b));
       put alpha ready (Ds.Bool true); put beta ready (Ds.Bool false);
       put alpha many_score (Ds.Ref_to (ref_uuid value_a)); put alpha many_score (Ds.Ref_to (ref_uuid value_b))]
    @ view 5 list_view "Everything" "list" "a0"
    @ view 6 table_view "By score" "table" "a1"
    @ [put table_view "logseq.property.table/sorting" (sorting [score, true]);
       put table_view "logseq.property.table/ordered-columns" (Ds.Vector [Ds.Keyword "block/title"; Ds.Keyword score; Ds.Keyword summary])]
    @ view 7 gallery_view "Cards" "gallery" "a2"
    @ view 8 broken_view "Broken" "table" "a3"
    @ [put broken_view "logseq.property.table/sorting" (Ds.String "invalid")]) db

let make_session ?(configured = false) db =
  let current = ref db in
  let session = Session.create_session {Session.default_options with
    load_graph_catalog = (if configured then Some (fun () -> Some Rpc_test.plain_graph_catalog) else None);
    graph_db = Some (fun () -> Some !current);
    graph_node_destination = Some (fun uuid -> Graph_read.node_destination (fun text -> Ok text) !current uuid);
    graph_node_is_tag = Some (fun uuid -> Option.fold ~none:false
      ~some:(fun id -> Graph_read.entity_is_instance_of !current id "logseq.class/Tag")
      (Ds.entid !current "block/uuid" (Ds.Uuid uuid)));
    graph_node_is_property = Some (fun uuid -> Option.fold ~none:false
      ~some:(fun id -> Graph_read.entity_is_instance_of !current id "logseq.class/Property")
      (Ds.entid !current "block/uuid" (Ds.Uuid uuid)));
    graph_blocks = Some (fun () -> Some (Graph_read.blocks_for_page (fun x -> Ok x) !current Q.page));
    graph_page_blocks = Some (fun uuid -> Some (Graph_read.blocks_for_page (fun x -> Ok x) !current uuid))} in
  if configured then ignore (Rpc_test.configure_plain_session session);
  session, current
let read ?(owner = owner) ?(feature = "query-result") ?(input = "") session =
  let response = Rpc_test.dispatch_json session "resultViews" (Json.to_string (`Assoc ["ownerUuid", `String owner;
    "featureType", `String feature; "input", `String input])) in
  check_eq ~msg:(Json.to_string response) (member "ok" response) (`Bool true);
  member "result" response
let find_view uuid result = List.find (fun view -> member "uuid" view = `String uuid) (items "views" result)
let ids view = List.map (fun row -> member "uuid" (member "block" row)) (items "rows" view)
let expected_ids expected actual = check_eq ~msg:(Json.to_string actual) (ids actual) (List.map (fun s -> `String s) expected)

let saved_views_and_isolated_failures () =
  let session, _ = make_session (fixture ()) in
  Q.open_results session;
  let views = read session in
  check_eq (List.map (member "uuid") (items "views" views))
    (List.map (fun s -> `String s) [list_view; table_view; gallery_view; broken_view]);
  List.iter (fun (uuid, typ) -> let view = find_view uuid views in
    check_eq (member "type" view) (`String typ); check_eq (member "error" view) `Null;
    check_eq (List.length (items "rows" view)) 3)
    [list_view, "list"; table_view, "table"; gallery_view, "gallery"];
  check (match member "error" (find_view broken_view views) with `String text -> text <> "" | _ -> false);
  let snapshot = Rpc_test.response_result (Json.from_string (Session.snapshot_visible session)) in
  let block = List.find (fun block -> member "uuid" block = `String owner) (items "blocks" snapshot) in
  check_eq (List.length (items "views" (member "query" block))) 4

let list_results_defer_cell_editor_data () =
  let session, _ = make_session (fixture ()) in
  let result = read session in
  let list = find_view list_view result in
  List.iter (fun row ->
    check_eq ~msg:"list results load block content without unused table cell editors"
      (items "properties" row) [];
    check ~msg:"list results retain rich block content" (items "markup" (member "block" row) <> [])) (items "rows" list);
  List.iter (fun view ->
    let view = find_view view result in
    List.iter (fun row ->
      let block = member "block" row in
      check ~msg:"grid identity retains the readable title" (text (member "displayTitle" block) <> "");
      List.iter (fun attr -> check_eq ~msg:("grids do not duplicate unused block " ^ attr)
        (member attr block) `Null) ["markup"; "references"; "children"]) (items "rows" view);
    check ~msg:"switching to a grid retains typed cell values and editing"
      (List.exists (fun row -> List.exists (fun cell ->
        member "attr" cell = `String score && member "editable" cell = `Bool true)
        (items "properties" row)) (items "rows" view));
    check_eq ~msg:"view layout does not change result membership"
      (List.sort compare (ids view)) (List.sort compare (ids list))) [table_view; gallery_view]

let typed_filters_and_search () =
  let base = fixture () in
  let session, current = make_session base in
  let run ?(or_ = false) ?(input = "") clauses expected =
    current := Ds.db_with [put list_view "logseq.property.table/filters" (filters ~or_ clauses)] base;
    let view = find_view list_view (read ~input session) in
    check_eq ~msg:(Json.to_string view) (member "error" view) `Null;
    check_eq ~msg:(Json.to_string view) (List.sort compare (ids view))
      (List.sort compare (List.map (fun s -> `String s) expected)) in
  List.iter (fun (operator, number, expected) -> run [score, operator, Ds.Int64 number] expected)
    ["number-gt", 10L, [alpha]; "number-gte", 10L, [alpha; beta];
     "number-lt", 20L, [beta]; "number-lte", 20L, [alpha; beta]];
  run [score, "between", Ds.Vector [Ds.Int64 10L; Ds.Int64 20L]] [alpha; beta];
  run [score, "between", Ds.Vector [Ds.Nil; Ds.Int64 15L]] [beta];
  run [score, "is", Ds.Keyword "empty"] [gamma];
  run [score, "is-not", Ds.Keyword "empty"] [alpha; beta];
  run [summary, "text-contains", Ds.String "SEAR"] [alpha];
  run [summary, "text-not-contains", Ds.String "SEAR"] [beta; gamma];
  run [summary, "is", Ds.Set [Ds.Uuid text_a]] [alpha];
  run [summary, "is-not", Ds.Set [Ds.Uuid text_a]] [beta; gamma];
  run [ready, "is", Ds.Bool true] [alpha];
  run [ready, "is", Ds.Bool false] [beta; gamma];
  run [ready, "is-not", Ds.Bool true] [beta; gamma];
  run [many_score, "number-lt", Ds.Int64 15L] [alpha];
  run ~or_:true [score, "number-gt", Ds.Int64 15L; summary, "text-contains", Ds.String "writing"] [alpha; beta];
  run ~or_:true ~input:"ALPHA" [score, "number-gt", Ds.Int64 15L; summary, "text-contains", Ds.String "writing"] [alpha];
  run [score, "number-gt", Ds.Nil] [alpha; beta; gamma];
  run [due, "date-before", Ds.Map [Ds.Keyword "block/journal-day", Ds.Int64 20261002L]] [alpha];
  run [due, "date-after", Ds.Map [Ds.Keyword "block/journal-day", Ds.Int64 20261002L]] [beta];
  current := Ds.db_with [put list_view "logseq.property.table/filters"
    (filters [score, "unsupported", Ds.Int64 1L])] base;
  check_eq (member "error" (find_view list_view (read session))) `Null;
  check_eq (List.length (items "rows" (find_view list_view (read session)))) 3

let stable_multi_sort_and_property_columns () =
  let base = fixture () in
  let session, current = make_session base in
  let asc = find_view table_view (read session) in
  expected_ids [beta; alpha; gamma] asc;
  let cells = items "properties" (List.hd (items "rows" asc)) in
  check ~msg:"table displays the referenced numeric value" (List.exists (fun cell ->
    member "attr" cell = `String score && member "text" cell = `String "10" && member "editable" cell = `Bool true) cells);
  current := Ds.db_with [put table_view "logseq.property.table/sorting" (sorting [score, false])] base;
  expected_ids [alpha; beta; gamma] (find_view table_view (read session));
  current := Ds.db_with [put value_b "logseq.property/value" (Ds.Int64 20L);
    put table_view "logseq.property.table/sorting" (sorting [score, true; "block/title", false])] base;
  expected_ids [beta; alpha; gamma] (find_view table_view (read session));
  current := Ds.db_with [put table_view "logseq.property.table/hidden-columns" (Ds.Keyword summary)] base;
  check (not (List.exists (fun column -> member "attr" column = `String summary)
    (items "columns" (find_view table_view (read session)))))

let scopes_and_references () =
  let db = fixture () in
  let session, _ = make_session db in
  let tagged = read ~owner:Q.project ~feature:"class-objects" session in
  check_eq (List.length (items "views" tagged)) 1;
  expected_ids [alpha] (List.hd (items "views" tagged));
  let property = read ~owner:score_property ~feature:"property-objects" session in
  check_eq (List.sort compare (ids (List.hd (items "views" property)))) (List.sort compare [`String alpha; `String beta]);
  let unsupported = Rpc_test.dispatch_json session "resultViews" (Json.to_string (`Assoc [
    "ownerUuid", `String Q.project; "featureType", `String "linked-references"])) in
  check_eq ~msg:"references do not acquire configurable views" (member "ok" unsupported) (`Bool false)

let with_runtime ?projection_limit f = Graph_runtime_test.with_store (fun path ->
  Fun.protect ~finally:(fun () -> Graph_runtime_test.cleanup_store path) (fun () ->
    let conn = Ds.conn_from_db (fixture ()) in
    let runtime = Graph_runtime.create path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
    let session = Session.create_session {Session.default_options with
      outliner_projection_limit = projection_limit;
      load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
      sync_cursor = Some (fun () -> Some (Graph_runtime.state runtime).server_t);
      graph_db = Some (fun () -> Some (Graph_runtime.db runtime));
      graph_node_icon = Some (fun uuid -> Graph_read.node_icon (Graph_runtime.db runtime) uuid);
      graph_tag_pages = Some (fun () -> Some (Graph_read.tag_pages (fun value -> Ok value) (Graph_runtime.db runtime)));
      graph_node_is_tag = Some (Graph_runtime.node_is_tag runtime);
      graph_node_is_property = Some (Graph_runtime.node_is_property runtime);
      graph_tag_objects = Some (fun uuid -> Some (Graph_runtime.objects_for_tag runtime uuid));
      graph_node_destination = Some (fun uuid -> Graph_read.node_destination (fun value -> Ok value) (Graph_runtime.db runtime) uuid);
      stage_operation = Some (Graph_runtime.stage runtime);
      pending_operations = Some (fun () -> Graph_runtime.pending_operations runtime);
      prepare_operation = Some (Graph_runtime.prepare_sync runtime);
      graph_blocks = Some (fun () -> Some (Graph_runtime.blocks_for_page runtime Q.page));
      graph_page_blocks = Some (fun uuid -> Some (Graph_runtime.blocks_for_page runtime uuid))} in
    ignore (Rpc_test.configure_plain_session session);
    Q.open_results session;
    f session runtime conn))
let action session fields = Rpc_test.dispatch_json session "resultView" (Json.to_string (`Assoc fields))
let base_action action_name view = ["ownerUuid", `String owner; "featureType", `String "query-result";
  "viewUuid", `String view; "action", `String action_name]

let priority_choices_and_edits_use_the_real_graph () = with_runtime (fun session runtime conn ->
  let custom = "20000000-0000-4000-8000-000000000099" in
  let tx = entity 99 custom "Critical" @ [
    put custom "block/closed-value-property" (Ds.Ref_to (Ds.Ident "logseq.property/priority"));
    put custom "block/order" (Ds.String "a0");
    put alpha "logseq.property/priority" (Ds.Ref_to (ref_uuid custom))] in
  ignore (Ds.transact_conn conn tx);
  Graph_runtime.rebase runtime 42 [] [custom; alpha];
  let snapshot = Session.snapshot_visible session |> Json.from_string |> member "result" in
  let choices = items "taskPriorities" snapshot in
  check ~msg:"priority menus must use the graph's ordered closed values" (choices <> []);
  check_eq (member "uuid" (List.hd choices)) (`String custom);
  check_eq (member "title" (List.hd choices)) (`String "Critical");
  List.iter (fun backend ->
    Q.with_ui backend (Json.to_string (`Assoc ["ok", `Bool true; "result", snapshot])) (fun app ->
      let renderer = Lui_app.runtime app in
      let root = Lui_app.root_node app in
      let rendered = App_test.descendant_with_identifier renderer root ("outliner.block." ^ alpha) in
      let native = App_test.native_row app rendered in
      if native <> -1 then begin
        let payload = App_test.native_row_payload app rendered in
        check_eq (member "uuid" (List.hd (items "priorities" payload))) (`String custom);
        App_test.dispatch app (Lui_protocol.ExtensionEvent (native, "outliner-block-row", "set-priority",
          Lui_protocol.String_map.singleton "priority" (Lui_protocol.StringValue custom)))
      end else begin
        let find id = App_test.descendant_with_identifier renderer rendered id in
        check ~msg:"Android priority glyph must have a menu button" (find "button.block-task-priority" <> -1);
        let option = find ("button.block-task-priority-option." ^ custom) in
        check ~msg:"Android priority menu must include custom choices" (option <> -1);
        App_test.dispatch app (Lui_protocol.Press option)
      end;
      App_test.flush app;
      let chosen_effect = List.find_opt (fun eff ->
        member "kind" (Json.from_string (Native_bridge.encode_effect eff)) = `String "set-outliner-task-priority")
        ((App.model app).pending_effects @ (App.model app).in_flight_effects) in
      check ~msg:"choosing a priority crosses the typed core effect boundary" (chosen_effect <> None)))
    [App_test.ios_backend; App_test.kotlin_backend];
  let execute metadata = Core_effect_test.execute session "set-outliner-task-priority"
    ["text", `String alpha; "metadata", `String metadata] in
  let verify expected =
    let db = Graph_runtime.db runtime in
    let block = List.find (fun (b : Cache_model.block) -> b.uuid = alpha) (Graph_read.blocks_for_page (fun x -> Ok x) db Q.page) in
    check_eq (Option.map (fun (priority : Cache_model.status) -> priority.uuid) block.priority) expected;
    let result = find_view list_view (read session) in
    let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" result) in
    check_eq (member "uuid" (member "priority" (member "block" row)))
      (Option.fold ~none:`Null ~some:(fun uuid -> `String uuid) expected) in
  Core_effect_test.success (execute {|{"ident":"logseq.property/priority.high"}|});
  let high = Graph_read.uuid_for_eid (Graph_runtime.db runtime)
    (Option.get (Ds.entid (Graph_runtime.db runtime) "db/ident" (Ds.Keyword "logseq.property/priority.high"))) in
  verify high;
  Core_effect_test.success (execute (Json.to_string (`Assoc ["uuid", `String custom])));
  verify (Some custom);
  let count = List.length (Graph_runtime.pending_operations runtime) in
  check_eq (member "ok" (execute {|{"uuid":7}|})) (`Bool false);
  check_eq (List.length (Graph_runtime.pending_operations runtime)) count;
  Core_effect_test.success (execute "null");
  verify None;
  let restored = Graph_runtime.create runtime.path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
  let restored_block = List.find (fun (b : Cache_model.block) -> b.uuid = alpha) (Graph_runtime.blocks_for_page restored Q.page) in
  check_eq restored_block.priority None;
  List.iter (fun operation -> check_ok ~msg:"priority edits compile into canonical sync transactions"
    (Graph_runtime.prepare_sync runtime operation)) (Graph_runtime.pending_operations runtime))

let saved_configuration_projects_and_survives_restart () = with_runtime (fun session runtime _ ->
  let config = `Assoc ["type", `String "gallery"; "name", `String "Important";
    "sorting", `List [`Assoc ["id", `String score; "asc", `Bool false]];
    "filters", `Assoc ["or", `Bool false; "clauses", `List [`List [`String score; `String "number-gte"; `Int 15]]]] in
  let saved = action session (base_action "save" table_view @ ["config", config]) in
  check_eq ~msg:(Json.to_string saved) (member "ok" saved) (`Bool true);
  let view = find_view table_view (read session) in
  check_eq (member "name" view) (`String "Important"); check_eq (member "type" view) (`String "gallery");
  expected_ids [alpha] view;
  let queued = Graph_runtime.pending_operations runtime in
  check (queued <> []);
  let restored = Graph_runtime.create runtime.path 42 runtime.conn {Graph_runtime.default_options with auto_create_today = false} in
  let restored_session, _ = make_session (Graph_runtime.db restored) in
  expected_ids [alpha] (find_view table_view (read restored_session));
  List.iter (fun operation -> check_ok ~msg:"view settings compile into sync transactions" (Graph_runtime.prepare_sync runtime operation)) queued;
  let created = action session (base_action "create" "" @ ["config", `Assoc ["name", `String "Another"; "type", `String "list"]]) in
  check_eq ~msg:(Json.to_string created) (member "ok" created) (`Bool true);
  check_eq (List.length (items "views" (read session))) 5)

let settings_preserve_nested_match_values () = with_runtime (fun session _ _ ->
  List.iter (fun (attr, operator, value, expected) ->
    let saved = action session (base_action "save" list_view @ ["config", `Assoc [
      "filters", `Assoc ["or", `Bool false; "clauses", `List [`List [`String attr; `String operator; value]]]]]) in
    check_eq ~msg:(Json.to_string saved) (member "ok" saved) (`Bool true);
    check_eq (List.sort compare (ids (find_view list_view (read session))))
      (List.sort compare (List.map (fun uuid -> `String uuid) expected)))
    [summary, "is", `List [`String text_a], [alpha];
     score, "between", `List [`Null; `Float 15.5], [beta];
     score, "is", `String "empty", [gamma]])

let many_and_scalar_cells_preserve_types () = with_runtime (fun session runtime _ ->
  let edit attr text =
    let view = find_view table_view (read session) in
    let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" view) in
    let cell = List.find (fun cell -> member "attr" cell = `String attr) (items "properties" row) in
    let result = action session (base_action "editCell" table_view @ ["blockUuid", `String alpha;
      "attr", `String attr; "expected", member "raw" cell; "value", `String text]) in
    check_eq ~msg:(Json.to_string result) (member "ok" result) (`Bool true) in
  edit many_score "10, 25";
  edit ready "false";
  edit summary "Revised text";
  let db = Graph_runtime.db runtime in
  let eid = Option.get (Ds.entid db "block/uuid" (Ds.Uuid alpha)) in
  check_eq (Graph_read.value db eid ready) (Some (Ds.Bool false));
  let refs = Graph_read.ref_eids db eid many_score in
  check_eq (List.sort compare (List.map (fun eid -> Graph_read.value db eid "logseq.property/value") refs))
    [Some (Ds.Int64 10L); Some (Ds.Int64 25L)];
  let text = List.hd (Graph_read.ref_eids db eid summary) in
  check_eq (Graph_read.value db text "block/title") (Some (Ds.String "Revised text")))

let editable_cells_use_owner_values_and_conflicts () = with_runtime (fun session runtime conn ->
  let view = find_view table_view (read session) in
  let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" view) in
  let cell = List.find (fun cell -> member "attr" cell = `String score) (items "properties" row) in
  let edit ?(expected = member "raw" cell) value = action session (base_action "editCell" table_view @ [
    "blockUuid", `String alpha; "attr", `String score; "expected", expected; "value", `String value]) in
  let changed = edit "35" in
  check_eq ~msg:(Json.to_string changed) (member "ok" changed) (`Bool true);
  let db = Graph_runtime.db runtime in
  let eid = Option.get (Ds.entid db "block/uuid" (Ds.Uuid alpha)) in
  let target = List.hd (Graph_read.ref_eids db eid score) in
  check_eq (Graph_read.value db target "logseq.property/value") (Some (Ds.Int64 35L));
  check ~msg:"editing a cell does not mutate a shared value entity"
    (Graph_read.uuid_for_eid db target <> Some value_a);
  let original = Option.get (Ds.entid db "block/uuid" (Ds.Uuid value_a)) in
  check_eq (Graph_read.value db original "logseq.property/value") (Some (Ds.Int64 20L));
  let authoritative = Ds.conn_db conn in
  check_eq (Graph_read.ref_eids authoritative eid score)
    [Option.get (Ds.entid authoritative "block/uuid" (Ds.Uuid value_a))];
  let before = List.length (Graph_runtime.pending_operations runtime) in
  check_eq (member "ok" (edit "not a number")) (`Bool false);
  check_eq (member "ok" (edit "40")) (`Bool false);
  check_eq ~msg:"invalid input and stale edits do not enqueue writes" (List.length (Graph_runtime.pending_operations runtime)) before;
  List.iter (fun operation -> check_ok ~msg:"typed cell edits compile into sync transactions" (Graph_runtime.prepare_sync runtime operation))
    (Graph_runtime.pending_operations runtime))

let load_property_values session app =
    List.iter (function
      | Model.LoadPropertyValuesEffect (id, _, payload) ->
        App_test.send app (Model.DequeueEffect id);
        let response = Core_effect_test.execute session "load-property-values" ["text", `String payload] in
        check_eq ~msg:("editor values load through the real core: " ^ Json.to_string response) (member "ok" response) (`Bool true);
        let loaded = member "propertyValues" (member "result" response) in
        App_test.send app (Model.ReceivePropertyValues (text (member "key" loaded), Json.to_string (member "column" loaded)));
        App_test.send app (Model.ResolveEffect (id, true, Json.to_string response));
        App_test.flush app
      | _ -> ()) (App.model app).pending_effects

let rec load_result_rows session app =
  let pending = List.filter (function Model.LoadResultRowsEffect _ -> true | _ -> false) (App.model app).pending_effects in
  List.iter (function
    | Model.LoadResultRowsEffect (id, _, payload) ->
      App_test.send app (Model.DequeueEffect id);
      let response = Core_effect_test.execute session "load-result-rows" ["text", `String payload] in
      check_eq ~msg:(Json.to_string response) (member "ok" response) (`Bool true);
      let loaded = member "resultRows" (member "result" response) in
      let icons = match Response_snapshot.decode_json_response response with Ok projection -> projection.Model.node_icons | Error message -> fail message in
      App_test.send app (Model.ReceiveResultRows (text (member "key" loaded), Json.to_string (member "view" loaded), icons));
      App_test.send app (Model.ResolveEffect (id, true, Json.to_string response)); App_test.flush app
    | _ -> ()) pending;
  if pending <> [] then load_result_rows session app

let find_visible session app identifier =
  let host = Lui_app.runtime app in
  load_result_rows session app;
  load_property_values session app;
  let find () = App_test.descendant_with_identifier host (Lui_app.root_node app) identifier in
  if find () <> -1 then find () else
  let model = App.model app in
  let rec view uuid = function
    | `Assoc fields as value when member "uuid" value = `String uuid && List.mem_assoc "columns" fields -> Some value
    | `Assoc fields -> List.find_map (fun (_, value) -> view uuid value) fields
    | `List values -> List.find_map (view uuid) values | _ -> None in
  let row_json rows = List.filter_map (fun (row : Model.outline_row) ->
    try Some (Json.from_string row.query_json) with _ -> None) rows in
  let projections = row_json model.outliner_rows @ List.concat_map (fun (route : Model.node_projection) ->
    row_json route.node_outliner_rows) model.node_routes in
  let target = match String.split_on_char '.' identifier with
    | "view" :: "cell" :: "separator" :: uuid :: _row :: attr
    | "view" :: "cell" :: uuid :: _row :: attr -> Some (uuid, String.concat "." attr)
    | _ -> None in
  (match target with
   | None -> ()
   | Some (uuid, attr) ->
     (match List.find_map (view uuid) projections with
      | None -> ()
      | Some value ->
        let rec position offset = function
          | [] -> None
          | col :: _ when member "attr" col = `String attr -> Some offset
          | col :: rest -> position (offset + (if member "attr" col = `String "block/title" then 261 else 171)) rest in
        Option.iter (fun offset ->
          Hashtbl.iter (fun node extension ->
            if extension = "native-table-viewport" && App_test.extension_property app node "identifier"
              = Some (Lui_protocol.StringValue ("view.table.scroll." ^ uuid)) then (
              let fields = Lui_protocol.String_map.empty
                |> Lui_protocol.String_map.add "offset" (Lui_protocol.IntValue (max 0 (offset - 100)))
                |> Lui_protocol.String_map.add "width" (Lui_protocol.IntValue 390) in
              App_test.dispatch app (Lui_protocol.ExtensionEvent (node, extension, "viewport-changed", fields));
              App_test.flush app)) host.Lui_runtime.runtime_extension_nodes) (position 0 (items "columns" value))));
  let found = find () in
  if found <> -1 then found else
    Hashtbl.fold (fun node extension found ->
      if extension = "native-table-viewport" && App_test.extension_property app node "identifier"
        = Some (Lui_protocol.StringValue identifier) then node else found)
      host.Lui_runtime.runtime_extension_nodes (-1)

let native_view_tabs_search_table_and_gallery () =
  List.iter (fun backend -> with_runtime (fun session _ _ ->
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let runtime = Lui_app.runtime app in
      let find id = find_visible session app id in
      let tab uuid = find ("view.tab." ^ uuid) in
      check ~msg:"saved view tabs mount on both native hosts" (tab table_view <> -1);
      App_test.dispatch app (Lui_protocol.Press (tab table_view)); App_test.flush app;
      let scroll = find ("view.table.scroll." ^ table_view) in
      check ~msg:"table scrolling uses a native viewport" (scroll <> -1 && App_test.extension_node app "native-table-viewport" <> -1);
      let cell = find ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ score) in
      check (cell <> -1);
      App_test.dispatch app (Lui_protocol.Press cell); App_test.flush app;
      check ~msg:"tapping a cell opens a native editor" (find ("view.edit.value." ^ table_view) <> -1);
      let sheet = find ("view.edit.sheet." ^ table_view) in
      check ~msg:"cell editors expose native sheet sizing" (sheet <> -1);
      check_eq ~msg:"native sheet detents use the platform wire format"
        (App_test.property_string runtime sheet Lui_protocol.Detents) "medium,large";
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.edit.value." ^ table_view), "35"));
      App_test.flush app;
      App_test.dispatch app (Lui_protocol.Press (find ("view.edit.create." ^ table_view))); App_test.flush app;
      check ~msg:"saving edits uses a real core view action"
        (List.exists (fun eff -> member "kind" (Json.from_string (Native_bridge.encode_effect eff)) = `String "result-view")
          ((App.model app).pending_effects @ (App.model app).in_flight_effects));
      App_test.dispatch app (Lui_protocol.Press (tab gallery_view)); App_test.flush app;
      check (find ("view.gallery." ^ gallery_view) <> -1);
      App_test.dispatch app (Lui_protocol.Press (find ("view.search.toggle." ^ owner))); App_test.flush app;
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.search." ^ owner), "ALPHA")); App_test.flush app;
      check (find ("view.card." ^ gallery_view ^ "." ^ alpha) <> -1);
      check_eq (find ("view.card." ^ gallery_view ^ "." ^ beta)) (-1);
      App_test.dispatch app (Lui_protocol.Press (tab broken_view)); App_test.flush app;
      check_eq (find ("view.error." ^ broken_view)) (-1);
      check (App_test.reported_errors (App.model app) <> []);
      App_test.dispatch app (Lui_protocol.Press (tab list_view)); App_test.flush app;
      check (find ("outliner.block." ^ alpha) <> -1))))
    [App_test.ios_backend; App_test.kotlin_backend]

let native_view_settings_and_local_errors () =
  List.iter (fun backend -> with_runtime (fun session _ _ ->
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let runtime = Lui_app.runtime app in
      let find id = find_visible session app id in
      let click id = let node = find id in check ~msg:id (node <> -1);
        App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      click ("view.tab." ^ table_view);
      click ("view.filter." ^ table_view);
      let check_sheet () =
        let sheet = find ("view.settings.sheet." ^ table_view) in
        check ~msg:"settings expose a native sheet" (sheet <> -1);
        check_eq ~msg:"settings open at calendar-like height and expand for longer lists"
          (App_test.property_string runtime sheet Lui_protocol.Detents) "medium,large" in
      check_sheet ();
      check_eq (find ("view.settings.name." ^ table_view)) (-1);
      check_eq ~msg:"filters use a native grouped list"
        (App_test.node runtime (find ("view.filter.list." ^ table_view))) (Some Lui_protocol.ListContainer);
      click ("view.filter.add." ^ table_view);
      click ("view.settings.save." ^ table_view);
      let pending = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
      let id = Model.effect_id pending in
      ignore (Lui_app.send app (Model.DequeueEffect id));
      ignore (Lui_app.send app (Model.ResolveEffect (id, false, "This view changed")));
      App_test.flush app;
      check_eq ~msg:"view failures remain local" (App.model app).effect_error None;
      check_eq (find ("view.action.error." ^ table_view)) (-1);
      check (List.mem "This view changed" (App_test.reported_errors (App.model app)));
      click ("view.settings.cancel." ^ table_view);
      click ("view.sort." ^ table_view);
      check_sheet ();
      check_eq ~msg:"sorting uses a native grouped list"
        (App_test.node runtime (find ("view.sort.list." ^ table_view))) (Some Lui_protocol.ListContainer);
      check_eq ~msg:"sort settings do not expose filter controls"
        (find ("view.filter.add." ^ table_view)) (-1);
      click ("view.sort.add." ^ table_view);
      click ("view.settings.cancel." ^ table_view);
      click ("view.tab." ^ list_view);
      check (find ("outliner.block." ^ alpha) <> -1))))
    [App_test.ios_backend; App_test.kotlin_backend]

let native_cells_refresh_and_object_collections_mount () =
  List.iter (fun backend ->
    with_runtime (fun session _ _ ->
      Q.with_ui backend (Session.snapshot_visible session) (fun app ->
        let runtime = Lui_app.runtime app in
        let find id = find_visible session app id in
        App_test.dispatch app (Lui_protocol.Press (find ("view.tab." ^ table_view))); App_test.flush app;
        let view = find_view table_view (read session) in
        let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" view) in
        let cell = List.find (fun cell -> member "attr" cell = `String score) (items "properties" row) in
        let result = action session (base_action "editCell" table_view @ ["blockUuid", `String alpha;
          "attr", `String score; "expected", member "raw" cell; "value", `String "35"]) in
        check_eq (member "ok" result) (`Bool true);
        let projection = match Response_snapshot.decode_response (Json.to_string result) with Ok value -> value | Error e -> fail e in
        App_test.send app (Model.ApplyCoreSnapshot projection); App_test.flush app;
        let cell_node = find ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ score) in
        check_eq ~msg:"visible table cells react to projected value changes"
          (App_test.property_string runtime cell_node Lui_protocol.TextValue) "35"));
    List.iter (fun owner ->
      let session, _ = make_session (fixture ()) in
      ignore (Rpc_test.configure_plain_session session);
      let response = Rpc_test.dispatch_json session "openNode" (Json.to_string (`Assoc ["uuid", `String owner])) in
      check_eq ~msg:(Json.to_string response) (member "ok" response) (`Bool true);
      Q.with_ui backend (Json.to_string response) (fun app ->
        App_test.send app (Model.RequestAppNode owner);
        let projection = match Response_snapshot.decode_response (Json.to_string response) with
          | Ok value -> value | Error message -> fail message in
        App_test.send app (Model.ApplyCoreSnapshot projection); App_test.flush app;
        let runtime = Lui_app.runtime app in
        check ~msg:"tag and property objects mount native result views"
          (App_test.descendant_with_identifier runtime (Lui_app.root_node app) ("view.search.toggle." ^ owner) <> -1);
      check ~msg:"tag and property collections expose the same type icon"
        (App_test.descendant_with_identifier runtime (Lui_app.root_node app) ("view.type." ^ owner ^ ":default") <> -1)))
      [Q.project; score_property]) [App_test.ios_backend; App_test.kotlin_backend]

let tuple_table_and_query_errors () =
  List.iter (fun backend ->
    let db = Ds.db_with [put Q.definition "block/title" (Ds.String
      "{:query [:find ?t ?s :where [?b :user.property/score ?s] [?b :block/title ?t]]}")] (fixture ()) in
    let session, current = make_session db in
    ignore (Rpc_test.configure_plain_session session);
    Q.open_results session;
    let view = find_view table_view (read session) in
    check_eq ~msg:"tuple tables expose one column for each query value" (List.length (items "columns" view)) 2;
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let _runtime = Lui_app.runtime app in
      let find id = find_visible session app id in
      App_test.dispatch app (Lui_protocol.Press (find ("view.tab." ^ table_view))); App_test.flush app;
      check ~msg:"tuple values render in read-only table cells" (find ("view.scalar." ^ table_view ^ ".0.0") <> -1);
      current := Ds.db_with [put Q.definition "block/title" (Ds.String "(and")] db;
      let projection = match Response_snapshot.decode_response (Session.snapshot_visible session) with
        | Ok value -> value | Error message -> fail message in
      App_test.send app (Model.ApplyCoreSnapshot projection); App_test.flush app;
      check_eq ~msg:"query diagnostics do not render inside the query block" (find ("query.error." ^ owner)) (-1);
      check ~msg:"query diagnostics enter the host log" (App_test.reported_errors (App.model app) <> [])))
    [App_test.ios_backend; App_test.kotlin_backend]

let typed_edits_restart_and_sync_acknowledgements () = with_runtime (fun session runtime conn ->
  let edit target attr value =
    let view = find_view table_view (read session) in
    let row = List.find (fun row -> member "uuid" (member "block" row) = `String target) (items "rows" view) in
    let cell = List.find (fun cell -> member "attr" cell = `String attr) (items "properties" row) in
    let result = action session (base_action "editCell" table_view @ ["blockUuid", `String target;
      "attr", `String attr; "expected", member "raw" cell; "value", `String value]) in
    check_eq ~msg:(Json.to_string result) (member "ok" result) (`Bool true) in
  edit alpha score "12.5";
  edit beta summary "";
  edit alpha many_score "5, 8";
  let pending = Graph_runtime.pending_operations runtime in
  check_eq (List.length pending) 3;
  List.iter (fun operation -> check ~msg:"atomic edits have coherent final postconditions"
    (Pending_projection.satisfied (Graph_runtime.db runtime) operation.Pending_ops.intent)) pending;
  let restored = Graph_runtime.create runtime.path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
  let restored_session, _ = make_session (Graph_runtime.db restored) in
  let rows = items "rows" (find_view table_view (read restored_session)) in
  let property target attr =
    let row = List.find (fun row -> member "uuid" (member "block" row) = `String target) rows in
    List.find (fun property -> member "attr" property = `String attr) (items "properties" row) in
  check_eq (member "text" (property alpha score)) (`String "12.5");
  check_eq (member "raw" (property beta summary)) `Null;
  List.iteri (fun index operation ->
    let before = (Graph_runtime.state restored).server_t in
    let _, tx = match Graph_runtime.prepare_sync restored operation with Ok value -> value | Error message -> fail message in
    let journal = match Journal_sync.decode (Json.to_string (`Assoc ["type", `String "tx/batch/ok";
      "t-before", `Int before; "t", `Int (before + 1); "txs", `List [`Assoc ["t", `Int (before + 1);
        "tx-id", `String operation.Pending_ops.operation_id; "tx", `String tx]]])) with
      | Ok value -> value | Error message -> fail message in
    check_ok (Graph_runtime.stage restored {operation with Pending_ops.state = Pending_ops.Accepted (before + 1)});
    let ids, changed = match Journal_sync.apply (fun value -> Ok value) conn before journal with
      | Ok value -> value | Error message -> fail message in
    Graph_runtime.rebase restored journal.t ids changed;
    check_eq ~msg:"server echoes confirm atomic property values and owner assignments together"
      (List.length (Graph_runtime.pending_operations restored)) (2 - index)) pending;
  check_eq (Graph_runtime.pending_operations restored) [];
  let db = Ds.conn_db conn in
  let alpha_id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid alpha)) in
  let values = Graph_read.ref_eids db alpha_id many_score in
  let number id = match Graph_read.value db id "logseq.property/value" with
    | Some (Ds.Int64 value) -> Int64.to_float value | Some (Ds.Float value) -> value
    | value -> fail ("Synced property value is not numeric: " ^
        Option.fold ~none:"missing" ~some:Dev_query.Edn_util.pr_str value ^ " at eid " ^ string_of_int id) in
  check_eq (List.sort Float.compare (List.map number values)) [5.; 8.])

let date_cells_accept_calendar_dates () = with_runtime (fun session runtime _ ->
  let view = find_view table_view (read session) in
  let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" view) in
  let cell = List.find (fun cell -> member "attr" cell = `String due) (items "properties" row) in
  let result = action session (base_action "editCell" table_view @ ["blockUuid", `String alpha;
    "attr", `String due; "expected", member "raw" cell; "value", `String "2026-10-23"]) in
  check_eq ~msg:(Json.to_string result) (member "ok" result) (`Bool true);
  let db = Graph_runtime.db runtime in
  let id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid alpha)) in
  let journal = List.hd (Graph_read.ref_eids db id due) in
  check_eq (Graph_read.value db journal "block/journal-day") (Some (Ds.Int64 20261023L));
  let before = List.length (Graph_runtime.pending_operations runtime) in
  let view = find_view table_view (read session) in
  let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" view) in
  let updated = List.find (fun cell -> member "attr" cell = `String due) (items "properties" row) in
  let invalid = action session (base_action "editCell" table_view @ ["blockUuid", `String alpha;
    "attr", `String due; "expected", member "raw" updated; "value", `String "2026-02-30"]) in
  check_eq (member "ok" invalid) (`Bool false);
  check_eq (List.length (Graph_runtime.pending_operations runtime)) before)

let native_boolean_editor_uses_the_real_effect_pipeline () =
  List.iter (fun backend -> with_runtime (fun session runtime _ ->
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = find_visible session app id in
      let click id = let node = find id in check ~msg:id (node <> -1);
        App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      click ("view.tab." ^ table_view);
      click ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ ready);
      click ("view.edit.bool.false." ^ table_view);
      let pending = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
      let action, body = match Core_effect.request ~now:(fun () -> 1) ~fresh_id:(fun () -> "unused")
          (Some (Native_bridge.encode_effect pending)) with Ok value -> value | Error message -> fail message in
      check_eq action "resultView";
      let response = Rpc_test.dispatch_json session action (Option.get body) in
      check_eq ~msg:(Json.to_string response) (member "ok" response) (`Bool true);
      let id = Model.effect_id pending in
      App_test.send app (Model.DequeueEffect id);
      let projection = match Response_snapshot.decode_response (Json.to_string response) with Ok value -> value | Error message -> fail message in
      App_test.send app (Model.ApplyCoreSnapshot projection);
      App_test.send app (Model.ResolveEffect (id, true, Json.to_string response)); App_test.flush app;
      check_eq (find ("view.edit.value." ^ table_view)) (-1);
      check_eq (App_test.property_string host (find ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ ready)) Lui_protocol.TextValue) "false";
      let db = Graph_runtime.db runtime in
      check_eq (Graph_read.value db (Option.get (Ds.entid db "block/uuid" (Ds.Uuid alpha))) ready) (Some (Ds.Bool false)))))
    [App_test.ios_backend; App_test.kotlin_backend]

let available_properties_and_corrupt_filter_isolation () =
  let db = Ds.db_with [put table_view "logseq.property.table/hidden-columns" (Ds.Keyword summary);
    put list_view "logseq.property.table/filters" (Ds.String "corrupt")] (fixture ()) in
  let session, _ = make_session db in
  let views = read session in
  let table = find_view table_view views in
  check ~msg:"hidden table columns remain available for filter and sort selection"
    (List.exists (fun property -> member "attr" property = `String summary) (items "properties" table));
  check ~msg:"corrupt filters are a view-local error" (member "error" (find_view list_view views) <> `Null);
  check_eq (member "error" table) `Null;
  expected_ids [beta; alpha; gamma] table

let native_toolbar_alignment_and_search_expansion () =
  List.iter (fun (backend, leading) -> with_runtime (fun session _ _ ->
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = find_visible session app id in
      let click id = let node = find id in check ~msg:id (node <> -1);
        App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      check_eq ~msg:"query results use a single results and actions header"
        (find ("view.tabs." ^ owner)) (-1);
      check_eq ~msg:"mobile collections do not offer New view" (find ("view.add." ^ owner)) (-1);
      let toolbar = find ("view.toolbar." ^ owner) in
      check ~msg:"the entire view toolbar shares one row" (toolbar <> -1);
      check_eq (App_test.children host toolbar |> List.map (fun id ->
        App_test.property_string host id Lui_protocol.AccessibilityIdentifier))
        ["query.toggle." ^ owner; "view.filter." ^ list_view; "view.sort." ^ list_view; "view.search.toggle." ^ owner; "view.type." ^ list_view];
      let assert_disclosure expected =
        check_eq ~msg:"collection results reuse the block disclosure icon"
          (App_test.property_string host (find ("query.disclosure." ^ owner)) Lui_protocol.IconName) expected in
      assert_disclosure "app:disclosure-down";
      check_eq ~msg:"search expands only when requested" (find ("view.search." ^ owner)) (-1);
      click ("view.search.toggle." ^ owner);
      check (find ("view.search." ^ owner) <> -1);
      check_eq ~msg:"search fits its collection instead of claiming the screen width"
        (App_test.property_string host (find ("view.search." ^ owner)) Lui_protocol.ContainerRelativeFrameValue) "<missing>";
      check_eq ~msg:"expanded results are separated from the next block"
        (App_test.property_int host (find ("view.results-gap." ^ owner)) Lui_protocol.HeightValue) 24;
      click ("view.search.toggle." ^ owner);
      check_eq (find ("view.search." ^ owner)) (-1);
      let inset = find ("query.inset." ^ owner) in
      check_eq ~msg:"the collection starts at its owning bullet"
        (App_test.property_int host inset Lui_protocol.PaddingLeft) leading;
      let projection = match Response_snapshot.decode_response (Session.snapshot_visible session) with
        | Ok value -> value | Error message -> fail message in
      App_test.send app (Model.ApplyCoreSnapshot {projection with Model.outliner_rows =
        List.map (fun (row : Model.outline_row) -> {row with depth = 2}) projection.outliner_rows});
      App_test.flush app;
      check_eq ~msg:"nested collections follow the same bullet indentation"
        (App_test.property_int host inset Lui_protocol.PaddingLeft) (leading + 44))))
    [App_test.ios_backend, 20; App_test.kotlin_backend, 12]

let native_direct_value_selection_and_creation () =
  List.iter (fun backend -> with_runtime (fun session runtime conn ->
    let run closed =
      if closed then ignore (Ds.transact_conn conn [
        put value_a "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property));
        put value_b "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property))]);
      Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [value_a; value_b];
      Q.with_ui backend (Session.snapshot_visible session) (fun app ->
        let host = Lui_app.runtime app in
        let find id = find_visible session app id in
        let click id = let node = find id in check ~msg:id (node <> -1);
          App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
        click ("view.tab." ^ table_view);
        click ("view.cell." ^ table_view ^ "." ^ alpha ^ ".block/title");
        check ~msg:"Name opens the shared text editor" (find ("view.edit.value." ^ table_view) <> -1);
        check_eq ~msg:"Name editing preserves source markup instead of saving its display label"
          (App_test.property_string host (find ("view.edit.value." ^ table_view)) Lui_protocol.TextValue) "Alpha **result**";
        check_eq ~msg:"Name has no Clear value action" (find ("view.edit.clear." ^ table_view)) (-1);
        click ("view.edit.cancel." ^ table_view);
        click ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ score);
        check ~msg:"other properties retain Clear value" (find ("view.edit.clear." ^ table_view) <> -1);
        check ~msg:"a cell immediately opens its searchable choices"
          (find ("view.edit.option." ^ table_view ^ "." ^ value_b) <> -1);
        App_test.dispatch app (Lui_protocol.TextChanged (find ("view.edit.value." ^ table_view), "35"));
        App_test.flush app;
        check_eq ~msg:"the selector filters existing choices" (find ("view.edit.option." ^ table_view ^ "." ^ value_b)) (-1);
        if closed then check_eq ~msg:"closed properties cannot create new choices"
          (find ("view.edit.create." ^ table_view)) (-1)
        else check ~msg:"an open property offers explicit creation" (find ("view.edit.create." ^ table_view) <> -1);
        click ("view.edit.cancel." ^ table_view);
        check_eq ~msg:"cancel never writes a property" (List.filter (function Model.ReportErrorEffect _ -> false | _ -> true) (App.model app).pending_effects) [];
        click ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ score);
        click ("view.edit.option." ^ table_view ^ "." ^ value_b);
        let pending = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
        let _, body = match Core_effect.request ~now:(fun () -> 1) ~fresh_id:(fun () -> "unused")
          (Some (Native_bridge.encode_effect pending)) with Ok value -> value | Error message -> fail message in
        check_eq ~msg:"choosing a value submits its stable reference immediately"
          (member "selectedValues" (Json.from_string (Option.get body))) (`List [`String value_b]))
    in run false; run true)) [App_test.ios_backend; App_test.kotlin_backend]

let selected_references_and_explicit_object_creation () = with_runtime (fun session runtime conn ->
  let cell attr =
    let view = find_view table_view (read session) in
    let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" view) in
    List.find (fun cell -> member "attr" cell = `String attr) (items "properties" row) in
  let select attr values = action session (base_action "editCell" table_view @ [
    "blockUuid", `String alpha; "attr", `String attr; "expected", member "raw" (cell attr);
    "value", `String ""; "selectedValues", `List (List.map (fun value -> `String value) values)]) in
  let response = select score [value_b] in
  check_eq ~msg:(Json.to_string response) (member "ok" response) (`Bool true);
  let id = Option.get (Ds.entid (Graph_runtime.db runtime) "block/uuid" (Ds.Uuid alpha)) in
  check_eq ~msg:"a selected value reuses the existing entity"
    (Graph_read.ref_eids (Graph_runtime.db runtime) id score)
    [Option.get (Ds.entid (Graph_runtime.db runtime) "block/uuid" (Ds.Uuid value_b))];
  check_eq ~msg:"a number selector rejects unrelated object references"
    (member "ok" (select score [Q.page])) (`Bool false);
  check_eq ~msg:"single-valued cells reject multiple choices"
    (member "ok" (select score [value_a; value_b])) (`Bool false);
  let response = select many_score [value_b] in
  check_eq (member "ok" response) (`Bool true);
  ignore (Ds.transact_conn conn [put value_a "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property))]);
  Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [value_a];
  let invalid = select score [value_b] in
  check_eq ~msg:"closed-value validation also applies to direct choices" (member "ok" invalid) (`Bool false);
  let contact = "user.property/Contact" and property_uuid = "20000000-0000-4000-8000-000000000030" in
  ignore (Ds.transact_conn conn (entity 30 property_uuid "Contact" @ [
    put property_uuid "db/ident" (Ds.Keyword contact); put property_uuid "logseq.property/type" (Ds.Keyword "page");
    put property_uuid "db/valueType" (Ds.Keyword "db.type/ref"); put property_uuid "db/cardinality" (Ds.Keyword "db.cardinality/one") ]));
  Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [property_uuid];
  let create enabled = action session (base_action "editCell" table_view @ [
    "blockUuid", `String alpha; "attr", `String contact; "expected", `Null;
    "value", `String "New collaborator"; "create", `Bool enabled]) in
  check_eq ~msg:"typing an unknown object never creates it implicitly" (member "ok" (create false)) (`Bool false);
  let response = create true in
  check_eq ~msg:(Json.to_string response) (member "ok" response) (`Bool true);
  let db = Graph_runtime.db runtime in
  let created = List.hd (Graph_read.ref_eids db id contact) in
  check_eq ~msg:"explicit creation produces a named page"
    (Graph_read.value db created "block/name") (Some (Ds.String "new collaborator"));
  List.iter (fun pending -> check_ok ~msg:"selector mutations compile into sync operations"
    (Graph_runtime.prepare_sync runtime pending)) (Graph_runtime.pending_operations runtime))

let native_filter_choices_preserve_master_sets () =
  List.iter (fun backend -> with_runtime (fun session _ _ ->
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = find_visible session app id in
      let press node = check (node <> -1); App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      let rec choice node title =
        if App_test.node host node = Some Lui_protocol.MenuItem
          && App_test.property_string host node Lui_protocol.TextValue = title then node
        else List.fold_left (fun found child -> if found <> -1 then found else choice child title)
          (-1) (App_test.children host node) in
      press (find ("view.tab." ^ table_view));
      press (find ("view.filter." ^ table_view));
      press (find ("view.filter.add." ^ table_view));
      let list = find ("view.filter.list." ^ table_view) in
      press (choice list "Score");
      press (find ("view.filter.values." ^ table_view ^ ".2"));
      let pick label =
        let rec find_choice node =
          if App_test.node host node = Some Lui_protocol.Button
            && App_test.property_string host node Lui_protocol.TextValue = label then node
          else List.fold_left (fun found child -> if found <> -1 then found else find_choice child)
            (-1) (App_test.children host node) in
        press (find_choice (find ("view.filter.values.sheet." ^ table_view ^ ".2"))) in
      pick "10"; pick "20";
      press (find ("view.filter.values.done." ^ table_view ^ ".2"));
      press (find ("view.settings.save." ^ table_view));
      let pending = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
      let _, body = Result.get_ok (Core_effect.request ~now:(fun () -> 1) ~fresh_id:(fun () -> "unused")
        (Some (Native_bridge.encode_effect pending))) in
      let config = member "config" (Json.from_string (Option.get body)) in
      check_eq ~msg:"editing filters does not overwrite sorting" (member "sorting" config) `Null;
      let clauses = items "clauses" (member "filters" config) in
      check_eq ~msg:"native choices preserve master's UUID match set"
        clauses [`List [`String score; `String "is"; `List [`String value_b; `String value_a]]])))
    [App_test.ios_backend; App_test.kotlin_backend]

let native_many_selector_stages_choices_until_done () =
  List.iter (fun backend -> with_runtime (fun session runtime _ ->
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = find_visible session app id in
      let click id = let node = find id in check ~msg:id (node <> -1);
        App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      click ("view.tab." ^ table_view);
      click ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ many_score);
      check (App_test.property_bool host (find ("view.edit.option." ^ table_view ^ "." ^ value_b)) Lui_protocol.Selected);
      click ("view.edit.option." ^ table_view ^ "." ^ value_b);
      check_eq ~msg:"multiple selection waits for Done" (List.filter (function Model.ReportErrorEffect _ -> false | _ -> true) (App.model app).pending_effects) [];
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.edit.value." ^ table_view), "35")); App_test.flush app;
      click ("view.edit.create." ^ table_view);
      check_eq (List.filter (function Model.ReportErrorEffect _ -> false | _ -> true) (App.model app).pending_effects) [];
      click ("view.edit.save." ^ table_view);
      let pending = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
      let action, body = Result.get_ok (Core_effect.request ~now:(fun () -> 1) ~fresh_id:(fun () -> "unused")
        (Some (Native_bridge.encode_effect pending))) in
      let response = Rpc_test.dispatch_json session action (Option.get body) in
      check_eq ~msg:(Json.to_string response) (member "ok" response) (`Bool true);
      let db = Graph_runtime.db runtime in
      let id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid alpha)) in
      let values = Graph_read.ref_eids db id many_score |> List.map (fun id -> Graph_read.value db id "logseq.property/value") in
      check_eq (List.sort compare values) [Some (Ds.Int64 20L); Some (Ds.Int64 35L)])))
    [App_test.ios_backend; App_test.kotlin_backend]

let master_conformance () =
  let fixture = Json.from_file "logseq/fixtures/master-views.json" in
  let schema = match Dev_query.Edn_util.read_string (text (member "schema" fixture)) with
    | Ds.Map fields -> List.map (fun (attr, spec) ->
        let attr = match attr with Ds.Keyword attr -> attr | _ -> fail "Invalid fixture attribute" in
        let field key = match spec with Ds.Map fields -> List.assoc_opt (Ds.Keyword key) fields | _ -> None in
        attr, {Storage_codec.default_schema_attr with
          Ds.cardinality = (if field "db/cardinality" = Some (Ds.Keyword "db.cardinality/many") then Ds.Many else Ds.One);
          indexed = field "db/index" = Some (Ds.Bool true);
          unique = (if field "db/unique" = Some (Ds.Keyword "db.unique/identity") then Some Ds.Identity else None);
          value_type = (if field "db/valueType" = Some (Ds.Keyword "db.type/ref") then Some Ds.RefType else None)}) fields
    | _ -> fail "Invalid master schema" in
  let conn = Ds.conn_from_db (Ds.empty_db ~schema ()) in
  ignore (Ds.transact_conn_string conn (text (member "tx" fixture)));
  let base = Ds.conn_db conn in
  let session, current = make_session base in
  let failures = List.filter_map (fun case ->
    let owner = text (member "owner" case) and view_uuid = text (member "view" case) in
    let setting attr key = match Dev_query.Edn_util.read_string (text (member key case)) with
      | Ds.Nil -> Ds.RetractAttr (ref_uuid view_uuid, attr)
      | value -> put view_uuid attr value in
    current := Ds.db_with [setting "logseq.property.table/sorting" "sorting";
      setting "logseq.property.table/filters" "filters"] base;
    let feature = text (member "feature" case) and input = text (member "input" case) in
    let rpc_view = find_view view_uuid (read ~owner ~feature ~input session) in
    (* Datalog collections have no defined order. Test membership through the RPC,
       then give both sort implementations the identical candidate sequence. *)
    let source_rows = List.map (fun uuid ->
      let id = Option.get (Ds.entid !current "block/uuid" (Ds.Uuid (text uuid))) in
      Query_block.Block (Option.get (Graph_read.block ~with_breadcrumbs:true (fun x -> Ok x) !current id)))
      (items "sourceRows" case) in
    let view = find_view view_uuid
      (Result_view.render_rows ~input !current ~owner ~feature ~encode_block:Rpc.block_json source_rows) in
    if member "error" case = `Bool true then
      if member "error" view <> `Null then None else Some (text (member "name" case) ^ ": expected local error")
    else if member "error" view <> `Null then Some (text (member "name" case) ^ ": " ^ Json.to_string (member "error" view))
    else if List.sort compare (ids rpc_view) <> List.sort compare (items "rows" case) then
      Some (text (member "name" case) ^ ": RPC scope or filtering differs from master")
    else if ids view = items "rows" case then None
    else Some (text (member "name" case) ^ ": expected " ^ Json.to_string (member "rows" case) ^ " got " ^ Json.to_string (`List (ids view))))
      (items "cases" fixture) in
  check_eq ~msg:(string_of_int (List.length failures) ^ " master conformance failures:\n" ^
    String.concat "\n" (List.filteri (fun index _ -> index < 20) failures)) failures []

let type_icons_switch_saved_views_and_default_all () =
  List.iter (fun backend -> with_runtime (fun session runtime conn ->
    let run view_id expected_name typ =
      Q.with_ui backend (Session.snapshot_visible session) (fun app ->
        let renderer = Lui_app.runtime app in
        let find id = find_visible session app id in
        let tab = find ("view.tab." ^ view_id) in
        check ~msg:"the left tabs retain saved view names" (tab <> -1);
        check_eq (App_test.property_string renderer tab Lui_protocol.TextValue) expected_name;
        App_test.dispatch app (Lui_protocol.Press tab); App_test.flush app;
        let trigger = find ("view.type." ^ view_id) in
        check ~msg:"view type has its own icon menu" (trigger <> -1);
        let option = find ("view.type.option." ^ view_id ^ "." ^ typ) in
        check ~msg:"the type menu exposes list table and gallery" (option <> -1);
        App_test.dispatch app (Lui_protocol.Press option); App_test.flush app;
        let eff = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
        let payload = Json.from_string (Native_bridge.encode_effect eff) |> member "text" |> text |> Json.from_string in
        check_eq (member "action" payload) (`String "save");
        check_eq (member "type" (member "config" payload)) (`String typ);
        let result = Core_effect_test.execute session "result-view" ["text", `String (Json.to_string payload)] in
        Core_effect_test.success result;
        let projection = match Response_snapshot.decode_response (Json.to_string result) with Ok x -> x | Error e -> fail e in
        App_test.send app (Model.ApplyCoreSnapshot projection); App_test.flush app;
        let rendered = find (if typ = "table" then "view.table.scroll." ^ view_id else "view.gallery." ^ view_id) in
        check ~msg:"changing a view type replaces its renderer" (rendered <> -1)) in
    run list_view "Everything" "table";
    let changed = find_view list_view (read session) in
    check_eq (member "name" changed) (`String "Everything");
    check_eq (List.length (items "views" (read session))) 4;
    let db = Ds.db_with (List.map (fun uuid -> Ds.RetractEntity (ref_uuid uuid))
      [list_view; table_view; gallery_view; broken_view]) (fixture ()) in
    let session, _ = make_session db in
    ignore (Rpc_test.configure_plain_session session);
    Q.open_results session;
    let defaults = read session |> items "views" in
    check_eq (List.length defaults) 1;
    let all = List.hd defaults in
    check_eq (member "name" all) (`String "All");
    check_eq (member "type" all) (`String "list");
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let _renderer = Lui_app.runtime app in
      let find id = find_visible session app id in
      check ~msg:"an unsaved collection exposes the All tab" (find ("view.tab." ^ owner ^ ":default") <> -1);
      check ~msg:"an unsaved collection also exposes a type icon" (find ("view.type." ^ owner ^ ":default") <> -1))))
    [App_test.ios_backend; App_test.kotlin_backend]

let pushed_query_type_changes_refresh_the_visible_renderer () =
  List.iter (fun backend -> with_runtime (fun session _ _ ->
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let apply response =
        let projection = match Response_snapshot.decode_response (Json.to_string response) with
          | Ok value -> value | Error message -> fail message in
        App_test.send app (Model.ApplyCoreSnapshot projection); App_test.flush app in
      App_test.send app (Model.RequestAppNode owner);
      apply (Rpc_test.dispatch_json session "openNode" (Json.to_string (`Assoc ["uuid", `String owner])));
      let rec descendants id = id :: List.concat_map descendants (App_test.children host id) in
      let find identifier = descendants (Lui_app.root_node app) |> List.filter (fun id ->
        App_test.property_string host id Lui_protocol.AccessibilityIdentifier = identifier) |> List.rev
        |> function id :: _ -> id | [] -> find_visible session app identifier in
      List.iter (fun typ ->
        Gc.full_major ();
        let option = find ("view.type.option." ^ list_view ^ "." ^ typ) in
        check ~msg:"the visible pushed query exposes its type action" (option <> -1);
        App_test.dispatch app (Lui_protocol.Press option); App_test.flush app;
        let eff = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
        App_test.send app (Model.DequeueEffect (Model.effect_id eff));
        let response = Core_effect_test.execute session "result-view"
          ["text", member "text" (Json.from_string (Native_bridge.encode_effect eff))] in
        Core_effect_test.success response;
        apply response;
        App_test.send app (Model.ResolveEffect (Model.effect_id eff, true, Json.to_string response));
        App_test.flush app;
        let id = if typ = "table" then "view.table.scroll." ^ list_view else "view.gallery." ^ list_view in
        check ~msg:("a saved type must replace the pushed query renderer: " ^ typ) (find id <> -1))
        ["table"; "gallery"]))) [App_test.ios_backend; App_test.kotlin_backend]

let empty_table_cells_have_accessible_names () =
  List.iter (fun backend ->
    let db = Ds.db_with [Ds.Retract (ref_uuid alpha, summary, None)] (fixture ()) in
    let session, _ = make_session db in
    ignore (Rpc_test.configure_plain_session session);
    Q.open_results session;
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = find_visible session app id in
      App_test.dispatch app (Lui_protocol.Press (find ("view.tab." ^ table_view))); App_test.flush app;
      let cell = find ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ summary) in
      check_eq ~msg:"missing properties remain empty cells" (App_test.property_string host cell Lui_protocol.TextValue) "";
      check_eq ~msg:"empty editable cells retain a meaningful accessible name"
        (App_test.property_string host cell Lui_protocol.AccessibilityLabel) "Summary: Empty"))
    [App_test.ios_backend; App_test.kotlin_backend]

let compact_local_timestamps_and_columns () =
  let db = Ds.db_with [
    put alpha "block/created-at" (Ds.Int64 1792632600000L);
    put alpha "block/updated-at" (Ds.Int64 1792719000000L);
    put table_view "logseq.property.table/ordered-columns" (Ds.Vector [
      Ds.Keyword "block/updated-at"; Ds.Keyword "block/created-at"; Ds.Keyword "block/title"; Ds.Keyword score])] (fixture ()) in
  let session, _ = make_session db in
  Q.open_results session;
  let view = find_view table_view (read session) in
  let attrs = List.map (member "attr") (items "columns" view) in
  check ~msg:"updated timestamps stay out of the table" (not (List.mem (`String "block/updated-at") attrs));
  check_eq ~msg:"created timestamp is always the last visible column" (List.hd (List.rev attrs)) (`String "block/created-at");
  let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" view) in
  let created = List.find (fun p -> member "attr" p = `String "block/created-at") (items "properties" row) in
  let expected = Unix.localtime 1792632600. in
  let label = Printf.sprintf "%04d-%02d-%02d %02d:%02d" (expected.Unix.tm_year + 1900)
      (expected.tm_mon + 1) expected.tm_mday expected.tm_hour expected.tm_min in
  check_eq ~msg:"time uses the local timezone and a compact format" (member "text" created) (`String label);
  check ~msg:"updated timestamps remain available for master-compatible filters and sorting"
    (List.exists (fun p -> member "attr" p = `String "block/updated-at") (items "properties" view))

let table_name_is_editable_and_timestamps_are_read_only () = with_runtime (fun session runtime conn ->
  ignore (Ds.transact_conn conn [put alpha "block/created-at" (Ds.Int64 1792632600000L);
    put alpha "block/updated-at" (Ds.Int64 1792633600000L)]);
  Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [alpha];
  let view = find_view table_view (read session) in
  let name = List.find (fun column -> member "attr" column = `String "block/title") (items "properties" view) in
  check_eq ~msg:"Name is editable in a table" (member "editable" name) (`Bool true);
  let expected = member "raw" (Result_view.property_json (Graph_runtime.db runtime)
    ~owner:alpha ~attr:"block/title" ~encode_block:(fun _ -> `Null)) in
  let rename = base_action "editCell" table_view @ ["blockUuid", `String alpha;
    "attr", `String "block/title"; "expected", expected; "value", `String "Renamed project"] in
  check_eq ~msg:"table Name edits save through the graph mutation boundary" (member "ok" (action session rename)) (`Bool true);
  let id = Option.get (Ds.entid (Graph_runtime.db runtime) "block/uuid" (Ds.Uuid alpha)) in
  check_eq (Graph_read.value (Graph_runtime.db runtime) id "block/title") (Some (Ds.String "Renamed project"));
  check_eq ~msg:"a stale Name edit must not overwrite a newer title" (member "ok" (action session rename)) (`Bool false);
  check_eq (Graph_read.value (Graph_runtime.db runtime) id "block/title") (Some (Ds.String "Renamed project"));
  List.iter (fun attr ->
    let metadata = List.find (fun column -> member "attr" column = `String attr) (items "properties" view) in
    check_eq ~msg:(attr ^ " cannot be edited in a table") (member "editable" metadata) (`Bool false);
    let id = Option.get (Ds.entid (Graph_runtime.db runtime) "block/uuid" (Ds.Uuid alpha)) in
    let before = Graph_read.value (Graph_runtime.db runtime) id attr in
    let result = action session (base_action "editCell" table_view @ ["blockUuid", `String alpha;
      "attr", `String attr; "expected", member "raw" (Result_view.property_json
        (Graph_runtime.db runtime) ~owner:alpha ~attr ~encode_block:(fun _ -> `Null));
      "value", `String "Changed"] ) in
    check_eq ~msg:"RPC rejects read-only table edits" (member "ok" result) (`Bool false);
    check_eq ~msg:"rejected edits leave the graph unchanged"
      (Graph_read.value (Graph_runtime.db runtime) id attr) before)
    ["block/created-at"; "block/updated-at"])

let table_tags_are_editable_and_keep_typed_references () = with_runtime (fun session runtime _ ->
  let view = find_view table_view (read session) in
  let tags = List.find (fun column -> member "attr" column = `String "block/tags") (items "properties" view) in
  check_eq ~msg:"Tags can be edited like other table properties" (member "editable" tags) (`Bool true);
  let expected = member "raw" (Result_view.property_json (Graph_runtime.db runtime)
    ~owner:alpha ~attr:"block/tags" ~encode_block:(fun _ -> `Null)) in
  let result = action session (base_action "editCell" table_view @ ["blockUuid", `String alpha;
    "attr", `String "block/tags"; "expected", expected; "value", `String "";
    "selectedValues", `List [`String Q.project]; "newValues", `List [`String "Table tag"]; "create", `Bool true]) in
  check_eq ~msg:(Json.to_string result) (member "ok" result) (`Bool true);
  let db = Graph_runtime.db runtime in
  let id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid alpha)) in
  let titles = Graph_read.entity_summaries (fun value -> Ok value) db id "block/tags"
    |> List.map (fun (tag : Cache_model.entity_summary) -> tag.title) |> List.sort String.compare in
  check_eq ~msg:"selecting and creating tags stores reference values" titles ["Project"; "Table tag"];
  List.iter (fun operation -> check_ok ~msg:"typed table tag edits compile for sync"
    (Graph_runtime.prepare_sync runtime operation)) (Graph_runtime.pending_operations runtime))

let table_cells_have_column_dividers_on_both_hosts () =
  List.iter (fun backend -> with_runtime (fun session _ _ ->
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = find_visible session app id in
      App_test.dispatch app (Lui_protocol.Press (find ("view.tab." ^ table_view))); App_test.flush app;
      let view = find_view table_view (read session) in
      let attrs = List.map (fun column -> text (member "attr" column)) (items "columns" view) in
      List.iter (fun row -> List.iteri (fun index attr -> if index > 0 then (
        let divider = find ("view.cell.separator." ^ table_view ^ "." ^ row ^ "." ^ attr) in
        check ~msg:"adjacent table cells have a visible column divider" (divider <> -1);
        check_eq (App_test.property_string host divider Lui_protocol.OrientationValue) "vertical")) attrs)
        ["header"; alpha; beta; gamma];
      App_test.dispatch app (Lui_protocol.Press (find ("view.cell." ^ table_view ^ "." ^ alpha ^ ".block/title")));
      App_test.flush app;
      check ~msg:"Name opens its text editor beside the column dividers" (find ("view.edit.sheet." ^ table_view) <> -1);
      App_test.dispatch app (Lui_protocol.Press (find ("view.edit.cancel." ^ table_view)));
      App_test.flush app;
      App_test.dispatch app (Lui_protocol.Press (find ("view.cell." ^ table_view ^ "." ^ alpha ^ ".block/tags")));
      App_test.flush app;
      check ~msg:"Tags opens the shared native selector" (find ("view.edit.sheet." ^ table_view) <> -1))))
    [App_test.ios_backend; App_test.kotlin_backend]

let virtual_result_response ?(count = 10_001) ?(input = "") ?(reverse = false) ?(ready_value = true) typ =
  let rows = List.init count (fun index ->
    let index = if reverse then count - index - 1 else index in
    let uuid = "virtual-" ^ string_of_int index in
    `Assoc ["block", Q.query_result_block uuid (Printf.sprintf "Object %05d" index);
      "properties", `List [
        `Assoc ["attr", `String "block/title"; "text", `String (Printf.sprintf "Object %05d" index); "editable", `Bool true;
          "raw", `Assoc ["type", `String "string"; "value", `String (Printf.sprintf "Object %05d" index)]];
        `Assoc ["attr", `String ready; "text", `String (string_of_bool ready_value); "editable", `Bool true;
          "raw", `Assoc ["type", `String "bool"; "value", `Bool ready_value]]]]) in
  let column fields = `Assoc (if ready_value then fields else List.rev fields) in
  let view = `Assoc ["uuid", `String "virtual"; "name", `String "All"; "type", `String typ;
    "sorting", `String input; "columns", `List [
      column ["attr", `String "block/title"; "title", `String "Name"; "editable", `Bool true];
      column ["attr", `String ready; "title", `String "Ready"; "kind", `String "checkbox"; "editable", `Bool true]];
    "rows", `List rows] in
  let query = `Assoc ["ownerUuid", `String owner; "featureType", `String "query-result";
    "expanded", `Bool true; "views", `List [view]] in
  Json.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
    "selectedGraphId", `String "virtual-results"; "graphName", `String "Virtual results";
    "outlinerRows", `List [`Assoc ["depth", `Int 0; "hasChildren", `Bool false; "isCollapsed", `Bool false;
      "block", (match Q.query_result_block owner "Large query" with
        | `Assoc fields -> `Assoc (("query", query) :: fields) | _ -> assert false)]]]])

let hidden_filter_catalog_does_not_multiply_mount_allocations () =
  let response catalog =
    let rec decorate = function
      | `Assoc fields as value when member "uuid" value = `String "virtual" ->
        `Assoc (("properties", `List [`Assoc ["attr", `String summary;
          "kind", `String "default"; "title", `String "Summary";
          "filterValues", `List [`Assoc ["title", `String catalog]]]]) :: fields)
      | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key, decorate value) fields)
      | `List values -> `List (List.map decorate values)
      | value -> value in
    Json.to_string (decorate (Json.from_string (virtual_result_response ~count:400 "list"))) in
  let allocations catalog =
    let projection = match Response_snapshot.decode_response (response catalog) with
      | Ok value -> value | Error message -> fail message in
    let app = App.create (App_test.ios_backend ()) in
    Fun.protect ~finally:(fun () -> ignore (Lui_app.dispose app)) (fun () ->
      App_test.start app;
      Gc.full_major ();
      let before = Gc.allocated_bytes () in
      App_test.send app (Model.ApplyCoreSnapshot projection); App_test.flush app;
      let allocated = Gc.allocated_bytes () -. before in
      let runtime = Lui_app.runtime app in
      check ~msg:"large metadata keeps the first result visible"
        (App_test.descendant_with_identifier runtime (Lui_app.root_node app)
          ("query.result." ^ owner ^ ".0") <> -1);
      allocated) in
  let small = allocations "short value" in
  let catalog = String.make (512 * 1024) 'x' in
  let large = allocations catalog in
  check ~msg:(Printf.sprintf "hidden filter metadata must be parsed once, not copied for every row/count: %.0f -> %.0f bytes" small large)
    (large -. small < float_of_int (String.length catalog * 16))

let deferred_cell_editor_loads_without_replacing_the_page () =
  let rec defer = function
    | `Assoc fields as value when member "attr" value = `String ready ->
      `Assoc (("kind", `String "node") :: ("ref", `Bool true) :: ("valuesDeferred", `Bool true) ::
        List.remove_assoc "kind" fields)
    | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key, defer value) fields)
    | `List values -> `List (List.map defer values) | value -> value in
  ignore (Native_bridge.initialize 2 2 3);
  Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ())) (fun () ->
    ignore (Native_bridge.apply_response (Json.to_string (defer (Json.from_string (virtual_result_response ~count:1 "table")))));
    let app = Native_bridge.app () in
    let host = Lui_app.runtime app in
    let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
    let cell = find ("view.cell.virtual.virtual-0." ^ ready) in
    check (cell <> -1);
    ignore (Native_bridge.press cell);
    check ~msg:"the editor opens before its candidates load" (find "view.edit.sheet.virtual" <> -1);
    let load = (App.model app).pending_effects |> List.map (fun eff -> Json.from_string (Native_bridge.encode_effect eff))
      |> List.find_opt (fun eff -> member "kind" eff = `String "load-property-values") in
    check ~msg:"only opening an editor requests its candidate values" (Option.is_some load);
    let request = Json.from_string (text (member "text" (Option.get load))) in
    check_eq (member "ownerUuid" request) (`String "virtual-0");
    let before = (App.model app).outliner_rows in
    let column = `Assoc ["attr", `String ready; "kind", `String "node";
      "filterValues", `List [`Assoc ["title", `String "Available node"; "match", `List [`String "available"]]]] in
    ignore (Native_bridge.apply_response (Json.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
      "propertyValues", `Assoc ["key", member "key" request; "column", column]]])));
    check_eq ~msg:"editor-only replies preserve the page and its result views" (App.model app).outliner_rows before;
    check ~msg:"the loaded candidate is selectable in the existing sheet"
      (find "view.edit.option.virtual.available" <> -1);
    for index = 1 to 9 do
      ignore (Native_bridge.apply_response (Json.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
        "propertyValues", `Assoc ["key", `String ("another-editor-" ^ string_of_int index); "column", column]]])))
    done;
    check ~msg:"an open editor retains its candidates when older shared replies are evicted"
      (find "view.edit.option.virtual.available" <> -1);
    ignore (Native_bridge.press (find "view.edit.cancel.virtual"));
    check ~msg:"cancel still closes a lazily loaded editor" (find "view.edit.sheet.virtual" = -1))

let wide_tables_mount_only_visible_cells () =
  let extra = List.init 60 (fun index -> `Assoc ["attr", `String ("user.property/Wide" ^ string_of_int index);
    "title", `String ("Column " ^ string_of_int index); "kind", `String "default"]) in
  let rec widen = function
    | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key,
        if key = "columns" then (match value with `List cols -> `List (cols @ extra) | _ -> value)
        else widen value) fields)
    | `List values -> `List (List.map widen values) | value -> value in
  let response = Json.to_string (widen (Json.from_string (virtual_result_response ~count:101 "table"))) in
  List.iter (fun backend -> Q.with_ui backend response (fun app ->
    let host = Lui_app.runtime app in
    let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
    let first = "view.cell.virtual.virtual-0.block/title" in
    let last = "view.cell.virtual.virtual-0.user.property/Wide59" in
    check ~msg:"the first visible cell is mounted" (find first <> -1);
    check_eq ~msg:"offscreen columns own no native cell nodes" (find last) (-1);
    let viewport = App_test.extension_node app "native-table-viewport" in
    check ~msg:"table scrolling reports the horizontal viewport" (viewport <> -1);
    let fields = Lui_protocol.String_map.empty
      |> Lui_protocol.String_map.add "offset" (Lui_protocol.IntValue 10_500)
      |> Lui_protocol.String_map.add "width" (Lui_protocol.IntValue 390) in
    App_test.dispatch app (Lui_protocol.ExtensionEvent (viewport, "native-table-viewport", "viewport-changed", fields));
    App_test.flush app;
    check ~msg:"horizontal scrolling mounts the last column" (find last <> -1);
    check_eq ~msg:"columns outside the viewport are evicted" (find first) (-1);
    let window = find "view.window.virtual" in
    App_test.dispatch app (Lui_protocol.VisibleRange (window, 95, 100)); App_test.flush app;
    check ~msg:"vertical scrolling preserves the horizontal cell window"
      (find "view.cell.virtual.virtual-100.user.property/Wide59" <> -1);
    check_eq ~msg:"offscreen rows are evicted" (find last) (-1)))
    [App_test.ios_backend; App_test.kotlin_backend]

let table_and_gallery_mount_bounded_windows () =
  List.iter (fun backend -> List.iter (fun typ ->
    Q.with_ui backend (virtual_result_response typ) (fun app ->
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      let window () = find "view.window.virtual" in
      check ~msg:(typ ^ " exposes a virtual collection") (window () <> -1);
      let mounted () = List.length (App_test.children host (window ())) in
      check ~msg:"10k results mount at most one bounded window" (mounted () <= 32);
      check_eq ~msg:"virtual result views need no Show more button" (find ("query.more." ^ owner)) (-1);
      let item index = if typ = "table" then "view.cell.virtual.virtual-" ^ string_of_int index ^ ".block/title"
        else "view.card.virtual.virtual-" ^ string_of_int index in
      check (find (item 0) <> -1);
      check_eq ~msg:"distant results do not own protocol nodes before scrolling" (find (item 10_000)) (-1);
      App_test.dispatch app (Lui_protocol.VisibleRange (window (), 9_990, 10_000)); App_test.flush app;
      check ~msg:"scrolling reaches the final odd result without pagination" (find (item 10_000) <> -1);
      check_eq ~msg:"scrolled-away result scopes are evicted" (find (item 0)) (-1);
      check (mounted () <= 32);
      if typ = "table" then begin
        App_test.dispatch app (Lui_protocol.Press (find ("view.cell.virtual.virtual-10000." ^ ready))); App_test.flush app;
        check ~msg:"distant table cells retain typed editors" (find "view.edit.sheet.virtual" <> -1);
        App_test.dispatch app (Lui_protocol.VisibleRange (window (), 0, 9)); App_test.flush app;
        check ~msg:"evicting a table row does not dismiss its editor" (find "view.edit.sheet.virtual" <> -1);
        App_test.dispatch app (Lui_protocol.Press (find "view.edit.cancel.virtual")); App_test.flush app
      end;
      App_test.dispatch app (Lui_protocol.VisibleRange (window (), 0, 9)); App_test.flush app;
      check ~msg:"returning to the start remounts the original values" (find (item 0) <> -1);
      App_test.dispatch app (Lui_protocol.VisibleRange (window (), -1, -1)); App_test.flush app;
      check (find (item 0) <> -1))) ["table"; "gallery"])
    [App_test.ios_backend; App_test.kotlin_backend]

let virtual_result_windows_follow_search_sort_and_resize () =
  List.iter (fun backend -> List.iter (fun typ ->
    Q.with_ui backend (virtual_result_response ~count:101 typ) (fun app ->
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      let window () = find "view.window.virtual" in
      check ~msg:"result viewport supports native range events" (window () <> -1);
      let metadata key = Lui_protocol.data_attrs_decode (App_test.property_string host (window ()) Lui_protocol.DataAttrs)
        |> List.assoc key |> int_of_string in
      App_test.dispatch app (Lui_protocol.VisibleRange (window (), 90, 100)); App_test.flush app;
      let retained_window = window () in
      (match Response_snapshot.decode_response (virtual_result_response ~count:101 ~ready_value:false typ) with
        | Error message -> fail message | Ok projection -> App_test.send app (Model.ApplyCoreSnapshot projection));
      App_test.flush app;
      check_eq ~msg:"value refreshes preserve the native result window" (window ()) retained_window;
      check ~msg:"editing or remote value changes do not jump back to the first row" (metadata "data-virtual-start" > 0);
      if typ = "table" then check_eq ~msg:"distant values update in the retained window"
        (App_test.property_string host (find ("view.cell.virtual.virtual-100." ^ ready)) Lui_protocol.TextValue) "false";
      let click id = App_test.dispatch app (Lui_protocol.Press (find id)); App_test.flush app in
      click ("view.search.toggle." ^ owner);
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.search." ^ owner), "Object 000")); App_test.flush app;
      check_eq ~msg:"search begins at the first matching row" (metadata "data-virtual-start") 0;
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.search." ^ owner), "missing")); App_test.flush app;
      check ~msg:"empty search removes the scrolling result surface" (window () = -1);
      check (find ("query.empty." ^ owner) <> -1);
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.search." ^ owner), "")); App_test.flush app;
      check_eq (metadata "data-virtual-count") 101;
      App_test.dispatch app (Lui_protocol.VisibleRange (window (), 90, 100)); App_test.flush app;
      let response = virtual_result_response ~count:101 ~input:"descending" ~reverse:true typ in
      (match Response_snapshot.decode_response response with Error message -> fail message
        | Ok projection -> App_test.send app (Model.ApplyCoreSnapshot projection)); App_test.flush app;
      check_eq ~msg:"a changed master sort starts from the first sorted row" (metadata "data-virtual-start") 0;
      if typ = "gallery" then begin
        App_test.send app (Model.ApplyViewportWidth 800); App_test.flush app;
        check_eq ~msg:"wide gallery windows count rows of two cards" (metadata "data-virtual-count") 51;
        App_test.dispatch app (Lui_protocol.VisibleRange (window (), 45, 50)); App_test.flush app;
        check ~msg:"the final unpaired card is reachable" (find "view.card.virtual.virtual-0" <> -1);
        App_test.send app (Model.ApplyViewportWidth 390); App_test.flush app;
        check_eq ~msg:"narrow layouts restore one card per row" (metadata "data-virtual-count") 101
      end)) ["table"; "gallery"])
    [App_test.ios_backend; App_test.kotlin_backend]

let closed_choices_follow_master_on_every_property_type () =
  List.iter (fun typ ->
    let db = Ds.db_with [
      put score_property "logseq.property/type" (Ds.Keyword typ);
      put value_a "block/title" (Ds.String "Later choice");
      put value_b "block/title" (Ds.String "First choice");
      put value_a "block/order" (Ds.String "a2");
      put value_b "block/order" (Ds.String "a0");
      put value_a "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property));
      put value_b "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property));
      put text_a "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property));
      put text_a "block/order" (Ds.String "a1");
      put text_a "logseq.property/deleted-at" (Ds.Int64 1L);
      put text_b "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property));
      put text_b "block/parent" (Ds.Ref_to (ref_uuid text_a));
      put text_b "block/order" (Ds.String "a3");
    ] (fixture ()) in
    let session, _ = make_session ~configured:true db in
    let metadata = Result_view.property_json db ~owner:alpha ~attr:score
      ~encode_block:(fun _ -> `Null) in
    check_eq ~msg:(typ ^ ": closed values preserve order and exclude recycled ancestors")
      (List.map (member "uuid") (items "choices" metadata)) [`String value_b; `String value_a];
    check_eq ~msg:(typ ^ ": a closed property never permits arbitrary creation")
      (member "canCreate" metadata) (`Bool false);
    List.iter (fun backend ->
      Q.open_results session;
      Q.with_ui backend (Session.snapshot_visible session) (fun app ->
        let _host = Lui_app.runtime app in
        let find id = find_visible session app id in
        let click id = let node = find id in check ~msg:id (node <> -1);
          App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
        click ("view.tab." ^ table_view);
        click ("view.cell." ^ table_view ^ "." ^ alpha ^ "." ^ score);
        check ~msg:(typ ^ ": closed values use the shared chooser rather than a free-form or calendar editor")
          (find ("view.edit.option." ^ table_view ^ "." ^ value_b) <> -1);
        check_eq ~msg:(typ ^ ": deleted choices are absent from the chooser")
          (find ("view.edit.option." ^ table_view ^ "." ^ text_a)) (-1);
        click ("view.edit.option." ^ table_view ^ "." ^ value_b);
        let pending = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
        let _, body = Result.get_ok (Core_effect.request ~now:(fun () -> 1) ~fresh_id:(fun () -> "unused")
          (Some (Native_bridge.encode_effect pending))) in
        check_eq ~msg:(typ ^ ": selecting a closed value preserves its stable reference")
          (member "selectedValues" (Json.from_string (Option.get body))) (`List [`String value_b])))
      [App_test.ios_backend; App_test.kotlin_backend])
    ["default"; "url"; "number"; "date"; "datetime"; "page"; "entity"; "node"; "class"; "property"]

let closed_choices_are_scoped_to_the_edited_object () =
  let db = Ds.db_with [
    put alpha "block/tags" (Ds.Ref_to (ref_uuid Q.project));
    put value_a "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property));
    put value_b "block/closed-value-property" (Ds.Ref_to (ref_uuid score_property));
    put value_a "logseq.property/choice-classes" (Ds.Ref_to (ref_uuid Q.project));
    put Q.project "logseq.property/choice-exclusions" (Ds.Ref_to (ref_uuid value_b));
  ] (fixture ()) in
  let choice_ids owner db = Result_view.property_json db ~owner ~attr:score ~encode_block:(fun _ -> `Null)
    |> items "choices" |> List.map (member "uuid") in
  check_eq ~msg:"matching class choices are included and class exclusions hide global choices"
    (choice_ids alpha db) [`String value_a];
  check_eq ~msg:"objects outside a choice's class cannot pick that choice"
    (choice_ids gamma db) [`String value_b];
  let db = Ds.db_with [put value_b "logseq.property/choice-classes" (Ds.Ref_to (ref_uuid Q.project))] db in
  check_eq ~msg:"an explicit matching scope takes precedence over a global exclusion, as on master"
    (List.sort compare (choice_ids alpha db)) (List.sort compare [`String value_a; `String value_b]);
  let empty = Result_view.property_json db ~owner:gamma ~attr:score ~encode_block:(fun _ -> `Null) in
  check_eq (items "choices" empty) [];
  check_eq ~msg:"an empty scoped set remains closed" (member "closed" empty) (`Bool true);
  check_eq (member "canCreate" empty) (`Bool false);
  let invalid = `Assoc ["blockUuid", `String gamma; "attr", `String score; "expected", `Null;
    "value", `String value_a; "create", `Bool true] in
  check ~msg:"direct edits cannot bypass the closed-value scope"
    (try ignore (Result_view.edit_property db ~now:1 ~fresh_uuid:(fun () -> "unused") invalid); false
     with Invalid_argument _ -> true);
  List.iter (fun backend ->
    let session, _ = make_session ~configured:true db in
    Q.open_results session;
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let _host = Lui_app.runtime app in
      let find id = find_visible session app id in
      let click id = let node = find id in check ~msg:id (node <> -1);
        App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      click ("view.tab." ^ table_view);
      click ("view.cell." ^ table_view ^ "." ^ gamma ^ "." ^ score);
      check_eq ~msg:"table cells use the edited row's scope, not the global filter catalog"
        (find ("view.edit.option." ^ table_view ^ "." ^ value_a)) (-1);
      check_eq ~msg:"historical used values do not repopulate an empty closed chooser"
        (find ("view.edit.option." ^ table_view ^ "." ^ value_b)) (-1);
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.edit.value." ^ table_view), "new value"));
      App_test.flush app;
      check_eq (find ("view.edit.create." ^ table_view)) (-1)))
    [App_test.ios_backend; App_test.kotlin_backend]

let table_name_editors_resolve_page_names_and_offer_navigation () =
  List.iter (fun backend -> with_runtime (fun session runtime conn ->
    let stored = "See [[" ^ Q.page ^ "]] **notes**" in
    ignore (Ds.transact_conn conn [put alpha "block/title" (Ds.String stored)]);
    Graph_runtime.rebase runtime 42 [] [alpha];
    Q.with_ui backend (Session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = find_visible session app id in
      let click id = let node = find id in check ~msg:id (node <> -1);
        App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      click ("view.tab." ^ table_view);
      click ("view.cell." ^ table_view ^ "." ^ alpha ^ ".block/title");
      let input = find ("view.edit.value." ^ table_view) in
      check_eq ~msg:"Name editors resolve UUID references while preserving markup"
        (App_test.property_string host input Lui_protocol.TextValue) "See [[Workspace]] **notes**";
      click ("view.edit.open." ^ table_view);
      check ~msg:"Name sheets can navigate to their corresponding node"
        (List.exists (function Model.OpenAppNodeEffect (_, uuid) -> uuid = alpha | _ -> false) (App.model app).pending_effects);
      check_eq ~msg:"navigation dismisses the editor" (find ("view.edit.sheet." ^ table_view)) (-1))))
    [App_test.ios_backend; App_test.kotlin_backend]

let readable_names_roundtrip_without_retargeting_references () = with_runtime (fun session runtime conn ->
  let stored = "See [[" ^ Q.page ^ "]] **notes**" in
  ignore (Ds.transact_conn conn [put alpha "block/title" (Ds.String stored)]);
  Graph_runtime.rebase runtime 42 [] [alpha];
  let cell () =
    let row = List.find (fun row -> member "uuid" (member "block" row) = `String alpha) (items "rows" (find_view table_view (read session))) in
    List.find (fun p -> member "attr" p = `String "block/title") (items "properties" row) in
  let p = cell () in
  check_eq (member "editorValue" p) (`String "See [[Workspace]] **notes**");
  let response = action session (base_action "editCell" table_view @ ["blockUuid", `String alpha;
    "attr", `String "block/title"; "expected", member "raw" p; "value", member "editorValue" p]) in
  check_eq (member "ok" response) (`Bool true);
  let db = Graph_runtime.db runtime in
  let id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid alpha)) in
  check_eq ~msg:"saving readable reference names preserves stored UUIDs" (Graph_read.value db id "block/title") (Some (Ds.String stored));
  ignore (Ds.transact_conn conn (entity 101 "92000000-0000-4000-8000-000000000001" "Workspace" @ [
    put "92000000-0000-4000-8000-000000000001" "block/name" (Ds.String "workspace")]));
  Graph_runtime.rebase runtime 42 [] [alpha];
  let name = Result_view.property_json (Graph_runtime.db runtime) ~owner:alpha ~attr:"block/title" ~encode_block:(fun _ -> `Null) in
  check_eq ~msg:"ambiguous display names keep identity-preserving syntax" (member "editorValue" name) (`String stored))

let cases = [
  case "deferred cell editors load candidates without replacing the page" deferred_cell_editor_loads_without_replacing_the_page;
  case "wide tables mount only cells intersecting the viewport" wide_tables_mount_only_visible_cells;
  case "table Name editors show readable refs and provide navigation" table_name_editors_resolve_page_names_and_offer_navigation;
  case "readable Name references roundtrip without retargeting" readable_names_roundtrip_without_retargeting_references;
  case "all closed property types use ordered live choices and typed selection" closed_choices_follow_master_on_every_property_type;
  case "closed choices follow master class scopes and cannot be bypassed" closed_choices_are_scoped_to_the_edited_object;
  case "list results defer cell data while grids retain typed editors" list_results_defer_cell_editor_data;
  case "hidden filter catalogs do not multiply query mount allocations" hidden_filter_catalog_does_not_multiply_mount_allocations;
  case "table and gallery virtualize 10k results and retain distant cell editors" table_and_gallery_mount_bounded_windows;
  case "virtual result windows follow search sort empty results and gallery resize" virtual_result_windows_follow_search_sort_and_resize;
  case "table Name saves with stale-edit protection while timestamps stay read-only" table_name_is_editable_and_timestamps_are_read_only;
  case "table tags edit typed references and create tag objects" table_tags_are_editable_and_keep_typed_references;
  case "table cells have column dividers and typed editors on both hosts" table_cells_have_column_dividers_on_both_hosts;
  case "compact local timestamps and mobile table metadata order" compact_local_timestamps_and_columns;
  case "empty table cells have accessible names" empty_table_cells_have_accessible_names;
  case "pushed query type changes refresh the visible renderer" pushed_query_type_changes_refresh_the_visible_renderer;
  case "type icons switch saved views and unsaved collections start with All list" type_icons_switch_saved_views_and_default_all;
  case "priority menus use graph choices and edits persist typed references" priority_choices_and_edits_use_the_real_graph;
  case "master filtering sorting and search match all three view scopes" master_conformance;
  case "saved query views isolate invalid configuration" saved_views_and_isolated_failures;
  case "master filters resolve typed values and combine search" typed_filters_and_search;
  case "multi-key sorting and table columns resolve property references" stable_multi_sort_and_property_columns;
  case "tag and property objects use views while references remain unchanged" scopes_and_references;
  case "view settings persist through pending projection and restart" saved_configuration_projects_and_survives_restart;
  case "saved filters preserve nested UUID sets and nullable bounds" settings_preserve_nested_match_values;
  case "many numeric and scalar checkbox and text edits preserve types" many_and_scalar_cells_preserve_types;
  case "table edits assign owner values with validation and conflict checks" editable_cells_use_owner_values_and_conflicts;
  case "both native hosts expose tabs search table editing and gallery" native_view_tabs_search_table_and_gallery;
  case "native settings expose filters sorting and local action errors" native_view_settings_and_local_errors;
  case "native cells refresh and tag property collections mount views" native_cells_refresh_and_object_collections_mount;
  case "tuple tables and query evaluation failures render on both hosts" tuple_table_and_query_errors;
  case "typed edits survive restart and clear after real sync acknowledgements" typed_edits_restart_and_sync_acknowledgements;
  case "date cells accept valid calendar dates and reject impossible dates" date_cells_accept_calendar_dates;
  case "native boolean editing completes the real core effect pipeline" native_boolean_editor_uses_the_real_effect_pipeline;
  case "filter property catalogs survive hidden columns and corrupt sibling settings" available_properties_and_corrupt_filter_isolation;
  case "native view toolbar aligns tabs actions and expandable search to the owning bullet" native_toolbar_alignment_and_search_expansion;
  case "native cell selectors immediately choose and restrict open value creation" native_direct_value_selection_and_creation;
  case "selector references and explicit object creation preserve graph semantics" selected_references_and_explicit_object_creation;
  case "native filter choices preserve master's multi-value UUID sets" native_filter_choices_preserve_master_sets;
  case "native multi-value selection stages choices and creation until Done" native_many_selector_stages_choices_until_done;
]
