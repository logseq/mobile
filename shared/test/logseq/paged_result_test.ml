open Test_util
module R = Result_view_test
module Q = Query_block_test
module D = Datascript
module J = Yojson.Basic
let member = Q.member
let items = Q.items
let text = R.text
let uuid index = Printf.sprintf "93000000-0000-4000-8000-%012d" index
let with_rows f = R.with_runtime ~projection_limit:32 (fun session runtime conn ->
  let tx = List.init 1000 (fun index ->
    R.entity (1000 + index) (uuid index) (Printf.sprintf "Paged %04d" index) @ [
      Q.put (uuid index) "block/refs" (D.Ref_to (Q.ref_uuid Q.project));
      Q.put (uuid index) "block/page" (D.Ref_to (Q.ref_uuid Q.page));
      Q.put (uuid index) "block/parent" (D.Ref_to (Q.ref_uuid Q.page));
      Q.put (uuid index) "block/order" (D.String (Printf.sprintf "b%04d" index))])
    |> List.fold_left (fun acc tx -> List.rev_append tx acc) [] |> List.rev in
  ignore (D.transact_conn conn (tx @ [Q.put (uuid 999) "logseq.property/icon" (D.Map [
    D.Keyword "type", D.Keyword "emoji"; D.Keyword "id", D.String "wave"])]));
  Graph_runtime.rebase runtime 43 [] [];
  f session runtime conn)
let query snapshot =
  let result = Rpc_test.response_result (J.from_string snapshot) in
  List.find (fun block -> member "uuid" block = `String R.owner) (items "blocks" result) |> member "query"
let read_window session ?(input = "") ?(view = R.table_view) ?(offset = 0) ?(limit = 12) extra =
  Rpc_test.dispatch_json session "resultRows" (J.to_string (`Assoc ([
    "key", `String "test-window"; "ownerUuid", `String R.owner; "featureType", `String "query-result";
    "viewUuid", `String view; "offset", `Int offset; "limit", `Int limit; "input", `String input] @ extra)))
let window response = member "view" (member "resultRows" (member "result" response))

let snapshots_and_reads_are_bounded_and_keep_master_membership () = with_rows (fun session runtime _ ->
  let initial = query (Rpc_session.snapshot_visible session) in
  check ~msg:"snapshots do not serialize the legacy full query result alongside saved views" (List.length (items "rows" initial) <= 12);
  let views = items "views" initial in
  check ~msg:"only the initial view includes a bounded row window"
    (List.fold_left (fun count view -> count + List.length (items "rows" view)) 0 views <= 12);
  List.iter (fun view -> if member "error" view = `Null then
    check_eq ~msg:"the scroll extent describes all matching results" (member "rowCount" view) (`Int 1003)) views;
  let full = R.find_view R.table_view (R.read session) |> R.ids in
  let response = read_window session ~offset:995 [] in
  check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true);
  let page = window response in
  check_eq (member "rowCount" page) (`Int 1003);
  check_eq ~msg:"windowing follows the saved sort and filter, never an independent ordering"
    (R.ids page) (List.filteri (fun index _ -> index >= 995) full);
  let response = read_window session ~input:"Paged 0999" [] in
  check_eq ~msg:"search covers rows outside the loaded window" (R.ids (window response)) [`String (uuid 999)];
  check_eq (member "rowCount" (window response)) (`Int 1);
  check_eq (member "ok" (read_window session ~view:"missing" [])) (`Bool false);
  check_eq ~msg:"large page requests are bounded by the core" (List.length (items "rows" (window (read_window session ~limit:10000 [])))) 64;
  check_eq ~msg:"a range past the end returns no rows" (items "rows" (window (read_window session ~offset:2000 []))) [];
  check_eq ~msg:"old-graph window requests cannot read the active graph"
    (member "ok" (read_window session ["graphId", `String "another-graph"])) (`Bool false);
  check_eq ~msg:"window reads never stage graph writes" (Graph_runtime.pending_operations runtime) [])

let native_ranges_load_rows_and_ignore_obsolete_requests () =
  List.iter (fun (platform, host) -> with_rows (fun session runtime conn ->
    ignore (Native_bridge.initialize platform host 3);
    Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ())) (fun () ->
      ignore (Native_bridge.apply_response (Rpc_session.snapshot_visible session));
      let app = Native_bridge.app () in
      let backend = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier backend (Lui_app.root_node app) id in
      let click id = check ~msg:id (find id <> -1); ignore (Native_bridge.press (find id)) in
      let pending () = (App.model app).pending_effects |> List.filter (fun eff ->
        member "kind" (J.from_string (Native_bridge.encode_effect eff)) = `String "load-result-rows") in
      let drain () = List.iter (fun eff ->
        let encoded = J.from_string (Native_bridge.encode_effect eff) in
        let id = Model.effect_id eff in
        App_test.send app (Model.DequeueEffect id);
        let response = Core_effect_test.execute session "load-result-rows" ["text", member "text" encoded] in
        check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true);
        ignore (Native_bridge.apply_response (J.to_string response));
        App_test.send app (Model.ResolveEffect (id, true, J.to_string response)); App_test.flush app) (pending ()) in
      click ("view.tab." ^ R.table_view); drain ();
      let surface () = find ("view.window." ^ R.table_view) in
      check ~msg:"paged rows use the shared native virtual list" (surface () <> -1);
      let scroll first last = App_test.dispatch app (Lui_protocol.VisibleRange (surface (), first, last)); App_test.flush app in
      scroll 950 958;
      check_eq ~msg:"scrolling requests one bounded window" (List.length (pending ())) 1;
      check ~msg:"scrolling reads do not insert a loading indicator above the view"
        (find ("view.rows.loading." ^ R.table_view) = -1);
      check ~msg:"existing rows remain mounted while the next window is pending"
        (find ("view.cell." ^ R.table_view ^ "." ^ R.alpha ^ ".block/title") <> -1);
      scroll 900 908;
      check_eq ~msg:"rapid scrolling coalesces while a read is pending" (List.length (pending ())) 1;
      let before = (App.model app).outliner_rows in
      drain (); drain ();
      check_eq ~msg:"window replies do not replace the surrounding page" (App.model app).outliner_rows before;
      let desired = R.find_view R.table_view (R.read session) |> items "rows" |> List.nth_opt in
      let row = Option.get (desired 900) |> member "block" |> member "uuid" |> text in
      check ~msg:"the latest visible range replaces the old window"
        (find ("view.cell." ^ R.table_view ^ "." ^ row ^ ".block/title") <> -1);
      check ~msg:"the first window no longer owns UI cells"
        (find ("view.cell." ^ R.table_view ^ "." ^ R.alpha ^ ".block/title") = -1);
      let id = Option.get (D.entid (Graph_runtime.db runtime) "block/uuid" (D.Uuid row)) in
      ignore (D.transact_conn conn [D.Add (D.Entity_id id, "block/title", D.String "Revised far row")]);
      Graph_runtime.rebase runtime 44 [] [row];
      ignore (Native_bridge.apply_response (Rpc_session.snapshot_visible session));
      check ~msg:"a graph revision invalidates windows even when the first rows did not change" (pending () <> []);
      drain ();
      check_eq ~msg:"the current viewport receives revised data without returning to the first row"
        (App_test.property_string backend (find ("view.cell." ^ R.table_view ^ "." ^ row ^ ".block/title")) Lui_protocol.TextValue) "Revised far row";
      click ("view.search.toggle." ^ R.owner);
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.search." ^ R.owner), "Paged 0999")); App_test.flush app;
      drain ();
      check ~msg:"search requests the full core scope rather than filtering the loaded rows"
        (find ("view.cell." ^ R.table_view ^ "." ^ uuid 999 ^ ".block/title") <> -1);
      check_eq ~msg:"search resets the requested range as well as the native scroll position" (pending ()) [];
      App_test.dispatch app (Lui_protocol.TextChanged (find ("view.search." ^ R.owner), "Paged 0888")); App_test.flush app;
      let failed = List.hd (pending ()) in
      let id = Model.effect_id failed in
      App_test.send app (Model.DequeueEffect id);
      App_test.send app (Model.ResolveEffect (id, false, "Read failed")); App_test.flush app;
      check ~msg:"failed range reads offer a local retry" (find ("view.rows.retry." ^ R.table_view) <> -1);
      click ("view.rows.retry." ^ R.table_view); drain ();
      check ~msg:"retry replaces the failed range with real rows"
        (find ("view.cell." ^ R.table_view ^ "." ^ uuid 888 ^ ".block/title") <> -1))))
    [2, 2; 3, 4]

let list_and_resized_gallery_reach_the_final_page () =
  List.iter (fun (platform, host) -> with_rows (fun session runtime conn ->
    ignore (Native_bridge.initialize platform host 3);
    Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ())) (fun () ->
      ignore (Native_bridge.apply_response (Rpc_session.snapshot_visible session));
      let app = Native_bridge.app () in
      let backend = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier backend (Lui_app.root_node app) id in
      let has_wave () = Hashtbl.fold (fun node extension found -> found ||
        List.mem extension ["node-icon"; "outliner-block-row"] && (match App_test.extension_property app node "payload" with
          | Some (Lui_protocol.StringValue value) ->
            let json = J.from_string value in
            member "id" (if extension = "node-icon" then json else member "nodeIcon" json) = `String "wave" | _ -> false))
        backend.Lui_runtime.runtime_extension_nodes false in
      let drain () = List.iter (fun eff ->
        let encoded = J.from_string (Native_bridge.encode_effect eff) in
        if member "kind" encoded = `String "load-result-rows" then (
          let id = Model.effect_id eff in App_test.send app (Model.DequeueEffect id);
          let response = Core_effect_test.execute session "load-result-rows" ["text", member "text" encoded] in
          check_eq (member "ok" response) (`Bool true);
          ignore (Native_bridge.apply_response (J.to_string response));
          App_test.send app (Model.ResolveEffect (id, true, J.to_string response)); App_test.flush app)) (App.model app).pending_effects in
      let scroll view first last =
        let node = find ("view.window." ^ view) in
        check ~msg:"every paged layout reports its native visible range" (node <> -1);
        App_test.dispatch app (Lui_protocol.VisibleRange (node, first, last)); App_test.flush app; drain () in
      check ~msg:"the first snapshot does not preload distant row icons"
        (View_base.node_icon (App.model app) (uuid 999) = "");
      scroll R.list_view 995 1002;
      check ~msg:"list results can load the final objects" (find ("query.result." ^ R.owner ^ ".1002") <> -1);
      check ~msg:"newly loaded list rows retain their custom icons" (has_wave ());
      ignore (Native_bridge.apply_response (J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
        "isQueryPatch", `Bool true; "nodeIcons", `Assoc [uuid 999, `Assoc ["type", `String "emoji"; "id", `String "fire"]];
        "resultRows", `Assoc ["key", `String "another-graph:rows:stale"; "view", `Assoc []]]])));
      check ~msg:"late replies from another graph cannot replace current row icons" (has_wave ());
      ignore (D.transact_conn conn [D.Retract (Q.ref_uuid (uuid 999), "logseq.property/icon", None)]);
      Graph_runtime.rebase runtime 44 [] [uuid 999];
      ignore (Native_bridge.apply_response (Rpc_session.snapshot_visible session)); drain ();
      check ~msg:"refreshing a row also removes its deleted custom icon" (not (has_wave ()));
      ignore (Native_bridge.press (find ("view.tab." ^ R.gallery_view))); drain ();
      App_test.send app (Model.ApplyViewportWidth 800); App_test.flush app;
      scroll R.gallery_view 500 501;
      let last = R.find_view R.gallery_view (R.read session) |> items "rows" |> List.rev |> List.hd |> member "block" |> member "uuid" |> text in
      check ~msg:"the unpaired final gallery card survives two-column paging"
        (find ("view.card." ^ R.gallery_view ^ "." ^ last) <> -1)))) [2, 2; 3, 4]

let tag_routes_do_not_duplicate_members_in_legacy_payloads () = with_rows (fun session runtime conn ->
  ignore (D.transact_conn conn (List.init 1000 (fun index ->
    Q.put (uuid index) "block/tags" (D.Ref_to (Q.ref_uuid Q.project)))));
  Graph_runtime.rebase runtime 44 [] [];
  let response = Rpc_test.dispatch_json session "openNode" (J.to_string (`Assoc ["uuid", `String Q.project])) in
  check_eq (member "ok" response) (`Bool true);
  let result = member "result" response in
  let route = List.find (fun route -> member "uuid" route = `String Q.project) (items "nodeRoutes" result) in
  List.iter (fun attr -> check_eq ~msg:("paged tag members are not duplicated in " ^ attr) (items attr route) [])
    ["relatedBlocks"; "linkedReferenceBlocks"; "blocks"];
  let view = List.hd (items "views" (member "resultViews" route)) in
  check_eq (member "rowCount" view) (`Int 1001);
  check_eq (List.length (items "rows" view)) 12;
  let tapped = Rpc_test.dispatch_json session "outlinerEvent"
    (J.to_string (`Assoc ["type", `String "tapBlock"; "uuid", `String (uuid 999)])) in
  check_eq (member "ok" tapped) (`Bool true);
  let active = List.find (fun route -> member "uuid" route = `String Q.project) (items "nodeRoutes" (member "result" tapped)) in
  check_eq ~msg:"tag list interactions reuse on-demand outliner context loading"
    (member "uuid" (member "editing" (member "outlinerState" active))) (`String (uuid 999)))

let object_page_views_mount_on_both_hosts () =
  List.iter (fun backend -> List.iter (fun is_tag -> List.iter (fun pushed -> List.iter (fun typ ->
    let collection = `Assoc ["ownerUuid", `String "object-owner";
      "featureType", `String (if is_tag then "class-objects" else "property-objects");
      "views", `List [`Assoc ["uuid", `String "object-view"; "name", `String "All"; "type", `String typ;
        "columns", `List [`Assoc ["attr", `String "block/title"; "title", `String "Name"]];
        "rowsDeferred", `Bool true; "rowCount", `Int 1000; "rowOffset", `Int 0;
        "rows", `List [`Assoc ["block", Q.query_result_block "first-object" "First object"]]]]] in
    let page = `Assoc ["uuid", `String "object-owner"; "title", `String "Objects"] in
    let fields = if pushed then ["nodeRoutes", `List [`Assoc ["uuid", `String "object-owner";
      "page", page; "isTag", `Bool is_tag; "isProperty", `Bool (not is_tag); "resultViews", collection]]]
      else ["selectedPage", page; "selectedPageIsTag", `Bool is_tag;
        "selectedPageIsProperty", `Bool (not is_tag); "resultViews", collection] in
    Q.with_ui backend (J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc (
      ["selectedGraphId", `String "object-pages"; "graphName", `String "Objects"] @ fields)])) (fun app ->
      if pushed then (App_test.send app (Model.RequestAppNode "object-owner"); App_test.flush app);
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      check ~msg:"tag and property views mount in root and pushed page surfaces" (find "page.results" <> -1);
      check ~msg:"object pages expose their own virtual viewport" (find "view.window.object-view" <> -1);
      let rec nested_in_outliner node =
        (App_test.property_string host node Lui_protocol.AccessibilityIdentifier = "list.outliner"
          && App_test.descendant_with_identifier host node "view.window.object-view" <> -1)
        || List.exists nested_in_outliner (App_test.children host node) in
      check ~msg:"object pages do not wrap their viewport in the outliner scroll view"
        (not (nested_in_outliner (Lui_app.root_node app)))))
    ["table"; "list"; "gallery"]) [false; true]) [false; true]) [App_test.ios_backend; App_test.kotlin_backend]

let cases = [
  case "snapshots and row reads are bounded after master sorting filtering and search" snapshots_and_reads_are_bounded_and_keep_master_membership;
  case "native visible ranges page shared rows and coalesce obsolete requests" native_ranges_load_rows_and_ignore_obsolete_requests;
  case "paged lists and resized galleries reach the final unpaired result" list_and_resized_gallery_reach_the_final_page;
  case "tag route snapshots omit hidden legacy member payloads" tag_routes_do_not_duplicate_members_in_legacy_payloads;
  case "tag and property views mount on root and pushed pages on both hosts" object_page_views_mount_on_both_hosts;
]
