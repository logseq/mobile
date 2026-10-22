open Test_util
module Ds = Datascript
module J = Yojson.Basic
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let items = Q.items
let put = Q.put
let properties response = items "properties" (member "nodeProperties" response)
let property attr response = List.find (fun p -> member "attr" p = `String attr) (properties response)
let read session uuid = Rpc_test.dispatch_json session "nodeProperties" uuid
let result response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true); member "result" response
let edit session uuid p value extra =
  Rpc_test.dispatch_json session "nodeProperty" (J.to_string (`Assoc ([
    "blockUuid", `String uuid; "attr", member "attr" p; "expected", member "raw" p;
    "value", `String value] @ extra)))

let projection_and_navigation () =
  let db = R.fixture () in
  let db = Ds.db_with [put Q.page R.summary (Ds.Ref_to (Q.ref_uuid R.text_b));
    put R.text_a "block/page" (Ds.Ref_to (Q.ref_uuid Q.page));
    put R.text_a "block/parent" (Ds.Ref_to (Q.ref_uuid Q.alpha));
    put R.text_a "block/order" (Ds.String "a0");
    put Q.project "logseq.property.class/properties" (Ds.Ref_to (Ds.Ident R.ready));
    put Q.project "logseq.property.class/properties" (Ds.Ref_to (Ds.Ident R.summary));
    put Q.project "logseq.property.class/extends" (Ds.Ref_to (Q.ref_uuid Q.project))] db in
  let session, _ = R.make_session db in
  let page = result (read session Q.page) in
  check_eq (member "text" (property R.summary page)) (`String "Writing");
  let block = result (read session Q.alpha) in
  let text = property R.summary block in
  check_eq (member "textLayout" text) (`Bool true);
  check_eq (member "uuid" (List.hd (items "blocks" text))) (`String R.text_a);
  check_eq (member "textLayout" (property R.score block)) (`Bool false);
  check_eq (member "textLayout" (property R.ready block)) (`Bool false);
  check ~msg:"technical identifiers and query internals are excluded"
    (List.for_all (fun p -> not (List.mem (member "attr" p)
      [`String "block/title"; `String "block/uuid"; `String "logseq.property/created-from-property"])) (properties block));
  let empty = result (read session Q.project) in
  check ~msg:"self-inheritance does not hang or leak unrelated properties" (List.length (properties empty) < 15);
  ignore (Q.dispatch session "openNode" (J.to_string (`Assoc ["uuid", `String Q.page])));
  let snapshot = Rpc_test.response_result (J.from_string (Rpc_session.snapshot_visible session)) in
  let route = List.hd (items "nodeRoutes" snapshot) in
  check_eq (member "text" (property R.summary route)) (`String "Writing");
  check ~msg:"ordinary rows do not carry full property panels" (List.for_all (fun row ->
    member "nodeProperties" (member "block" row) = `Null) (items "outlinerRows" route))

let inherited_empty_and_closed_values () =
  let db = Ds.db_with [
    put Q.project "logseq.property.class/properties" (Ds.Ref_to (Ds.Ident R.summary));
    put Q.beta "block/tags" (Ds.Ref_to (Q.ref_uuid Q.project));
    Ds.RetractAttr (Q.ref_uuid Q.beta, R.summary);
    put R.value_a "block/closed-value-property" (Ds.Ref_to (Q.ref_uuid R.score_property));
    put R.summary_property "logseq.property/hide?" (Ds.Bool true)] (R.fixture ()) in
  let session, _ = R.make_session db in
  let projected = result (read session Q.alpha) in
  check ~msg:"hidden property definitions stay hidden" (not (List.exists (fun p -> member "attr" p = `String R.summary) (properties projected)));
  check_eq (member "closed" (property R.score projected)) (`Bool true);
  let db = Ds.db_with [put R.summary_property "logseq.property/hide?" (Ds.Bool false)] db in
  let session, _ = R.make_session db in
  check_eq ~msg:"tag-declared empty properties remain available for editing"
    (member "raw" (property R.summary (result (read session Q.beta)))) `Null

let typed_edits_persist_and_sync () = R.with_runtime (fun session runtime conn ->
  let apply uuid attr value extra =
    let p = property attr (result (read session uuid)) in
    ignore (result (edit session uuid p value extra)) in
  apply Q.alpha R.score "35" [];
  apply Q.alpha R.ready "false" [];
  apply Q.alpha R.summary "Revised **notes**\nSecond line" [];
  let db = Graph_runtime.db runtime in
  let id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid Q.alpha)) in
  check_eq (Graph_read.value db id R.ready) (Some (Ds.Bool false));
  let value = List.hd (Graph_read.ref_eids db id R.score) in
  check_eq (Graph_read.value db value "logseq.property/value") (Some (Ds.Int64 35L));
  let original = Option.get (Ds.entid db "block/uuid" (Ds.Uuid R.value_a)) in
  check_eq ~msg:"shared values are never edited in place" (Graph_read.value db original "logseq.property/value") (Some (Ds.Int64 20L));
  let current = property R.summary (result (read session Q.alpha)) in
  check_eq (member "text" current) (`String "Revised **notes**\nSecond line");
  List.iter (fun op -> match Graph_runtime.prepare_sync runtime op with
    | Ok _ -> () | Error message -> fail ("property sync: " ^ message)) (Graph_runtime.pending_operations runtime);
  ignore (result (edit session Q.alpha current "" []));
  check_eq (Graph_read.value (Graph_runtime.db runtime) id R.summary) None;
  let restored = Graph_runtime.create runtime.path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
  let restored_session, _ = R.make_session (Graph_runtime.db restored) in
  check_eq (member "text" (property R.score (result (read restored_session Q.alpha)))) (`String "35");
  List.iter (fun operation ->
    let before = (Graph_runtime.state restored).server_t in
    let _, tx = match Graph_runtime.prepare_sync restored operation with Ok value -> value | Error message -> fail message in
    let journal = match Journal_sync.decode (J.to_string (`Assoc ["type", `String "tx/batch/ok";
      "t-before", `Int before; "t", `Int (before + 1); "txs", `List [`Assoc ["t", `Int (before + 1);
      "tx-id", `String operation.Pending_ops.operation_id; "tx", `String tx]]])) with
      | Ok value -> value | Error message -> fail message in
    check_ok (Graph_runtime.stage restored {operation with Pending_ops.state = Pending_ops.Accepted (before + 1)});
    let ids, changed = match Journal_sync.apply (fun value -> Ok value) conn before journal with
      | Ok value -> value | Error message -> fail message in
    Graph_runtime.rebase restored journal.t ids changed) (Graph_runtime.pending_operations restored);
  check_eq (Graph_runtime.pending_operations restored) [])

let invalid_and_stale_edits_do_not_write () = R.with_runtime (fun session runtime _ ->
  let p = property R.score (result (read session Q.alpha)) in
  let before = List.length (Graph_runtime.pending_operations runtime) in
  List.iter (fun response -> check_eq (member "ok" response) (`Bool false)) [
    edit session Q.alpha p "NaN" [];
    edit session "missing" p "4" [];
    edit session Q.alpha (`Assoc ["attr", `String "block/uuid"; "raw", `Null]) "changed" []];
  check_eq (List.length (Graph_runtime.pending_operations runtime)) before;
  ignore (result (edit session Q.alpha p "25" []));
  check_eq (member "ok" (edit session Q.alpha p "30" [])) (`Bool false);
  check_eq (List.length (Graph_runtime.pending_operations runtime)) (before + 1))

let native_labels_layout_and_editor () =
  List.iter (fun backend -> R.with_runtime (fun session _ _ ->
    ignore (Q.dispatch session "openNode" (J.to_string (`Assoc ["uuid", `String Q.alpha])));
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      App_test.send app (Model.RequestAppNode Q.alpha);
      let snapshot = match Response_snapshot.decode_response (Rpc_session.snapshot_visible session) with
        | Ok value -> value | Error message -> fail message in
      App_test.send app (Model.ApplyCoreSnapshot snapshot); App_test.flush app;
      List.iter (fun eff -> ignore (Lui_app.send app (Model.DequeueEffect (Model.effect_id eff)))) (App.model app).pending_effects;
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      let expand = find ("properties.expand." ^ Q.alpha) in
      if expand <> -1 then (App_test.dispatch app (Lui_protocol.Press expand); App_test.flush app);
      let id attr = "property.value." ^ Q.alpha ^ "." ^ attr in
      let label = find ("property.label." ^ Q.alpha ^ "." ^ R.summary) in
      check ~msg:"zoomed blocks show property labels" (label <> -1);
      check_eq (App_test.node host label) (Some Lui_protocol.Text);
      check_eq (App_test.property_string host label Lui_protocol.ForegroundValue) "muted-foreground";
      let rec walk id = id :: List.concat_map walk (App_test.children host id) in
      let screen = find "screen.node" in
      let order = walk screen in
      let position node = let rec loop n = function [] -> max_int | x :: _ when x = node -> n | _ :: xs -> loop (n + 1) xs in loop 0 order in
      let block = App_test.descendant_with_identifier host screen ("outliner.block." ^ Q.alpha) in
      check ~msg:"zoomed properties follow the block body" (position block < position label);
      check ~msg:"text values use the real block renderer" (find ("outliner.block." ^ R.text_a) <> -1);
      check (find ("property.inline." ^ Q.alpha ^ "." ^ R.score) <> -1);
      let click id = let node = find id in check ~msg:id (node <> -1); App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      click (id R.score);
      let editor = "property." ^ Q.alpha ^ "." ^ R.score in
      check (find ("view.edit.sheet." ^ editor) <> -1);
      click ("view.edit.cancel." ^ editor);
      check_eq (App.model app).pending_effects [];
      let editor = "property." ^ Q.alpha ^ "." ^ R.ready in
      let checkbox = find (id R.ready) in
      check_eq ~msg:"checkbox values use a native checkbox" (App_test.node host checkbox) (Some Lui_protocol.Checkbox);
      App_test.dispatch app (Lui_protocol.ToggleChanged (checkbox, false)); App_test.flush app;
      check ~msg:"checkbox state follows the tap while saving" (not (App_test.property_bool host checkbox Lui_protocol.Checked));
      check_eq ~msg:"checkboxes toggle directly without a true/false sheet" (find ("view.edit.sheet." ^ editor)) (-1);
      let eff = List.find (fun eff -> member "kind" (J.from_string (Native_bridge.encode_effect eff)) = `String "node-property") (App.model app).pending_effects in
      let encoded = J.from_string (Native_bridge.encode_effect eff) in
      let payload = J.from_string (R.text (member "text" encoded)) in
      check_eq (member "blockUuid" payload) (`String Q.alpha);
      check_eq (member "attr" payload) (`String R.ready);
      check_eq (member "value" payload) (`String "false");
      let effect_id = Model.effect_id eff in
      ignore (Lui_app.send app (Model.DequeueEffect effect_id));
      ignore (Lui_app.send app (Model.ResolveEffect (effect_id, false, "This value changed")));
      App_test.flush app;
      check_eq (App.model app).effect_error None;
      check ~msg:"a rejected toggle restores the confirmed checkbox state"
        (App_test.property_bool host (find (id R.ready)) Lui_protocol.Checked);
      check (find ("view.action.error." ^ editor) <> -1)))) [App_test.ios_backend; App_test.kotlin_backend]

let text_editor_refresh_and_value_catalog () =
  List.iter (fun backend -> R.with_runtime (fun session runtime conn ->
    ignore (Ds.transact_conn conn [Ds.RetractAttr (Q.ref_uuid Q.alpha, R.summary);
      put Q.project "logseq.property.class/properties" (Ds.Ref_to (Ds.Ident R.summary))]);
    Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [Q.alpha; Q.project];
    let p = property R.score (result (read session Q.alpha)) in
    check ~msg:"an open selector offers values already used by other objects"
      (List.exists (fun value -> member "title" value = `String "10") (items "filterValues" p));
    ignore (Q.dispatch session "openNode" (J.to_string (`Assoc ["uuid", `String Q.alpha])));
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      App_test.send app (Model.RequestAppNode Q.alpha);
      let refresh () = let snapshot = match Response_snapshot.decode_response (Rpc_session.snapshot_visible session) with
        | Ok value -> value | Error message -> fail message in App_test.send app (Model.ApplyCoreSnapshot snapshot); App_test.flush app in
      refresh ();
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      let expand = find ("properties.expand." ^ Q.alpha) in
      if expand <> -1 then (App_test.dispatch app (Lui_protocol.Press expand); App_test.flush app);
      let empty = find ("property.value." ^ Q.alpha ^ "." ^ R.summary) in
      check ~msg:"empty tag text property has an edit affordance" (empty <> -1);
      App_test.dispatch app (Lui_protocol.Press empty); App_test.flush app;
      let editor = "property." ^ Q.alpha ^ "." ^ R.summary in
      check_eq ~msg:"text properties support multiline editing"
        (App_test.node host (find ("view.edit.value." ^ editor))) (Some Lui_protocol.Textarea);
      App_test.dispatch app (Lui_protocol.Press (find ("view.edit.cancel." ^ editor))); App_test.flush app;
      let p = property R.summary (result (read session Q.alpha)) in
      let response = Core_effect_test.execute session "node-property" ["text", `String (J.to_string (`Assoc [
        "blockUuid", `String Q.alpha; "attr", `String R.summary; "expected", member "raw" p; "value", `String "New notes"]))] in
      ignore (result response); refresh ();
      let updated = property R.summary (result (read session Q.alpha)) in
      let uuid = R.text (member "uuid" (List.hd (items "blocks" updated))) in
      check ~msg:"empty-to-text updates mount a real block without reopening the node" (find ("outliner.block." ^ uuid) <> -1);
      check_eq (find ("property.value." ^ Q.alpha ^ "." ^ R.summary)) (-1)))) [App_test.ios_backend; App_test.kotlin_backend]

let many_text_edits_preserve_sibling_values () = R.with_runtime (fun session runtime conn ->
  ignore (Ds.transact_conn conn [put R.summary_property "db/cardinality" (Ds.Keyword "db.cardinality/many");
    put Q.alpha R.summary (Ds.Ref_to (Q.ref_uuid R.text_b))]);
  Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [Q.alpha; R.summary_property];
  let p = property R.summary (result (read session Q.alpha)) in
  let next = "Notes, including commas\nSecond line" in
  ignore (result (edit session Q.alpha p next ["textValueUuid", `String R.text_a]));
  let p = property R.summary (result (read session Q.alpha)) in
  let blocks = items "blocks" p in
  check_eq ~msg:"editing one text block preserves its sibling" (List.sort compare (List.map (member "title") blocks))
    (List.sort compare [`String "Writing"; `String next]);
  let updated = List.find (fun block -> member "title" block = `String next) blocks in
  ignore (result (edit session Q.alpha p "" ["textValueUuid", member "uuid" updated]));
  check_eq (member "text" (property R.summary (result (read session Q.alpha)))) (`String "Writing"))

let builtin_description_is_editable () = R.with_runtime (fun session runtime conn ->
  ignore (Ds.transact_conn conn [put Q.page "logseq.property/description" (Ds.Ref_to (Q.ref_uuid R.text_a))]);
  Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [Q.page];
  let p = property "logseq.property/description" (result (read session Q.page)) in
  check_eq ~msg:"public built-in properties remain interactive" (member "editable" p) (`Bool true);
  ignore (result (edit session Q.page p "Page description" []));
  check_eq (member "text" (property "logseq.property/description" (result (read session Q.page)))) (`String "Page description"))

let temporal_properties_display_and_edit () = R.with_runtime (fun session runtime conn ->
  let attr = "user.property/Appointment" in
  let def = "40000000-0000-4000-8000-000000000001" in
  let value = "40000000-0000-4000-8000-000000000002" in
  ignore (Ds.transact_conn conn (R.entity 101 def "Appointment" @ [
    put def "db/ident" (Ds.Keyword attr); put def "logseq.property/type" (Ds.Keyword "datetime");
    put def "db/valueType" (Ds.Keyword "db.type/ref");
    put def "db/cardinality" (Ds.Keyword "db.cardinality/one");
    put def "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Property"))]
    @ R.entity 102 value "" @ [Ds.RetractAttr (Q.ref_uuid value, "block/title");
    put value "logseq.property/value" (Ds.Int64 1792632600000L);
    put Q.alpha attr (Ds.Ref_to (Q.ref_uuid value))]));
  Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] [Q.alpha; def; value];
  let p = property attr (result (read session Q.alpha)) in
  check ~msg:"datetime values are readable instead of epoch numbers"
    (member "text" p <> `String "1792632600000" && String.contains (R.text (member "text" p)) ':');
  check_eq ~msg:"the picker receives lossless milliseconds" (member "editorValue" p) (`String "1792632600000");
  let due = property R.due (result (read session Q.alpha)) in
  check_eq (member "editorValue" due) (`String "2026-10-01");
  ignore (result (edit session Q.alpha due "2026-10-22" []));
  check_eq (member "editorValue" (property R.due (result (read session Q.alpha)))) (`String "2026-10-22");
  ignore (result (edit session Q.alpha p "1792719000000" []));
  let p = property attr (result (read session Q.alpha)) in
  check_eq (member "editorValue" p) (`String "1792719000000");
  check_eq (member "ok" (edit session Q.alpha p "NaN" [])) (`Bool false);
  ignore (result (edit session Q.alpha p "" []));
  check ~msg:"clearing removes the assigned date value" (not (List.exists (fun p -> member "attr" p = `String attr)
    (properties (result (read session Q.alpha))))))

let page_rename_guards_follow_master () =
  let named n uuid title tags parent = R.entity n uuid title @
    [put uuid "block/name" (Ds.String (Dev_query.Unicode.lowercase title))] @
    List.map (fun ident -> put uuid "block/tags" (Ds.Ref_to (Ds.Ident ident))) tags @
    (match parent with None -> [] | Some parent -> [put uuid "block/parent" (Ds.Ref_to (Q.ref_uuid parent))]) in
  let target = "40000000-0000-4000-8000-000000000001" in
  let other = "40000000-0000-4000-8000-000000000002" in
  let base = Ds.db_with (named 100 target "Original" ["logseq.class/Page"] None) (R.fixture ()) in
  let validate message db uuid title accepted =
    let id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid uuid)) in
    let expected_title = Option.value ~default:"" (Graph_read.string_value (Graph_read.value db id "block/title")) in
    let result = Pending_projection.compile db (Pending_ops.Save_title {uuid; expected_title; title}) in
    check_eq ~msg:message (Result.is_ok result) accepted in
  List.iter (fun title -> validate ("invalid page title: " ^ title) base target title false)
    [""; " \t\n"; "　"; "Has #tag"; "Nested/Page"; "2026-10-23"; "10/23/2026"];
  List.iter (fun (source, expected) ->
    check_eq ~msg:("page lookup names match JavaScript lowercase and NFC: " ^ source) (Node_title.name source) expected)
    ["ΟΣ", "ος"; "ΟΣΑ", "οσα"; "Σ", "σ"; "ΣΣ", "σς"; "AΣ'A", "aσ'a"; "AΣ'", "aς'"; "İ", "i̇"];
  validate "ordinary blocks can still be empty" base Q.alpha "" true;
  validate "ordinary block text can contain hashtags and slashes" base Q.alpha "A #tag / text" true;
  validate "built-in flag protects title changes"
    (Ds.db_with [put target "logseq.property/built-in?" (Ds.Bool true)] base) target "New" false;
  validate "internal property identifiers are protected even without a built-in flag"
    (Ds.db_with [put target "db/ident" (Ds.Keyword "logseq.property/internal-name")] base) target "New" false;
  validate "file entities are protected"
    (Ds.db_with [put target "file/path" (Ds.String "logseq/rename-test.edn")] base) target "New" false;
  validate "journal title is not a rename target"
    (Ds.db_with [put target "block/journal-day" (Ds.Int64 20261023L)] base) target "New" false;
  let duplicate = Ds.db_with (named 101 other "Existing" ["logseq.class/Page"] None) base in
  validate "ordinary page duplicates are case insensitive" duplicate target "EXISTING" false;
  let unicode = Ds.db_with (named 101 other "Café" ["logseq.class/Page"] None) base in
  validate "page name uniqueness uses Unicode NFC" unicode target "CAFÉ" false;
  let parented = Ds.db_with [put other "block/parent" (Ds.Ref_to (Q.ref_uuid Q.page))] duplicate in
  validate "ordinary page names in another parent do not collide" parented target "Existing" true;
  let matching_parent = Ds.db_with [put target "block/parent" (Ds.Ref_to (Q.ref_uuid Q.page))] parented in
  validate "ordinary page names within the same parent collide" matching_parent target "Existing" false;
  let different_tags = Ds.db_with [put target "block/tags" (Ds.Ref_to (Q.ref_uuid Q.project));
    put other "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Task"))] duplicate in
  validate "Page-only overlap allows differently tagged objects" different_tags target "Existing" true;
  validate "a shared additional tag still collides"
    (Ds.db_with [put other "block/tags" (Ds.Ref_to (Q.ref_uuid Q.project))] different_tags) target "Existing" false;
  let tag = Ds.db_with (named 101 other "Another tag" ["logseq.class/Tag"] None) base in
  validate "tag names are exact-title unique" tag other "Project" false;
  validate "tag names are case sensitive" tag other "project" true;
  validate "property names cannot begin with page reference syntax" base R.summary_property "[[Bad]]" false;
  validate "user property names are exact-title unique" base R.summary_property "Score" false;
  validate "user property names are case sensitive" base R.summary_property "score" true;
  validate "user properties may share a built-in property's name" base R.summary_property "Status" true

let page_rename_updates_lookup_search_and_references () =
  let db = Ds.db_with [put Q.page "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Page"));
    put Q.alpha "block/title" (Ds.String ("See [[" ^ Q.page ^ "]]"));
    put Q.alpha "block/refs" (Ds.Ref_to (Q.ref_uuid Q.page))] (R.fixture ()) in
  Graph_runtime_test.with_search_runtime db (fun _ conn runtime ->
    let session = Rpc_session.create_session {Rpc_session.default_options with
      load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
      graph_db = Some (fun () -> Some (Graph_runtime.db runtime));
      sync_cursor = Some (fun () -> Some (Graph_runtime.state runtime).server_t);
      stage_operation = Some (Graph_runtime.stage runtime); prepare_operation = Some (Graph_runtime.prepare_sync runtime);
      graph_sidebar_pages = Some (fun () -> Some {Graph_read.favorites = [{uuid = Q.page; title = "Workspace"}];
        recent_pages = [{uuid = Q.page; title = "Workspace"}]});
      graph_node_destination = Some (fun uuid -> Graph_read.node_destination (fun value -> Ok value) (Graph_runtime.db runtime) uuid);
      graph_page_blocks = Some (fun uuid -> Some (Graph_runtime.blocks_for_page runtime uuid));
      graph_search_page = Some (Graph_runtime.search_page runtime)}
      |> Rpc_test.configure_plain_session in
    ignore (result (Rpc_test.dispatch_json session "selectPage" Q.page));
    ignore (result (Rpc_test.dispatch_json session "openNode" (J.to_string (`Assoc ["uuid", `String Q.page]))));
    let before = result (Rpc_test.dispatch_json session "searchNodes" "Workspace") in
    check ~msg:"the original name is retained in an active search before renaming"
      (List.exists (fun hit -> member "uuid" hit = `String Q.page) (items "searchResults" before));
    let rename = member "rename" (member "nodeProperties" (result (read session Q.page))) in
    check_eq ~msg:"an ordinary page exposes its shared rename editor capability" (member "attr" rename) (`String "block/title");
    check_eq ~msg:"a rename cannot target a graph that is no longer active"
      (member "ok" (edit session Q.page rename "Wrong graph" ["graphId", `String "other-graph"])) (`Bool false);
    let after = result (edit session Q.page rename "Café Notes" []) in
    check_eq ~msg:"the already selected page title updates in the actual RPC response"
      (member "title" (member "selectedPage" after)) (`String "Café Notes");
    check_eq ~msg:"an already pushed native destination updates in place"
      (member "title" (member "page" (List.hd (items "nodeRoutes" after)))) (`String "Café Notes");
    List.iter (fun key -> check_eq ~msg:(key ^ " use the current title")
      (member "title" (List.hd (items key after))) (`String "Café Notes")) ["favorites"; "recentPages"];
    check ~msg:"the retained old-name search drops renamed pages and references immediately"
      (not (List.exists (fun hit -> List.mem (member "uuid" hit) [`String Q.page; `String Q.alpha]) (items "searchResults" after)));
    let db = Graph_runtime.db runtime in
    let id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid Q.page)) in
    check_eq ~msg:"the page lookup key updates with its title" (Graph_read.value db id "block/name") (Some (Ds.String "café notes"));
    let hits, _ = Graph_runtime.search_page runtime ~offset:0 ~limit:20 "Café" in
    check ~msg:"renamed pages become searchable immediately"
      (List.exists (fun (hit : Search_index.indexed_search_hit) -> hit.uuid = Q.page && hit.title = "Café Notes") hits);
    check ~msg:"references are reindexed with the renamed display title"
      (List.exists (fun (hit : Search_index.indexed_search_hit) -> hit.uuid = Q.alpha && String_kit.includes ~sub:"Café Notes" hit.title) hits);
    check_eq ~msg:"stale rename submissions never overwrite a newer title" (member "ok" (edit session Q.page rename "Stale" [])) (`Bool false);
    List.iter (fun operation -> check_ok ~msg:"page rename compiles for sync"
      (Graph_runtime.prepare_sync runtime operation)) (Graph_runtime.pending_operations runtime);
    let protected = Ds.db_with [put Q.page "logseq.property/built-in?" (Ds.Bool true)] (Graph_runtime.db runtime) in
    let protected_session, _ = R.make_session protected in
    check_eq ~msg:"built-in pages do not expose Rename page" (member "rename" (member "nodeProperties" (result (read protected_session Q.page)))) `Null)

let native_page_rename_uses_shared_editor () =
  R.with_runtime (fun session _ _ ->
    let node_properties = member "nodeProperties" (result (read session Q.page)) in
    List.iter (fun backend ->
      let response = J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
        "selectedGraphId", `String "plain-1";
        "selectedPage", `Assoc ["uuid", `String Q.page; "title", `String "Workspace"];
        "nodeProperties", node_properties; "outlinerRows", `List []]]) in
      Q.with_ui backend response (fun app ->
        let host = Lui_app.runtime app in
        let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
        let click id = let node = find id in check ~msg:id (node <> -1);
          App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
        click "button.page.rename";
        let id = "page.rename." ^ Q.page in
        let input = find ("view.edit.value." ^ id) in
        check ~msg:"Rename page reuses the shared property text editor" (input <> -1);
        check_eq (App_test.property_string host input Lui_protocol.TextValue) "Workspace";
        check_eq ~msg:"Rename page has no Clear value action" (find ("view.edit.clear." ^ id)) (-1);
        App_test.dispatch app (Lui_protocol.TextChanged (input, "Renamed page")); App_test.flush app;
        click ("view.edit.save." ^ id);
        let payload = List.find_map (function Model.NodePropertyEffect (_, key, body) when key = id -> Some (J.from_string body) | _ -> None)
          (App.model app).pending_effects in
        check ~msg:"Rename page sends one existing node-property mutation" (payload <> None);
        let payload = Option.get payload in
        check_eq (member "blockUuid" payload) (`String Q.page);
        check_eq (member "graphId" payload) (`String "plain-1");
        check_eq (member "attr" payload) (`String "block/title");
        check_eq (member "value" payload) (`String "Renamed page")))
      [App_test.ios_backend; App_test.kotlin_backend])

let cases = [
  case "Rename page uses the protected shared native editor" native_page_rename_uses_shared_editor;
  case "page rename guards match master names, built-ins and duplicate scopes" page_rename_guards_follow_master;
  case "page rename updates lookup, live search, references and sync" page_rename_updates_lookup_search_and_references;
  case "dates and datetimes display, edit and clear without epoch labels" temporal_properties_display_and_edit;
  case "properties follow node navigation without expanding ordinary blocks" projection_and_navigation;
  case "inherited empty properties, hidden metadata and closed values" inherited_empty_and_closed_values;
  case "typed edits clear, persist and compile for sync" typed_edits_persist_and_sync;
  case "invalid and stale edits never enqueue writes" invalid_and_stale_edits_do_not_write;
  case "native property labels, block layout and typed editor" native_labels_layout_and_editor;
  case "text editors refresh empty values and offer existing selector values" text_editor_refresh_and_value_catalog;
  case "editing one text value preserves siblings and literal commas" many_text_edits_preserve_sibling_values;
  case "page descriptions are editable public properties" builtin_description_is_editable;
]
