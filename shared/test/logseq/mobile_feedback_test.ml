open Test_util
module D = Datascript
module J = Yojson.Basic
module Q = Query_block_test
module R = Result_view_test
module N = Node_property_test
module B = Block_clipboard_test
let member = Q.member
let items = Q.items
let put = Q.put
let ref_uuid = Q.ref_uuid
let person = "82000000-0000-4000-8000-000000000001"
let hidden = "82000000-0000-4000-8000-000000000002"
let subclass = "82000000-0000-4000-8000-000000000003"
let node_property = "user.property/RelatedPerson"
let definition = "82000000-0000-4000-8000-000000000004"
let update runtime conn tx =
  ignore (D.transact_conn conn tx);
  Graph_runtime.rebase runtime 42 [] []
let configure_nodes runtime conn = update runtime conn
  (R.entity 200 person "Unused person" @ R.entity 201 hidden "Hidden person" @
   R.entity 202 subclass "Special person" @ R.entity 203 definition "Related person" @ [
    put subclass "block/tags" (D.Ref_to (D.Ident "logseq.class/Tag"));
    put subclass "logseq.property.class/extends" (D.Ref_to (ref_uuid Q.project));
    put person "block/tags" (D.Ref_to (ref_uuid subclass));
    put person "block/name" (D.String "unused person");
    put hidden "block/tags" (D.Ref_to (ref_uuid Q.project));
    put hidden "logseq.property/hide?" (D.Bool true);
    put definition "db/ident" (D.Keyword node_property);
    put definition "block/tags" (D.Ref_to (D.Ident "logseq.class/Property"));
    put definition "db/valueType" (D.Keyword "db.type/ref");
    put definition "db/cardinality" (D.Keyword "db.cardinality/one");
    put definition "logseq.property/type" (D.Keyword "node");
    put definition "logseq.property/classes" (D.Ref_to (ref_uuid Q.project));
    put Q.page node_property (D.Ref_to (ref_uuid Q.alpha))])
let verify_sync = Composer_tag_test.sync_all
let open_node session uuid = ignore (N.result (Rpc_test.dispatch_json session "openNode"
  (J.to_string (`Assoc ["uuid", `String uuid]))))
let with_ui session uuid f =
  open_node session uuid;
  List.iter (fun backend -> Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
    App_test.send app (Model.RequestAppNode uuid);
    let snapshot = match Response_snapshot.decode_response (Rpc_session.snapshot_visible session) with
      | Ok value -> value | Error message -> fail message in
    App_test.send app (Model.ApplyCoreSnapshot snapshot); App_test.flush app;
    let host = Lui_app.runtime app in
    let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
    let click id = let node = find id in check ~msg:("Missing action: " ^ id) (node <> -1);
      App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
    f app find click)) [App_test.ios_backend; App_test.kotlin_backend]

let pasted_page_references_survive_followup_edits () = R.with_runtime (fun session runtime conn ->
  B.rename runtime B.target "";
  B.success (B.paste session B.target "" "[[ABC]]");
  let page = Graph_read.unique_named_uuid false (Graph_runtime.db runtime) "ABC" |> Option.get in
  check_eq (B.title runtime B.target) ("[[" ^ page ^ "]]");
  B.success (B.event session ["type", `String "textChanged"; "uuid", `String B.target;
    "title", `String "[[ABC]] continued"; "caretUTF16Offset", `Int 17]);
  B.success (B.event session ["type", `String "saveEditing"]);
  check_eq ~msg:"a paste keeps the raw expected title for the next save"
    (B.title runtime B.target) ("[[" ^ page ^ "]] continued");
  B.block_event session "cancelEditing" B.target;
  B.success (B.paste ~start:17 session B.target "[[ABC]] continued" " [[ABC]]");
  check_eq ~msg:"pasting a repeated reference reuses the page"
    (Graph_read.unique_named_uuid false (Graph_runtime.db runtime) "ABC") (Some page);
  verify_sync runtime conn)

let tags_without_lookup_names_are_selectable_and_navigable () = R.with_runtime (fun session runtime conn ->
  update runtime conn [D.RetractAttr (ref_uuid Q.project, "block/name");
    put R.table_view "logseq.property/view-for" (D.Ref_to (ref_uuid Q.project));
    put R.table_view "logseq.property.view/feature-type" (D.Keyword "class-objects")];
  let picker = member "tagPicker" (member "nodeProperties" (N.result (N.read session Q.page))) in
  check ~msg:"Add tags includes a tag with a title and UUID but no lookup name"
    (List.exists (fun choice -> member "match" choice = `List [`String Q.project]) (items "filterValues" picker));
  check ~msg:"the same tag opens from a table or search"
    (Graph_read.node_destination (fun value -> Ok value) (Graph_runtime.db runtime) Q.project <> None);
  with_ui session Q.project (fun _ find click ->
    click ("view.tab." ^ R.table_view);
    click ("view.cell." ^ R.table_view ^ "." ^ Q.alpha ^ "." ^ R.score);
    check ~msg:"table cells on a tag without a lookup name open their property editor"
      (find ("view.edit.value." ^ R.table_view) <> -1)))

let search_destinations_keep_the_page_menu () =
  List.iter (fun underlying -> R.with_runtime (fun session _ _ ->
    Option.iter (open_node session) underlying;
    open_node session Q.page;
    List.iter (fun backend -> Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      Option.iter (fun uuid -> App_test.send app (Model.RequestAppNode uuid)) underlying;
      App_test.send app Model.OpenSearch;
      App_test.send app (Model.RequestSearchNode Q.page);
      let snapshot = match Response_snapshot.decode_response (Rpc_session.snapshot_visible session) with
        | Ok value -> value | Error message -> fail message in
      App_test.send app (Model.ApplyCoreSnapshot snapshot); App_test.flush app;
      check_eq ~msg:"page actions target the visible search result, including from journal home"
        (Option.map (fun (page : Model.sidebar_page) -> page.uuid) (Model.active_page (App.model app))) (Some Q.page);
      let find id = App_test.descendant_with_identifier (Lui_app.runtime app) (Lui_app.root_node app) id in
      check ~msg:"search destinations retain More and Add tags" (find "button.page.tags" <> -1);
      let current = App.model app in
      let favorite = Model.update current Model.ToggleActivePageFavorite in
      check ~msg:"Favorite targets the visible search page"
        (List.exists (function Model.SetPageFavoriteEffect (_, uuid, _) -> uuid = Q.page | _ -> false) favorite.pending_effects);
      let deleted = Model.update (Model.update current Model.RequestDeleteActivePage) Model.ConfirmDeleteActivePage in
      check_eq ~msg:"deleting a search page preserves the underlying app navigation"
        deleted.app_navigation_path current.app_navigation_path;
      check_eq ~msg:"deleting a search page returns to the previous search destination" deleted.search_navigation_path [];
      check ~msg:"deleting a search page closes its core search route"
        (List.exists (function Model.CloseSearchNodeEffect (_, uuid) -> uuid = Q.page | _ -> false) deleted.pending_effects)))
      [App_test.ios_backend; App_test.kotlin_backend])) [None; Some Q.alpha]

let node_candidates_include_unused_subclass_instances () = R.with_runtime (fun session runtime conn ->
  configure_nodes runtime conn;
  let p = N.property node_property (N.result (N.read session Q.page)) in
  let candidates = items "filterValues" p in
  check ~msg:"unused instances of descendant tags are selectable"
    (List.exists (fun p -> member "match" p = `List [`String person]) candidates);
  check ~msg:"unrelated nodes are excluded from a restricted property"
    (not (List.exists (fun p -> member "match" p = `List [`String Q.beta]) candidates));
  check ~msg:"hidden nodes are excluded"
    (not (List.exists (fun p -> member "match" p = `List [`String hidden]) candidates));
  check_eq ~msg:"a caller cannot assign an out-of-class node"
    (member "ok" (N.edit session Q.page p Q.beta [])) (`Bool false);
  ignore (N.result (N.edit session Q.page p person [])); verify_sync runtime conn)

let property_created_pages_inherit_the_restriction () = R.with_runtime (fun session runtime conn ->
  configure_nodes runtime conn;
  let p = N.property node_property (N.result (N.read session Q.page)) in
  ignore (N.result (N.edit session Q.page p "Bar" ["create", `Bool true]));
  let db = Graph_runtime.db runtime in
  let bar = Graph_read.unique_named_uuid false db "Bar" |> Option.get in
  let bar_id = Option.get (D.entid db "block/uuid" (D.Uuid bar)) in
  let tag_id = Option.get (D.entid db "block/uuid" (D.Uuid Q.project)) in
  check ~msg:"creating in a class-restricted node editor assigns the configured tag"
    (List.mem tag_id (Graph_read.ref_eids db bar_id "block/tags"));
  verify_sync runtime conn)

let deleting_a_property_target_clears_live_values () = R.with_runtime (fun session runtime conn ->
  configure_nodes runtime conn;
  let p = N.property node_property (N.result (N.read session Q.page)) in
  ignore (N.result (N.edit session Q.page p "Bar" ["create", `Bool true]));
  let bar = Graph_read.unique_named_uuid false (Graph_runtime.db runtime) "Bar" |> Option.get in
  check_ok (Graph_runtime.stage runtime (Graph_runtime.queued_operation runtime (Graph_runtime.fresh_uuid ())
    (Pending_ops.Delete_page {page_uuid = bar; deleted_at = 1234; order = "a0"})));
  let db = Graph_runtime.db runtime in
  let id = Option.get (D.entid db "block/uuid" (D.Uuid Q.page)) in
  check_eq ~msg:"recycling a node retracts its incoming property value"
    (Graph_read.value db id node_property) None;
  let restored = Graph_runtime.create runtime.path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
  check_eq (Graph_read.value (Graph_runtime.db restored) id node_property) None;
  verify_sync runtime conn)

let toolbar_page_creation_builds_a_hierarchy () = R.with_runtime (fun session runtime conn ->
  B.rename runtime B.target "";
  B.block_event session "tapBlock" B.target;
  B.success (B.event session ["type", `String "toolbar"; "action", `String "pageReference"]);
  B.success (B.event session ["type", `String "textChanged"; "uuid", `String B.target;
    "title", `String "[[Parent/Child]]"; "caretUTF16Offset", `Int 14]);
  B.success (B.event session ["type", `String "chooseAutocomplete"; "value", `String "Parent/Child"]);
  B.success (B.event session ["type", `String "saveEditing"]);
  let db = Graph_runtime.db runtime in
  let parent = match Graph_read.unique_named_uuid false db "Parent" with
    | Some uuid -> uuid | None -> fail "Hierarchy creation must create Parent" in
  let child = Graph_read.unique_named_uuid false db "Child" |> Option.get in
  let parent_id = Option.get (D.entid db "block/uuid" (D.Uuid parent)) in
  let child_id = Option.get (D.entid db "block/uuid" (D.Uuid child)) in
  check_eq (Graph_read.ref_eids db child_id "block/parent") [parent_id];
  check_eq ~msg:"the reference points to the leaf rather than a slash-named page"
    (B.title runtime B.target) ("[[" ^ child ^ "]]");
  verify_sync runtime conn)

let date_editors_offer_navigation_to_the_journal () = R.with_runtime (fun session _ _ ->
  with_ui session Q.alpha (fun app find click ->
    let expand = "properties.expand." ^ Q.alpha in
    if find expand <> -1 then click expand;
    click ("property.value." ^ Q.alpha ^ "." ^ R.due);
    let open_id = "view.edit.open.property." ^ Q.alpha ^ "." ^ R.due ^ "." ^ R.day_a in
    check ~msg:"the date picker has an explicit Open journal action" (find open_id <> -1);
    click open_id;
    check ~msg:"opening the date navigates to its journal"
      (List.exists (function Model.OpenAppNodeEffect (_, uuid) -> uuid = R.day_a | _ -> false)
        (App.model app).pending_effects)))

let search_property_navigation_stays_in_search () = R.with_runtime (fun session _ _ ->
  with_ui session Q.alpha (fun app find click ->
    App_test.send app Model.OpenSearch;
    App_test.send app (Model.RequestSearchNode Q.alpha);
    App_test.send app (Model.ResolveSearchNode (Q.alpha, true)); App_test.flush app;
    let expand = "properties.expand." ^ Q.alpha in
    if find expand <> -1 then click expand;
    click ("property.value." ^ Q.alpha ^ "." ^ R.due);
    click ("view.edit.open.property." ^ Q.alpha ^ "." ^ R.due ^ "." ^ R.day_a);
    check ~msg:"a journal opened from a search property remains in the visible search stack"
      (List.exists (function Model.OpenSearchNodeEffect (_, uuid) -> uuid = R.day_a | _ -> false)
        (App.model app).pending_effects)))

let tag_pages_allow_removing_tags_and_schema_properties () = R.with_runtime (fun session runtime conn ->
  update runtime conn [put Q.project "block/tags" (D.Ref_to (D.Ident "logseq.class/Task"));
    put Q.project "logseq.property.class/properties" (D.Ref_to (D.Ident R.score))];
  with_ui session Q.project (fun _ find _ ->
    check ~msg:"schema properties offer removal"
      (find ("property.schema.remove." ^ Q.project ^ "." ^ R.score) <> -1));
  let mutate fields = Rpc_test.dispatch_json session "nodeProperty"
    (J.to_string (`Assoc (("blockUuid", `String Q.project) :: fields))) in
  ignore (N.result (mutate ["action", `String "remove"; "attr", `String R.score]));
  let db = Graph_runtime.db runtime in
  let id = Option.get (D.entid db "block/uuid" (D.Uuid Q.project)) in
  check_eq (Graph_read.ref_eids db id "logseq.property.class/properties") [];
  let task = D.entid db "db/ident" (D.Keyword "logseq.class/Task") |> Option.get
    |> Graph_read.uuid_for_eid db |> Option.get in
  ignore (N.result (mutate ["action", `String "removeTag"; "tagUuid", `String task]));
  check ~msg:"removing a tag preserves the tag page's structural Tag type"
    (Graph_read.node_is_tag (Graph_runtime.db runtime) Q.project);
  verify_sync runtime conn)

let tables_share_node_candidates_and_date_navigation () = R.with_runtime (fun session runtime conn ->
  configure_nodes runtime conn;
  update runtime conn [put Q.alpha node_property (D.Ref_to (ref_uuid Q.alpha))];
  let table = R.find_view R.table_view (R.read session) in
  let col = List.find (fun col -> member "attr" col = `String node_property) (items "columns" table) in
  check ~msg:"table node editors include unused class members"
    (List.exists (fun value -> member "match" value = `List [`String person]) (items "filterValues" col));
  let row = List.find (fun row -> member "uuid" (member "block" row) = `String Q.alpha) (items "rows" table) in
  let date = List.find (fun p -> member "attr" p = `String R.due) (items "properties" row) in
  check ~msg:"table date editors carry their journal navigation target"
    (List.exists (fun value -> member "uuid" value = `String R.day_a) (items "references" date)))

let creation_and_removal_reject_protected_or_invalid_targets () = R.with_runtime (fun session runtime conn ->
  configure_nodes runtime conn;
  let p = N.property node_property (N.result (N.read session Q.page)) in
  let before = Graph_runtime.pending_operations runtime in
  check_eq ~msg:"Create cannot bypass the class restriction for an existing UUID"
    (member "ok" (N.edit session Q.page p Q.beta ["create", `Bool true])) (`Bool false);
  let tag = D.entid (Graph_runtime.db runtime) "db/ident" (D.Keyword "logseq.class/Tag") |> Option.get
    |> Graph_read.uuid_for_eid (Graph_runtime.db runtime) |> Option.get in
  check_eq ~msg:"the structural Tag type cannot be removed"
    (member "ok" (Rpc_test.dispatch_json session "nodeProperty" (J.to_string (`Assoc [
      "blockUuid", `String Q.project; "action", `String "removeTag"; "tagUuid", `String tag])))) (`Bool false);
  check_eq ~msg:"invalid operations leave no partial pages or removals"
    (Graph_runtime.pending_operations runtime) before)

let tag_only_pages_expose_removal_controls () = R.with_runtime (fun session runtime conn ->
  update runtime conn (R.entity 220 person "Extra tag" @ [
    put person "block/tags" (D.Ref_to (D.Ident "logseq.class/Tag"));
    put Q.project "block/tags" (D.Ref_to (ref_uuid person))]);
  with_ui session Q.project (fun _ find _ ->
    check ~msg:"a page with only tags still exposes tag removal"
      (find ("property.tag.remove." ^ Q.project ^ "." ^ person) <> -1)))

let cases = [
  case "search property links navigate in the visible stack" search_property_navigation_stays_in_search;
  case "table property editors share node discovery and journal links" tables_share_node_candidates_and_date_navigation;
  case "creation and removal enforce type protections atomically" creation_and_removal_reject_protected_or_invalid_targets;
  case "tag-only pages expose tag removal" tag_only_pages_expose_removal_controls;
  case "pasted page refs survive saving and subsequent paste" pasted_page_references_survive_followup_edits;
  case "tags without lookup names appear and open" tags_without_lookup_names_are_selectable_and_navigable;
  case "search result pages retain overflow actions" search_destinations_keep_the_page_menu;
  case "node pickers include unused and inherited class members" node_candidates_include_unused_subclass_instances;
  case "new node values inherit the configured class" property_created_pages_inherit_the_restriction;
  case "deleting referenced pages clears property values" deleting_a_property_target_clears_live_values;
  case "toolbar page creation builds a hierarchy" toolbar_page_creation_builds_a_hierarchy;
  case "date editors can open journal pages" date_editors_offer_navigation_to_the_journal;
  case "tag pages can remove tags and properties" tag_pages_allow_removing_tags_and_schema_properties;
]
