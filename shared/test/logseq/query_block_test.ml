open Test_util
module Ds = Datascript
module Json = Yojson.Basic
module Session = Rpc_session
module Types = Session_types

let owner = "10000000-0000-4000-8000-000000000001"
let definition = "10000000-0000-4000-8000-000000000002"
let page = "10000000-0000-4000-8000-000000000003"
let alpha = "10000000-0000-4000-8000-000000000004"
let beta = "10000000-0000-4000-8000-000000000005"
let project = "10000000-0000-4000-8000-000000000006"
let member = Rpc_test.member
let items name json = match member name json with `List xs -> xs | _ -> []
let ref_uuid uuid = Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid)
let put uuid attr value = Ds.Add (ref_uuid uuid, attr, value)

let fixture source =
  let db = match Graph_bootstrap.database "query-tests" false (fun s -> Ok s) with
    | Ok db -> db | Error message -> fail message in
  let schema = ("user.property/score", {Storage_codec.default_schema_attr with
    Ds.indexed = true; value_type = Some Ds.NumberType}) :: db.Ds.schema in
  let db = {db with Ds.schema} in
  let add_entity uuid title = [Ds.Add (Ds.Entity_id (900000 + int_of_string (String.sub uuid 24 12)), "block/uuid", Ds.Uuid uuid);
    put uuid "block/title" (Ds.String title)] in
  let block uuid title order = add_entity uuid title @ [
    put uuid "block/page" (Ds.Ref_to (ref_uuid page));
    put uuid "block/parent" (Ds.Ref_to (ref_uuid page));
    put uuid "block/order" (Ds.String order)] in
  Ds.db_with (add_entity page "Workspace" @ [put page "block/name" (Ds.String "workspace")]
    @ [Ds.Add (Ds.Entity_id 900010, "db/ident", Ds.Keyword "user.property/score");
       Ds.Add (Ds.Entity_id 900010, "block/title", Ds.String "Score");
       Ds.Add (Ds.Entity_id 900010, "block/tags", Ds.Ref_to (Ds.Ident "logseq.class/Property"))]
    @ add_entity project "Project" @ [put project "block/name" (Ds.String "project");
       put project "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Tag"))]
    @ block owner "My query" "a0" @ [
      put owner "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Query"));
      put owner "logseq.property/query" (Ds.Ref_to (ref_uuid definition))]
    @ block definition source "a1"
    @ block alpha "Alpha **result**" "a2" @ [
      put alpha "block/tags" (Ds.Ref_to (ref_uuid project));
      put alpha "block/refs" (Ds.Ref_to (ref_uuid project));
      put alpha "user.property/score" (Ds.Int64 2L)]
    @ block beta "Beta result" "a3" @ [put beta "user.property/score" (Ds.Int64 1L)]) db

let make_session ?(limit = None) db =
  let db = ref db in
  let blocks () = Graph_read.blocks_for_page (fun s -> Ok s) !db page in
  let session = Session.create_session {Session.default_options with
    outliner_projection_limit = limit;
    graph_blocks = Some (fun () -> Some (blocks ()));
    graph_page_blocks = Some (fun _ -> Some (blocks ()))} in
  let model = (Types.state session).model in
  model.Cache_model.db <- !db;
  let set_db value = db := value; model.db <- value; model.revision <- model.revision + 1 in
  session, set_db

let dispatch session action payload = Rpc_test.response_result (Rpc_test.dispatch_json session action payload)
let open_results session =
  ignore (Rpc_test.dispatch_json session "resultView" (Json.to_string (`Assoc [
    "ownerUuid", `String owner; "featureType", `String "query-result";
    "action", `String "setExpanded"; "expanded", `Bool true])))
let query session = member "query" (dispatch session "queryBlock" owner)
let query_source source = let session, _ = make_session (fixture source) in query session
let row_ids query = List.filter_map (fun row -> match member "uuid" (member "block" row) with
  | `String s -> Some s | _ -> None) (items "rows" query) |> List.sort compare
let cells query = List.concat_map (fun row -> items "cells" row) (items "rows" query)
let expect_ids source expected =
  let result = query_source source in
  check_eq ~msg:(Json.to_string result) (member "error" result) `Null;
  check_eq ~msg:source (row_ids result) (List.sort compare expected)

let simple_queries () =
  List.iter (fun source -> expect_ids source [alpha])
    ["#Project"; "[[Project]]"; "(and #Project (not \"Beta\"))";
     "(and (property :user.property/score 2) #Project)";
     "(or #Project \"not found\")"];
  expect_ids "(page Workspace)" [alpha; beta]

let advanced_queries () =
  expect_ids "{:query [:find (pull ?b [*]) :where [?b :user.property/score ?s] [(> ?s 1)]]}" [alpha];
  expect_ids "{:query [:find [?b ...] :where [?b :user.property/score ?s]]}" [alpha; beta];
  let result = query_source "{:query [:find (count ?b) :where [?b :user.property/score]]}" in
  check_eq (cells result) [`String "2"];
  let tuples = query_source "{:query [:find ?t ?s :where [?b :user.property/score ?s] [?b :block/title ?t]]}" in
  check_eq (List.length (items "rows" tuples)) 2;
  check (List.mem (`String "Alpha **result**") (cells tuples))

let contextual_inputs_and_rules () =
  expect_ids "{:query [:find (pull ?b [*]) :in $ ?p :where [?p-e :block/name ?p] [?b :block/page ?p-e] [?b :user.property/score]] :inputs [:query-page]}" [alpha; beta];
  expect_ids "{:query [:find (pull ?b [*]) :in $ ?p :where [?p-e :block/name ?p] [?b :block/page ?p-e] [?b :user.property/score]] :inputs [:current-page]}" [alpha; beta];
  expect_ids "{:query [:find (pull ?b [*]) :in $ % :where (scored ?b)] :rules [[(scored ?b) [?b :user.property/score 2]]]}" [alpha];
  let today = Cache_model.journal_day_for_ms (Session_types.now_ms ()) in
  let result = query_source "{:query [:find ?day . :in $ ?day :where] :inputs [:today]}" in
  check_eq (cells result) [`String (string_of_int today)]

let transforms () =
  expect_ids "{:query [:find (pull ?b [*]) :where [?b :user.property/score]] :result-transform (fn [rows] (take 1 (sort-by :user.property/score rows)))}" [beta];
  let result = query_source "{:query [:find ?s :where [?b :user.property/score ?s]] :result-transform (fn [rows] (map (fn [row] [(inc (first row))]) rows))}" in
  check_eq (List.sort compare (cells result)) [`String "2"; `String "3"]

let invalid_and_empty_queries () =
  List.iter (fun source -> let q = query_source source in
    check ~msg:("expected a query-local error: " ^ source)
      (match member "error" q with `String s -> s <> "" | _ -> false))
    ["(and"; "(unknown-operator foo)"; "{:query [:find ?x :where (missing ?x)]}";
     "{:query [:find ?x :where] :view (fn [x] [:div x])}";
     "{:query [:find ?x :where] :result-transform (fn [rows] (unknown-fn rows))}"];
  check_eq (items "rows" (query_source "#Missing")) [];
  check_eq (member "error" (query_source "")) `Null

let missing_definition_is_isolated () =
  let db = fixture "#Project" in
  let missing = Ds.db_with [Ds.RetractEntity (ref_uuid definition)] db in
  let session, _ = make_session missing in
  let q = query session in
  check (match member "error" q with `String _ -> true | _ -> false);
  let ordinary = member "query" (dispatch session "queryBlock" alpha) in
  check_eq ordinary `Null

let filters_recursive_and_hidden_results () =
  let db = fixture ("{:query [:find (pull ?b [*]) :where [?p :block/uuid #uuid \"" ^ page ^ "\"] [?b :block/page ?p]]}") in
  let db = Ds.db_with [put beta "logseq.property/hide?" (Ds.Bool true)] db in
  let session, _ = make_session db in
  let q = query session in
  check_eq ~msg:(Json.to_string q) (row_ids q) [alpha]

let live_updates_and_hydration () =
  let db = fixture "#Project" in
  let session, set_db = make_session ~limit:(Some 1) db in
  open_results session;
  let snapshot () = Rpc_test.response_result (Json.from_string (Session.snapshot_visible session)) in
  let owner_block response = List.find (fun b -> member "uuid" b = `String owner) (items "blocks" response) in
  check_eq (row_ids (member "query" (owner_block (snapshot ())))) [alpha];
  let db = Ds.db_with [put beta "block/tags" (Ds.Ref_to (ref_uuid project));
    put beta "block/refs" (Ds.Ref_to (ref_uuid project))] db in
  set_db db;
  let q = member "query" (owner_block (snapshot ())) in
  check_eq ~msg:(Json.to_string q) (row_ids q) [alpha; beta];
  let hydrated = dispatch session "hydrateOutlinerRows" (Json.to_string (`List [`String owner])) in
  check_eq (row_ids (member "query" (List.hd (items "hydratedBlocks" hydrated)))) [alpha; beta];
  set_db (Ds.db_with [put definition "block/title" (Ds.String "\"Beta\"")] db);
  check_eq (row_ids (query session)) [beta]

let query_result_block uuid title = `Assoc ["uuid", `String uuid; "title", `String title;
  "pageId", `String page; "markup", `List [`Assoc ["type", `String "text"; "text", `String title]]]

let ui_response ?(collapsed = false) ?(rows = []) ?(error = `Null) () =
  let q = `Assoc ["kind", `String "simple"; "source", `String "#Project";
    "rows", `List rows; "error", error] in
  let block = match query_result_block owner "My query" with `Assoc fields -> `Assoc (("query", q) :: fields) | x -> x in
  Json.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
    "selectedGraphId", `String "test-graph"; "graphName", `String "Query graph";
    "outlinerRows", `List [`Assoc ["block", block; "depth", `Int 0;
      "hasChildren", `Bool false; "isCollapsed", `Bool collapsed]]]])

let with_ui backend response f =
  let app = App.create (backend ()) in
  Fun.protect ~finally:(fun () -> ignore (Lui_app.dispose app)) (fun () ->
    App_test.start app;
    (match Response_snapshot.decode_response response with
     | Error message -> fail message
     | Ok projection -> App_test.send app (Model.ApplyCoreSnapshot projection));
    App_test.flush app;
    f app)

let ui_results_and_navigation () =
  List.iter (fun backend ->
    with_ui backend (ui_response ~rows:[`Assoc ["block", query_result_block alpha "Alpha result"]] ()) (fun app ->
      let runtime = Lui_app.runtime app in
      let root = Lui_app.root_node app in
      let result = App_test.descendant_with_identifier runtime root ("query.result." ^ owner ^ ".0") in
      check ~msg:"query result is mounted on both native hosts" (result <> -1);
      let rendered = App_test.descendant_with_identifier runtime result ("outliner.block." ^ alpha) in
      check ~msg:"results reuse the full block row" (rendered <> -1);
      let native = App_test.descendant_with_extension runtime app rendered "outliner-block-row" in
      if native <> -1 then
        App_test.dispatch app (Lui_protocol.ExtensionEvent (native, "outliner-block-row", "open-node",
          Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue alpha)))
      else App_test.dispatch app (Lui_protocol.Press
        (App_test.descendant_with_identifier runtime rendered ("button.outliner.zoom." ^ alpha ^ ".Alpha result")));
      App_test.flush app;
      check ~msg:"result navigation targets its block"
        (List.exists (function Model.OpenAppNodeEffect (_, uuid) -> uuid = alpha | _ -> false)
           ((App.model app).pending_effects @ (App.model app).in_flight_effects))))
    [App_test.ios_backend; App_test.kotlin_backend]

let ui_states_and_disclosure () =
  let find app suffix = App_test.descendant_with_identifier (Lui_app.runtime app)
    (Lui_app.root_node app) ("query." ^ suffix ^ "." ^ owner) in
  List.iter (fun backend ->
    with_ui backend (ui_response ()) (fun app -> check (find app "empty" <> -1));
    with_ui backend (ui_response ~error:(`String "Invalid query") ())
      (fun app -> check (find app "error" <> -1));
    with_ui backend (ui_response ~collapsed:true ()) (fun app -> check_eq (find app "empty") (-1));
    let rows = List.init 25 (fun i -> `Assoc ["cells", `List [`String (string_of_int i)]]) in
    with_ui backend (ui_response ~rows ()) (fun app ->
      let more = find app "more" in
      check ~msg:"large results initially mount a bounded slice" (more <> -1);
      App_test.dispatch app (Lui_protocol.Press more); App_test.flush app;
      check_eq ~msg:"show more reveals the remaining results" (find app "more") (-1);
      let fold = find app "toggle" in
      check (fold <> -1);
      App_test.dispatch app (Lui_protocol.Press fold); App_test.flush app;
      check_eq (find app "rows") (-1)))
    [App_test.ios_backend; App_test.kotlin_backend]

let task_priority_and_date_queries () =
  let db = fixture "(and (task Todo) (priority High))" in
  let db = Ds.db_with [
    put alpha "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Task"));
    put alpha "logseq.property/status" (Ds.Ref_to (Ds.Ident "logseq.property/status.todo"));
    put alpha "logseq.property/priority" (Ds.Ref_to (Ds.Ident "logseq.property/priority.high"))] db in
  let session, set_db = make_session db in
  check_eq ~msg:(Json.to_string (query session)) (row_ids (query session)) [alpha];
  let today = Cache_model.journal_day_for_ms (Types.now_ms ()) in
  let db = Ds.db_with [put page "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Journal"));
    put page "block/journal-day" (Ds.Int64 (Int64.of_int today));
    put definition "block/title" (Ds.String "(between today today)")] db in
  set_db db;
  check_eq (row_ids (query session)) [alpha; beta]

let projected_database_is_authoritative_for_queries () =
  Graph_runtime_test.with_store (fun path ->
    let db = fixture "\"Beta\"" in
    let conn = Ds.conn_from_db db in
    let runtime = Graph_runtime.create path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
    let session = Session.create_session {Session.default_options with
      graph_db = Some (fun () -> Some (Graph_runtime.db runtime));
      graph_blocks = Some (fun () -> Some (Graph_runtime.blocks_for_page runtime page))} in
    check_eq (row_ids (query session)) [beta];
    let operation = {Pending_ops.operation_id = "query-edit"; base_t = 42; state = Pending_ops.Queued;
      intent = Pending_ops.Save_title {uuid = beta; expected_title = "Beta result"; title = "Gamma result"}} in
    check_ok (Graph_runtime.stage runtime operation);
    check_eq ~msg:"queries see pending edits instead of the confirmed DB" (row_ids (query session)) [];
    check_eq (Graph_read.string_value (Graph_read.value (Ds.conn_db conn)
      (Option.get (Ds.entid db "block/uuid" (Ds.Uuid beta))) "block/title")) (Some "Beta result");
    ignore (Ds.transact_conn conn [put alpha "block/title" (Ds.String "Beta from remote")]);
    Graph_runtime.rebase runtime 43 [] [alpha];
    check_eq ~msg:"remote changes re-evaluate over the remaining pending projection" (row_ids (query session)) [alpha];
    Graph_runtime_test.cleanup_store path)

let invalid_advanced_options_are_rejected () =
  List.iter (fun option ->
    let q = query_source ("{:query [:find ?b :where [?b :user.property/score]] " ^ option ^ "}") in
    check ~msg:("invalid query options: " ^ option ^ " -> " ^ Json.to_string q)
      (match member "error" q with `String _ -> true | _ -> false))
    [":inputs \"invalid\""; ":rules \"invalid\""; ":remove-block-children? \"invalid\""]

let query_results_do_not_recurse () =
  let db = fixture "(page Workspace)" in
  let db = Ds.db_with [put beta "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Query"));
    put beta "logseq.property/query" (Ds.Ref_to (ref_uuid definition))] db in
  let session, _ = make_session db in
  open_results session;
  let response = Rpc_test.response_result (Json.from_string (Session.snapshot_visible session)) in
  let block = List.find (fun b -> member "uuid" b = `String owner) (items "blocks" response) in
  let results = items "rows" (member "query" block) in
  check_eq (List.length results) 2;
  List.iter (fun row -> check_eq (member "query" (member "block" row)) `Null) results

let result_body_taps_edit_blocks () =
  List.iter (fun backend ->
    with_ui backend (ui_response ~rows:[`Assoc ["block", query_result_block alpha "Alpha result"]] ()) (fun app ->
      let runtime = Lui_app.runtime app in
      let result = App_test.descendant_with_identifier runtime (Lui_app.root_node app) ("query.result." ^ owner ^ ".0") in
      let native = App_test.descendant_with_extension runtime app result "outliner-block-row" in
      let content, extension = if native <> -1 then native, "outliner-block-row" else
        App_test.descendant_with_extension runtime app result "outliner-block-content", "outliner-block-content" in
      check (content <> -1);
      App_test.dispatch app (Lui_protocol.ExtensionEvent (content, extension, "edit",
        Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue alpha)));
      App_test.flush app;
      check_eq (App.model app).outliner_editing None;
      check ~msg:"tapping result text uses the ordinary block editing pipeline"
        (List.exists (function Model.TapOutlinerBlockEffect (_, uuid) -> uuid = alpha | _ -> false)
          ((App.model app).pending_effects @ (App.model app).in_flight_effects))))
    [App_test.ios_backend; App_test.kotlin_backend]

let result_list_breadcrumbs_and_local_children () =
  let child = query_result_block beta "Child result" in
  let block = match query_result_block alpha "Parent result" with
    | `Assoc fields -> `Assoc (("children", `List [child]) ::
        ("breadcrumbs", `List [`Assoc ["uuid", `String page; "title", `String "Workspace"]]) :: fields)
    | x -> x in
  List.iter (fun backend ->
    with_ui backend (ui_response ~rows:[`Assoc ["block", block]] ()) (fun app ->
      let runtime = Lui_app.runtime app in
      let root = Lui_app.root_node app in
      let result = App_test.descendant_with_identifier runtime root ("query.result." ^ owner ^ ".0") in
      check ~msg:"list rows show native navigable breadcrumbs"
        (App_test.descendant_with_identifier runtime result "breadcrumb.related-blocks" <> -1);
      let find uuid = App_test.descendant_with_identifier runtime result ("outliner.block." ^ uuid) in
      check (find alpha <> -1);
      check_eq ~msg:"children start folded" (find beta) (-1);
      let toggle () =
        let native = App_test.descendant_with_extension runtime app (find alpha) "outliner-block-row" in
        if native <> -1 then App_test.dispatch app (Lui_protocol.ExtensionEvent
          (native, "outliner-block-row", "collapse",
            Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue alpha)))
        else App_test.dispatch app (Lui_protocol.Press
          (App_test.descendant_with_identifier runtime (find alpha) ("button.outliner.collapse." ^ alpha)));
        App_test.flush app in
      toggle ();
      check ~msg:"expansion reveals full child blocks" (find beta <> -1);
      check ~msg:"result folding does not change source outline folding"
        (not (List.exists (function Model.ToggleOutlinerCollapsedEffect _ -> true | _ -> false)
          ((App.model app).pending_effects @ (App.model app).in_flight_effects)));
      toggle ();
      check_eq (find beta) (-1))) [App_test.ios_backend; App_test.kotlin_backend]

let cross_page_session () =
  let other = "10000000-0000-4000-8000-000000000007" in
  let db = fixture "#Project" in
  let db = Ds.db_with [Ds.Add (Ds.Entity_id 900007, "block/uuid", Ds.Uuid other);
    put other "block/title" (Ds.String "Other page"); put other "block/name" (Ds.String "other page");
    put alpha "block/page" (Ds.Ref_to (ref_uuid other));
    put alpha "block/parent" (Ds.Ref_to (ref_uuid other));
    put beta "block/page" (Ds.Ref_to (ref_uuid other));
    put beta "block/parent" (Ds.Ref_to (ref_uuid alpha))] db in
  let session = Session.create_session {Session.default_options with
    load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
    graph_db = Some (fun () -> Some db);
    graph_blocks = Some (fun () -> Some (Graph_read.blocks_for_page (fun s -> Ok s) db page));
    graph_page_blocks = Some (fun uuid -> Some (Graph_read.blocks_for_page (fun s -> Ok s) db uuid))} in
  let session = Rpc_test.configure_plain_session session in
  open_results session;
  session

let cross_page_result_actions () =
  let session = cross_page_session () in
  let event fields = Rpc_test.outliner_event session (Json.to_string (`Assoc fields)) in
  ignore (event ["type", `String "longPressBlock"; "uuid", `String alpha]);
  let copied = event ["type", `String "toolbar"; "action", `String "copy"] in
  check ~msg:"select bar copies the actual result from another page"
    (List.exists (fun command ->
      if member "type" command <> `String "setClipboardBlocks" then false else
      match member "text" command with
      | `String payload ->
        let payload = Json.from_string payload in
        let markdown = match member "plainText" payload with `String text -> text | _ -> "" in
        String_kit.index_of ~sub:"- Alpha **result**" ~start:0 markdown <> None
        && String_kit.index_of ~sub:"\t- Beta result" ~start:0 markdown <> None
      | _ -> false)
      (items "outlinerCommands" copied));
  let edited = event ["type", `String "tapBlock"; "uuid", `String alpha] in
  check_eq ~msg:"result editing resolves blocks outside the visible page"
    (member "uuid" (member "editing" (member "outlinerState" edited))) (`String alpha);
  let response = Rpc_test.response_result (Json.from_string (Session.snapshot_visible session)) in
  check ~msg:"loading result action targets does not duplicate them into the main outline"
    (not (List.exists (fun row -> member "uuid" (member "block" row) = `String alpha) (items "outlinerRows" response)));
  let owner = List.find (fun block -> member "uuid" block = `String owner) (items "blocks" response) in
  let result = List.hd (items "rows" (member "query" owner)) in
  check_eq ~msg:"result trees include nonmatching children"
    (List.map (member "uuid") (items "children" (member "block" result))) [`String beta]

let result_selection_toolbar () =
  List.iter (fun backend ->
    let session = cross_page_session () in
    with_ui backend (Session.snapshot_visible session) (fun app ->
      let runtime = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier runtime (Lui_app.root_node app) id in
      let result = find ("query.result." ^ owner ^ ".0") in
      check ~msg:"real session query result is visible" (result <> -1);
      let native = App_test.descendant_with_extension runtime app result "outliner-block-row" in
      if native <> -1 then App_test.dispatch app (Lui_protocol.ExtensionEvent
        (native, "outliner-block-row", "long-press",
          Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue alpha)))
      else App_test.dispatch app (Lui_protocol.ExtensionEvent
        (App_test.descendant_with_extension runtime app result "outliner-block-content",
          "outliner-block-content", "drag-start",
          Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue alpha)));
      App_test.flush app;
      check ~msg:"result long press enters normal selection"
        (List.exists (function Model.LongPressOutlinerBlockEffect (_, uuid) -> uuid = alpha | _ -> false)
          ((App.model app).pending_effects @ (App.model app).in_flight_effects));
      let response = Json.to_string (Rpc_test.dispatch_json session "outlinerEvent"
        (Json.to_string (`Assoc ["type", `String "longPressBlock"; "uuid", `String alpha]))) in
      (match Response_snapshot.decode_response response with
       | Error message -> fail message
       | Ok projection -> App_test.send app (Model.ApplyCoreSnapshot projection));
      App_test.flush app;
      check ~msg:"selecting a result displays the shared select bar" (find "toolbar.outliner.selection" <> -1);
      check ~msg:"selected result uses full block selection styling"
        (App_test.property_bool runtime (find ("outliner.block." ^ alpha)) Lui_protocol.Selected);
      App_test.dispatch app (Lui_protocol.Press (find "button.outliner.selection.copy"));
      App_test.flush app;
      check (List.exists (function Model.OutlinerToolbarEffect (_, "copy") -> true | _ -> false)
        ((App.model app).pending_effects @ (App.model app).in_flight_effects))))
    [App_test.ios_backend; App_test.kotlin_backend]

let interactive_patches_refresh_query_results () =
  let db = fixture "\"Beta\"" in
  let session, set_db = make_session db in
  open_results session;
  let before = match Response_snapshot.decode_response (Session.snapshot_visible session) with
    | Ok value -> Model.update (Model.initial ()) (Model.ApplyCoreSnapshot value)
    | Error message -> fail message in
  let row_query model =
    let row = List.find (fun row -> row.Model.row_uuid = owner) model.Model.outliner_rows in
    Json.from_string row.query_json in
  check_eq (row_ids (row_query before)) [beta];
  set_db (Ds.db_with [put beta "block/title" (Ds.String "Gamma result")] db);
  let patch = Session.outliner_patch session (Session.outliner_context session) [beta] in
  let after = match Response_snapshot.decode_response patch with
    | Ok value -> Model.update before (Model.ApplyCoreSnapshot value)
    | Error message -> fail message in
  check_eq ~msg:"editing another row must update the query without reopening its page"
    (row_ids (row_query after)) []

let current_query_children_remain_visible () =
  let db = fixture "(page Workspace)" in
  let db = Ds.db_with [put alpha "block/parent" (Ds.Ref_to (ref_uuid owner))] db in
  let session, set_db = make_session db in
  check_eq ~msg:"excluding the owner must not exclude its matching children" (row_ids (query session)) [alpha; beta];
  let db = Ds.db_with [put beta "block/parent" (Ds.Ref_to (ref_uuid alpha))] db in
  set_db db;
  check_eq (row_ids (query session)) [alpha];
  set_db (Ds.db_with [put definition "block/title" (Ds.String "{:query (page Workspace) :remove-block-children? false}")] db);
  check_eq (row_ids (query session)) [alpha; beta]

let collapsed_queries_do_not_evaluate_until_opened () =
  let session, set_db = make_session (fixture "{:query [:find ?x :where (unsupported ?x)]}") in
  ignore (Rpc_test.configure_plain_session session);
  let current () =
    let response = Session.snapshot_visible session |> Json.from_string |> Rpc_test.response_result in
    let block = List.find (fun b -> member "uuid" b = `String owner) (items "blocks" response) in
    member "query" block in
  let folded = current () in
  check_eq ~msg:"query results start collapsed" (member "expanded" folded) (`Bool false);
  check_eq ~msg:"collapsed queries do not evaluate invalid query definitions" (member "error" folded) `Null;
  check_eq (items "rows" folded) [];
  let expand value = Rpc_test.dispatch_json session "resultView" (Json.to_string (`Assoc [
    "ownerUuid", `String owner; "featureType", `String "query-result";
    "action", `String "setExpanded"; "expanded", `Bool value])) in
  let opened = expand true in
  check_eq (member "ok" opened) (`Bool true);
  check ~msg:"query errors are evaluated only on explicit expansion" (match member "error" (current ()) with `String _ -> true | _ -> false);
  ignore (expand false);
  set_db (fixture "#Project");
  check_eq (member "expanded" (current ())) (`Bool false);
  check_eq (items "rows" (current ())) [];
  ignore (expand true);
  check_eq ~msg:"reopening evaluates the current graph rather than stale results" (row_ids (current ())) [alpha];
  List.iter (fun backend ->
    ignore (expand false);
    with_ui backend (Session.snapshot_visible session) (fun app ->
      let runtime = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier runtime (Lui_app.root_node app) id in
      let block = find ("outliner.block." ^ owner) in
      check ~msg:"folding results preserves the ordinary query block" (block <> -1);
      let native = App_test.descendant_with_extension runtime app block "outliner-block-row" in
      let content = if native <> -1 then native else
        App_test.descendant_with_extension runtime app block "outliner-block-content" in
      check ~msg:"the query owner keeps the normal block renderer" (content <> -1);
      check_eq (find ("query.result." ^ owner ^ ".0")) (-1);
      App_test.dispatch app (Lui_protocol.Press (find ("query.toggle." ^ owner))); App_test.flush app;
      check ~msg:"expanding requests results through the core boundary"
        (List.exists (function Model.ResultViewEffect (_, id, payload) -> id = owner &&
          member "action" (Json.from_string payload) = `String "setExpanded" | _ -> false)
          (App.model app).pending_effects))) [App_test.ios_backend; App_test.kotlin_backend]

let cases = [
  case "queries stay unevaluated until expanded and refresh when reopened" collapsed_queries_do_not_evaluate_until_opened;
  case "result lists render breadcrumbs and independently folded children" result_list_breadcrumbs_and_local_children;
  case "cross-page results retain editing and select bar actions" cross_page_result_actions;
  case "result long press displays the functional shared selection toolbar" result_selection_toolbar;
  case "query children survive owner filtering and honor nested result options" current_query_children_remain_visible;
  case "interactive patches refresh unchanged query owners" interactive_patches_refresh_query_results;
  case "task priority and relative date queries use DB properties" task_priority_and_date_queries;
  case "queries share pending and remote graph projections" projected_database_is_authoritative_for_queries;
  case "malformed advanced options produce local errors" invalid_advanced_options_are_rejected;
  case "query blocks returned as results do not recurse" query_results_do_not_recurse;
  case "native result body taps edit full blocks" result_body_taps_edit_blocks;
  case "simple queries execute against DB graph semantics" simple_queries;
  case "advanced queries display blocks aggregates and tuples" advanced_queries;
  case "dynamic inputs and user rules resolve in query context" contextual_inputs_and_rules;
  case "result transforms operate on real query rows" transforms;
  case "invalid and empty queries stay local" invalid_and_empty_queries;
  case "missing definitions and ordinary blocks are isolated" missing_definition_is_isolated;
  case "results filter hidden definition and current blocks" filters_recursive_and_hidden_results;
  case "snapshots and hydration follow live database and definition updates" live_updates_and_hydration;
  case "both native hosts render query results and navigate" ui_results_and_navigation;
  case "both native hosts render states fold and show more" ui_states_and_disclosure;
]
