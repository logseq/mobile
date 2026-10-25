open Test_util
module J = Yojson.Basic
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let items = Q.items
let text = R.text
let captured = "80000000-0000-4000-8000-000000000001"
let tags selected created = `Assoc ["selectedValues", `List (List.map (fun value -> `String value) selected);
  "newValues", `List (List.map (fun value -> `String value) created)]
let send session ?(uuid = captured) ?(body = "Captured note") selection =
  Rpc_test.dispatch_json session "sendTagged" (J.to_string (`Assoc ["uuid", `String uuid;
    "text", `String body; "now", `Int 1792719000000; "tags", selection]))
let succeed response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true)
let tag_titles runtime uuid =
  let db = Graph_runtime.db runtime in
  match Datascript.entid db "block/uuid" (Datascript.Uuid uuid) with
  | None -> []
  | Some eid -> Graph_read.entity_summaries (fun value -> Ok value) db eid "block/tags"
    |> List.map (fun (tag : Cache_model.entity_summary) -> tag.title) |> List.sort String.compare

let sync_all runtime conn =
  List.iter (fun operation ->
    let before = (Graph_runtime.state runtime).server_t in
    let _, tx = match Graph_runtime.prepare_sync runtime operation with Ok value -> value | Error message -> fail message in
    let journal = match Journal_sync.decode (J.to_string (`Assoc ["type", `String "tx/batch/ok";
      "t-before", `Int before; "t", `Int (before + 1); "txs", `List [`Assoc ["t", `Int (before + 1);
      "tx-id", `String operation.Pending_ops.operation_id; "tx", `String tx]]])) with
      | Ok value -> value | Error message -> fail message in
    check_ok (Graph_runtime.stage runtime {operation with Pending_ops.state = Pending_ops.Accepted (before + 1)});
    let ids, changed = match Journal_sync.apply (fun value -> Ok value) conn before journal with
      | Ok value -> value | Error message -> fail message in
    Graph_runtime.rebase runtime journal.t ids changed) (Graph_runtime.pending_operations runtime);
  check_eq ~msg:"tagged captures round-trip through confirmed sync" (Graph_runtime.pending_operations runtime) []

let fresh_journal_captures_preserve_the_note () = R.with_runtime (fun session runtime _ ->
  succeed (Rpc_test.dispatch_json session "send" (J.to_string (`Assoc ["uuid", `String captured;
    "text", `String "First capture"; "now", `Int 1792719000000])));
  check_eq ~msg:"creating a new journal preserves the captured text"
    (Editor_command_test.value runtime captured "block/title") (Some (Datascript.String "First capture"));
  let day = Cache_model.journal_day_for_ms 1792719000000 in
  let page = Rpc_wire.journal_page_uuid day in
  check_eq ~msg:"the journal page has its calendar title, not the captured note"
    (Editor_command_test.value runtime page "block/title") (Some (Datascript.String (Rpc_wire.journal_day_title day))))

let capture_assigns_existing_and_new_tags () = R.with_runtime (fun session runtime conn ->
  succeed (send session (tags [Q.project; Q.project] ["Mobile"; " mobile "]));
  check_eq ~msg:"capture keeps the source text separate from selected tags"
    (Editor_command_test.value runtime captured "block/title") (Some (Datascript.String "Captured note"));
  check_eq ~msg:"existing and newly created tags are assigned once" (tag_titles runtime captured) ["Mobile"; "Project"];
  let same_name = "80000000-0000-4000-8000-000000000002" in
  succeed (send session ~uuid:same_name (tags [] ["mobile"]));
  check_eq (tag_titles runtime same_name) ["Mobile"];
  let restored = Graph_runtime.create runtime.path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
  check_eq ~msg:"pending tagged journal captures survive restart"
    (Editor_command_test.value restored captured "block/title") (Some (Datascript.String "Captured note"));
  check_eq (tag_titles restored captured) ["Mobile"; "Project"];
  sync_all runtime conn)

let invalid_tags_do_not_capture_or_create () = R.with_runtime (fun session runtime _ ->
  List.iter (fun selection ->
    let before = List.length (Graph_runtime.pending_operations runtime) in
    let response = send session selection in
    check_eq ~msg:"reject invalid selected tags" (member "ok" response) (`Bool false);
    check_eq ~msg:"invalid tags leave no partial capture or new tag" (List.length (Graph_runtime.pending_operations runtime)) before;
    check_eq (Datascript.entid (Graph_runtime.db runtime) "block/uuid" (Datascript.Uuid captured)) None)
    [tags [Q.alpha] ["Must not exist"]; tags ["missing"] []; tags [] [" "]])

let inline_tags_and_status_survive () = R.with_runtime (fun session runtime _ ->
  let status = `Assoc ["uuid", `String "00000002-7975-1727-0000-000000000001";
    "ident", `String "logseq.property/status.todo"; "title", `String "Todo"] in
  let response = Rpc_test.dispatch_json session "sendTagged" (J.to_string (`Assoc [
    "uuid", `String captured; "text", `String "Note #Project"; "now", `Int 1792719000000;
    "status", status; "tags", tags [] ["Mobile"]])) in
  succeed response;
  check_eq ~msg:"selected tags preserve tags typed in the note" (tag_titles runtime captured) ["Mobile"; "Project"];
  check ~msg:"tagged tasks retain their status" (Editor_command_test.value runtime captured "logseq.property/status" <> None))

let assets_assign_tags_without_changing_the_filename () = R.with_runtime (fun session runtime conn ->
  let payload = ["uuid", `String captured; "title", `String "Photo.png"; "now", `Int 1792719000000;
    "assetType", `String "png"; "assetSize", `Int 12; "assetChecksum", `String "abc";
    "localPath", `String "/tmp/Photo.png"; "targetBlockId", `String Q.alpha;
    "tags", tags [Q.project] ["Photos"]] in
  succeed (Rpc_test.dispatch_json session "addAsset" (J.to_string (`Assoc payload)));
  check_eq (Editor_command_test.value runtime captured "block/title") (Some (Datascript.String "Photo.png"));
  check_eq (tag_titles runtime captured) ["Asset"; "Photos"; "Project"];
  (* Binary upload completion activates the original asset transaction for sync. *)
  let asset = List.find (fun (operation : Pending_ops.pending_operation) ->
    match operation.intent with Pending_ops.Create_asset _ -> true | _ -> false) (Pending_ops.list runtime.path) in
  check_eq asset.state Pending_ops.Applied;
  check_ok (Graph_runtime.stage runtime {asset with state = Pending_ops.Queued});
  sync_all runtime conn)

let catalog_uses_graph_tags_without_writes () = R.with_runtime (fun session runtime _ ->
  let before = Graph_runtime.pending_operations runtime in
  let response = Rpc_test.dispatch_json session "composerTags" "" in
  succeed response;
  let choices = items "composerTagChoices" (member "result" response) in
  check ~msg:"the picker offers graph tag objects" (List.exists (fun tag -> member "uuid" tag = `String Q.project) choices);
  check ~msg:"ordinary blocks are not tag candidates" (not (List.exists (fun tag -> member "uuid" tag = `String Q.alpha) choices));
  check_eq ~msg:"opening a picker does not mutate the graph" (Graph_runtime.pending_operations runtime) before)

let shared_picker_stages_and_removes_tags () =
  List.iter (fun backend -> R.with_runtime (fun session runtime _ ->
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      let click id = let node = find id in check ~msg:("Missing control: " ^ id) (node <> -1);
        App_test.dispatch app (Lui_protocol.Press node); App_test.flush app in
      App_test.send app Model.ExpandComposer; App_test.flush app;
      let before = List.length (Graph_runtime.pending_operations runtime) in
      let choices = Rpc_test.dispatch_json session "composerTags" "" |> J.to_string in
      let projection = match Response_snapshot.decode_response choices with Ok value -> value | Error message -> fail message in
      let open_tags () = click "button.composer.tags";
        App_test.send app (Model.ApplyCoreSnapshot projection); App_test.flush app in
      open_tags ();
      check ~msg:"tags reuse the shared property editor sheet" (find "view.edit.sheet.composer.tags" <> -1);
      click ("view.edit.option.composer.tags." ^ Q.project);
      click "view.edit.save.composer.tags";
      check ~msg:"selected tags appear as removable composer chips" (find ("button.composer.tag.remove." ^ Q.project) <> -1);
      let saved = Model.ui_session (App.model app) in
      let encoded_session = J.from_string (Native_bridge.encode_ui_session saved) in
      check ~msg:"unsent tags persist with the UI session" (items "composerTags" encoded_session <> []);
      click ("button.composer.tag.remove." ^ Q.project);
      App_test.send app (Model.RestoreUISession saved); App_test.flush app;
      check_eq ~msg:"relaunch keeps staged tags while the composer is collapsed"
        (App.model app).composer_tags saved.composer_tags;
      App_test.send app Model.ExpandComposer; App_test.flush app;
      check ~msg:"restoring the same graph recovers staged tags" (find ("button.composer.tag.remove." ^ Q.project) <> -1);
      open_tags ();
      let input = find "view.edit.value.composer.tags" in
      App_test.dispatch app (Lui_protocol.TextChanged (input, "Mobile")); App_test.flush app;
      click "view.edit.create.composer.tags";
      click "view.edit.save.composer.tags";
      check_eq ~msg:"staging tags never writes before Send" (List.length (Graph_runtime.pending_operations runtime)) before;
      click ("button.composer.tag.remove." ^ Q.project);
      check_eq ~msg:"remove only the chosen chip" (find ("button.composer.tag.remove." ^ Q.project)) (-1);
      open_tags ();
      click "view.edit.cancel.composer.tags";
      App_test.send app (Model.ChangeComposerDraft "Keep this note");
      App_test.send app Model.SendComposer; App_test.flush app;
      let encoded = List.map (fun eff -> J.from_string (Native_bridge.encode_effect eff)) (App.model app).pending_effects in
      let tagged = List.find_opt (fun eff -> member "kind" eff = `String "send-tagged") encoded in
      check ~msg:"Send carries typed tag selection separately from text" (tagged <> None);
      let eff = Option.get tagged in
      let payload = J.from_string (text (member "text" eff)) in
      check_eq (member "text" payload) (`String "Keep this note");
      check_eq (items "newValues" (member "tags" payload)) [`String "Mobile"];
      check_eq (items "selectedValues" (member "tags" payload)) [];
      let effect_id = match member "id" eff with `Int id -> id | _ -> fail "Missing effect id" in
      check_eq ~msg:"sending clears staged tags for the next capture"
        (items "composerTags" (J.from_string (Native_bridge.encode_ui_session (Model.ui_session (App.model app))))) [];
      App_test.send app (Model.DequeueEffect effect_id);
      App_test.send app (Model.ResolveEffect (effect_id, false, "Try again")); App_test.flush app;
      check_eq ~msg:"failed tagged captures recover the draft" (App.model app).composer_draft "Keep this note";
      check ~msg:"failed tagged captures recover tags"
        (items "composerTags" (J.from_string (Native_bridge.encode_ui_session (Model.ui_session (App.model app)))) <> []);
      let old_choices = projection in
      let changed = match J.from_string (Rpc_session.snapshot_visible session) with
        | `Assoc fields -> (match member "result" (`Assoc fields) with
            | `Assoc result -> `Assoc (("result", `Assoc (("selectedGraphId", `String "other") :: List.remove_assoc "selectedGraphId" result)) :: List.remove_assoc "result" fields)
            | _ -> fail "Missing result")
        | _ -> fail "Missing envelope" in
      let changed = match Response_snapshot.decode_response (J.to_string changed) with Ok value -> value | Error message -> fail message in
      App_test.send app (Model.ApplyCoreSnapshot changed); App_test.flush app;
      check_eq ~msg:"switching graphs clears staged tag references"
        (items "composerTags" (J.from_string (Native_bridge.encode_ui_session (Model.ui_session (App.model app))))) [];
      App_test.send app (Model.ApplyCoreSnapshot old_choices); App_test.flush app;
      check_eq ~msg:"a stale tag catalog never switches graphs" (App.model app).selected_graph_id (Some "other"))))
    [App_test.ios_backend; App_test.kotlin_backend]

let projection_for_graph response graph_id catalog =
  let envelope = J.from_string response in
  let fields = match member "result" envelope with `Assoc fields -> fields | _ -> fail "Missing snapshot" in
  let fields = ("selectedGraphId", `String graph_id) :: ("isGraphCatalogPatch", `Bool catalog)
    :: List.remove_assoc "selectedGraphId" (List.remove_assoc "isGraphCatalogPatch" fields) in
  match Response_snapshot.decode_response (J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc fields])) with
  | Ok value -> value | Error message -> fail message

let graph_changes_reset_the_tag_picker () =
  List.iter (fun backend -> List.iter (fun change -> R.with_runtime (fun session _ _ ->
    let snapshot = Rpc_session.snapshot_visible session in
    Q.with_ui backend snapshot (fun app ->
      let old_graph = (App.model app).selected_graph_id in
      App_test.send app (Model.SetComposerTags [{Model.uuid = Q.project; title = "Project"}]);
      App_test.send app Model.OpenComposerTags; App_test.flush app;
      let load = List.find (function Model.LoadComposerTagsEffect _ -> true | _ -> false) (App.model app).pending_effects in
      let load_id = match member "id" (J.from_string (Native_bridge.encode_effect load)) with `Int id -> id | _ -> fail "Missing load id" in
      App_test.send app (Model.DequeueEffect load_id);
      if change = "open" then begin
        let graphs = [{Model.id = "other"; name = "Other"; is_encrypted = false; is_ready = true; role = None}] in
        let catalog = { (projection_for_graph snapshot (Option.get old_graph) true) with Model.graphs } in
        App_test.send app (Model.ApplyCoreSnapshot catalog);
        App_test.send app (Model.RequestOpenGraph "other"); App_test.flush app;
        let eff = List.find (function Model.OpenGraphEffect _ -> true | _ -> false) (App.model app).pending_effects in
        let id = match eff with Model.OpenGraphEffect (id, _) -> id | _ -> assert false in
        App_test.send app (Model.DequeueEffect id);
        App_test.send app (Model.ResolveEffect (id, true, "{}"))
      end else App_test.send app (Model.ApplyCoreSnapshot (projection_for_graph snapshot "other" (change = "catalog")));
      App_test.flush app;
      let current = App.model app in
      check_eq ~msg:(change ^ " must clear graph-specific staged tags") current.composer_tags [];
      check_eq ~msg:(change ^ " must close the previous graph's picker") current.composer_tags_open false;
      check_eq ~msg:(change ^ " must release the loading state") current.composer_tags_loading false;
      App_test.send app Model.OpenComposerTags; App_test.flush app;
      App_test.send app (Model.ResolveEffect (load_id, false, "Old graph request failed")); App_test.flush app;
      check_eq ~msg:"a stale failure cannot close the new graph's picker" (App.model app).composer_tags_open true;
      check_eq ~msg:"a stale failure cannot end the new graph's loading request" (App.model app).composer_tags_loading true)))
    ["snapshot"; "catalog"; "open"]) [App_test.ios_backend; App_test.kotlin_backend]

let failed_asset_captures_recover_only_in_their_graph () =
  List.iter (fun backend -> List.iter (fun switch -> R.with_runtime (fun session _ _ ->
    let snapshot = Rpc_session.snapshot_visible session in
    Q.with_ui backend snapshot (fun app ->
      let asset = {Model.uuid = captured; title = "Photo.png"; local_path = "/tmp/Photo.png"; payload = "{}"} in
      App_test.send app (Model.SetComposerTags [{Model.uuid = Q.project; title = "Project"}]);
      App_test.send app (Model.StageComposerAsset asset);
      App_test.send app Model.SendComposer; App_test.flush app;
      let eff = List.find (function Model.SendAssetEffect _ -> true | _ -> false) (App.model app).pending_effects in
      let encoded = J.from_string (Native_bridge.encode_effect eff) in
      let id = match member "id" encoded with `Int id -> id | _ -> fail "Missing asset effect" in
      App_test.send app (Model.DequeueEffect id);
      if switch then App_test.send app (Model.ApplyCoreSnapshot (projection_for_graph snapshot "other" false));
      App_test.flush app;
      if switch then check_eq ~msg:"old in-flight assets cannot be saved in another graph's session" (Model.ui_session (App.model app)).assets [];
      App_test.send app (Model.ResolveEffect (id, false, "Local persistence failed")); App_test.flush app;
      let current = App.model app in
      check_eq ~msg:"only the capture graph can recover an asset" (List.length current.composer_assets) (if switch then 0 else 1);
      check_eq ~msg:"asset retries must show their tags" (List.map (fun (tag : Model.sidebar_page) -> tag.uuid) current.composer_tags)
        (if switch then [] else [Q.project]);
      if not switch then begin
        App_test.send app (Model.RemoveComposerTag Q.project);
        App_test.send app Model.SendComposer; App_test.flush app;
        let retry = List.find (function Model.SendAssetEffect _ -> true | _ -> false) (App.model app).pending_effects in
        let payload = J.from_string (text (member "text" (J.from_string (Native_bridge.encode_effect retry)))) in
        check_eq ~msg:"removing a recovered chip removes it from the retry" (items "selectedValues" (member "tags" payload)) []
      end))) [false; true]) [App_test.ios_backend; App_test.kotlin_backend]

let adjacent_reference_tags_target_the_page () =
  List.iter (fun (reference, target_name) -> R.with_runtime (fun session runtime conn ->
    let title = "[[" ^ reference ^ "]]#Pro" in
    ignore (Node_property_test.result (Rpc_test.dispatch_json session "outlinerEvent" (J.to_string (`Assoc [
      "type", `String "tapBlock"; "uuid", `String R.gamma]))));
    ignore (Node_property_test.result (Rpc_test.dispatch_json session "outlinerEvent" (J.to_string (`Assoc [
      "type", `String "textChanged"; "title", `String title;
      "caretUTF16Offset", `Int (String_kit.utf16_length title)]))));
    ignore (Node_property_test.result (Rpc_test.dispatch_json session "outlinerEvent" (J.to_string (`Assoc [
      "type", `String "chooseAutocomplete"; "value", `String Q.project]))));
    let db = Graph_runtime.db runtime in
    let target = Option.get (Graph_read.unique_named_uuid false db target_name) in
    check ~msg:"the adjacent wiki reference receives the selected tag"
      (List.mem "Project" (tag_titles runtime target));
    check ~msg:"the containing block does not receive the adjacent tag"
      (not (List.mem "Project" (tag_titles runtime R.gamma)));
    sync_all runtime conn))
    ["Workspace", "Workspace"; "New destination", "New destination"]

let rename_page_rejects_hashes_without_writes () = R.with_runtime (fun session runtime _ ->
  let rename = member "rename" (member "nodeProperties" (Node_property_test.result (Node_property_test.read session Q.page))) in
  let before = Graph_runtime.pending_operations runtime in
  List.iter (fun title ->
    check_eq ~msg:"Rename page accepts only a page name"
      (member "ok" (Node_property_test.edit session Q.page rename title [])) (`Bool false);
    check_eq ~msg:"rejected names do not create tags or enqueue writes"
      (Graph_runtime.pending_operations runtime) before) ["Workspace #Project"; "Workspace#Mobile"])

let new_property_definitions_roundtrip_through_sync () = R.with_runtime (fun session runtime conn ->
  List.iter (fun owner -> ignore (Node_property_test.result
    (Node_property_test.create_named_property session owner (if owner = Q.page then "Page notes" else "Tag notes"))))
    [Q.page; Q.project];
  sync_all runtime conn;
  List.iter (fun title ->
    let db = Graph_runtime.db runtime in
    let uuid = Graph_read.unique_named_uuid false db title |> Option.get in
    let id = Datascript.entid db "block/uuid" (Datascript.Uuid uuid) |> Option.get in
    check ~msg:"confirmed properties retain their type and schema" (Node_title.is_property db id)) ["Page notes"; "Tag notes"])

let shortcut_text_preserves_readable_tags_and_page_references () = R.with_runtime (fun session runtime conn ->
  let capture uuid text = succeed (Rpc_test.dispatch_json session "send" (J.to_string (`Assoc [
    "uuid", `String uuid; "text", `String text; "now", `Int 1792719000000]))) in
  capture captured "Buy milk #task [[Workspace]] [[快捷记录/子页面]]";
  let db = Graph_runtime.db runtime in
  let id = Option.get (Datascript.entid db "block/uuid" (Datascript.Uuid captured)) in
  let block = Option.get (Graph_read.block (fun x -> Ok x) db id) in
  let rendered = Node_presentation.decorate db captured (Rpc.block_json block) in
  let markup = items "markup" rendered in
  let tag = List.find_opt (fun value -> member "type" value = `String "tagReference") markup in
  check ~msg:"shortcut hashtags render as a named tag, never a raw UUID" (Option.is_some tag);
  check_eq (member "title" (Option.get tag)) (`String "Task");
  let pages = List.filter (fun value -> member "type" value = `String "nodeReference") markup in
  check ~msg:"shortcut references to existing pages remain tappable"
    (List.exists (fun value -> member "uuid" value = `String Q.page) pages);
  let child = Graph_read.unique_named_uuid false db "快捷记录/子页面" in
  check ~msg:"shortcut references create missing pages" (Option.is_some child);
  let child = Option.get child in
  check ~msg:"new shortcut references render as named links"
    (List.exists (fun value -> member "uuid" value = `String child) pages);
  let parent = Graph_read.unique_named_uuid false db "快捷记录" in
  check ~msg:"shortcut page creation preserves namespace hierarchy" (Option.is_some parent);
  capture "80000000-0000-4000-8000-000000000099" "Again [[快捷记录/子页面]]";
  check_eq ~msg:"repeated shortcut references reuse the same page"
    (Graph_read.unique_named_uuid false (Graph_runtime.db runtime) "快捷记录/子页面") (Some child);
  ignore (Rpc_test.dispatch_json session "openNode" (J.to_string (`Assoc ["uuid", `String captured])));
  let editing = Editor_command_test.event session "tapBlock" ["uuid", `String captured] in
  let route = items "nodeRoutes" editing |> List.rev |> List.hd in
  let title = R.text (member "title" (member "editing" (member "outlinerState" route))) in
  let references = Ref_text.references title in
  check ~msg:"editing shortcut captures uses readable page and tag names"
    (List.exists (fun (reference : Ref_text.reference) -> reference.kind = Ref_text.Tag && reference.name = "Task") references
     && List.exists (fun (reference : Ref_text.reference) -> reference.kind = Ref_text.Page && reference.name = "子页面") references);
  ignore (Editor_command_test.type_at session (title ^ " revised") (Outliner_state.utf16_length (title ^ " revised")));
  Editor_command_test.save session;
  let saved = Option.get (Graph_read.block (fun x -> Ok x) (Graph_runtime.db runtime) id) in
  check ~msg:"editing a shortcut reference preserves its original target"
    (List.exists (fun (reference : Cache_model.entity_summary) -> reference.uuid = child) saved.references);
  capture "80000000-0000-4000-8000-000000000098" "Literal `#task [[Code literal]]`";
  check_eq ~msg:"shortcut code spans keep reference markers literal"
    (Graph_read.unique_named_uuid false (Graph_runtime.db runtime) "Code literal") None;
  sync_all runtime conn)

let cases = [
  case "shortcut text renders tags and creates reusable page references" shortcut_text_preserves_readable_tags_and_page_references;
  case "new page and tag properties survive confirmed sync" new_property_definitions_roundtrip_through_sync;
  case "adjacent wiki reference tags apply to the referenced page" adjacent_reference_tags_target_the_page;
  case "Rename page rejects hash syntax atomically" rename_page_rejects_hashes_without_writes;
  case "graph changes reset the tag picker" graph_changes_reset_the_tag_picker;
  case "asset failures recover in the capture graph" failed_asset_captures_recover_only_in_their_graph;
  case "fresh journal captures preserve note text" fresh_journal_captures_preserve_the_note;
  case "assets assign tags and preserve filenames" assets_assign_tags_without_changing_the_filename;
  case "capture assigns existing and new tags" capture_assigns_existing_and_new_tags;
  case "invalid tags leave no partial capture" invalid_tags_do_not_capture_or_create;
  case "inline tags and task status survive" inline_tags_and_status_survive;
  case "catalog is lazy and read-only" catalog_uses_graph_tags_without_writes;
  case "shared native picker stages and removes tags" shared_picker_stages_and_removes_tags;
]
