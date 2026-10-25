open Test_util
module Ds = Datascript
module J = Yojson.Basic
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let items = Q.items
let text = R.text
let put = Q.put
let result response =
  check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true);
  member "result" response
let event session kind fields = result (Rpc_test.dispatch_json session "outlinerEvent"
  (J.to_string (`Assoc (("type", `String kind) :: fields))))
let snapshot session = result (J.from_string (Rpc_session.snapshot_visible session))
let state response = member "outlinerState" response
let draft response = member "editing" (state response)
let choices response = items "outlinerAutocompleteCandidates" response
let type_at session title caret = event session "textChanged"
  ["title", `String title; "caretUTF16Offset", `Int caret]
let start session title =
  ignore (event session "tapBlock" ["uuid", `String Q.alpha]);
  type_at session title (Outliner_state.utf16_length title)
let choose session value = event session "chooseAutocomplete" ["value", `String value]
let command session label =
  let response = snapshot session in
  match List.find_opt (fun row -> member "label" row = `String label) (choices response) with
  | Some row -> choose session (text (member "value" row))
  | None -> fail ("Missing command: " ^ label ^ " in " ^ J.to_string (`List (choices response)))
let run session label = ignore (start session "/"); command session label
let value runtime uuid attr =
  let db = Graph_runtime.db runtime in
  Option.bind (Ds.entid db "block/uuid" (Ds.Uuid uuid)) (fun eid -> Graph_read.value db eid attr)
let save session = ignore (event session "saveEditing" [])
let submit session value = event session "submitAutocomplete" ["value", `String value]
let rebase runtime conn tx =
  ignore (Ds.transact_conn conn tx);
  Graph_runtime.rebase runtime (Graph_runtime.state runtime).server_t [] []

let pasted_markers_do_not_open_completion () = R.with_runtime (fun session _ _ ->
  List.iter (fun title ->
    ignore (event session "tapBlock" ["uuid", `String Q.alpha]);
    let response = event session "textChanged" ["title", `String title;
      "caretUTF16Offset", `Int (Outliner_state.utf16_length title); "inputOrigin", `String "paste"] in
    check_eq ~msg:("paste stays literal: " ^ title) (member "autocomplete" (state response)) `Null;
    let response = event session "caretMoved" ["caretUTF16Offset", `Int (Outliner_state.utf16_length title)] in
    check_eq ~msg:"selection changes do not reopen pasted syntax" (member "autocomplete" (state response)) `Null;
    let response = type_at session (title ^ "x") (Outliner_state.utf16_length title + 1) in
    check_eq ~msg:"typing ordinary text after a paste does not activate pasted syntax"
      (member "autocomplete" (state response)) `Null;
    let typed = title ^ "x /" in
    let response = type_at session typed (Outliner_state.utf16_length typed) in
    check_eq ~msg:"a freshly typed trigger starts a new completion"
      (member "kind" (member "autocomplete" (state response))) (`String "command"))
    ["Pasted text /"; "🙂 /"; "Pasted [["; "Pasted #"; "/Heading 1"])

let catalog_search_and_literal_boundaries () = R.with_runtime (fun session _ _ ->
  let response = start session "/" in
  check_eq ~msg:"slash uses the shared completion state"
    (member "kind" (member "autocomplete" (state response))) (`String "command");
  let labels = List.map (fun row -> text (member "label" row)) (choices response) in
  List.iter (fun label -> check ~msg:("built-in command missing: " ^ label) (List.mem label labels))
    ["Node embed"; "Link"; "Image link"; "Underline"; "Code block"; "Quote"; "Math block";
     "Clear heading"; "Heading 1"; "Heading 6"; "Deadline"; "Scheduled";
     "Tomorrow"; "Yesterday"; "Today"; "Current time"; "Date picker"; "Number list";
     "Number children"; "Calculator"; "Template"; "Embed HTML"; "Embed Video URL";
     "Embed YouTube timestamp"; "Embed Twitter tweet"; "Cloze"; "No priority"];
  List.iter (fun label -> check ~msg:("excluded command: " ^ label) (not (List.mem label labels)))
    ["Query"; "Advanced Query"; "Query function"; "Add property"; "Add comment";
     "Upload an asset"; "Node reference"; "Normal text"];
  let response = start session "/h6" in
  check ~msg:"command search is fuzzy" (List.exists (fun row -> member "label" row = `String "Heading 6") (choices response));
  List.iter (fun title -> let response = start session title in
    check_eq ~msg:("literal marker: " ^ title) (member "autocomplete" (state response)) `Null)
    ["https://example.com/a"; "a/b"; "`/head`"; "```\n/head"; "\\/head"; "{{video /head}}"];
  ignore (start session "Keep /head");
  let response = event session "dismissAutocomplete" [] in
  check_eq (member "title" (draft response)) (`String "Keep /head");
  check_eq (member "autocomplete" (state response)) `Null;
  ignore (choose session "command:heading-1");
  check_eq (member "title" (draft (snapshot session))) (`String "Keep /head"))

let inline_commands_preserve_caret_and_suffix () =
  List.iter (fun (label, inserted, backward) -> R.with_runtime (fun session _ _ ->
    ignore (start session "🙂 中文 / suffix");
    ignore (type_at session "🙂 中文 / suffix" 7);
    let response = command session label in
    check_eq (member "title" (draft response)) (`String ("🙂 中文 " ^ inserted ^ " suffix"));
    check_eq (member "caretUTF16Offset" (draft response))
      (`Int (6 + Outliner_state.utf16_length inserted - backward));
    check_eq (member "autocomplete" (state response)) `Null))
    ["Underline", "<ins></ins>", 6; "Embed HTML", "@@html: @@", 2;
     "Embed Video URL", "{{video }}", 2; "Embed Twitter tweet", "{{tweet }}", 2;
     "Cloze", "{{cloze }}", 2]

let graph_choices_headings_and_block_types () = R.with_runtime (fun session runtime conn ->
  let custom = "30000000-0000-4000-8000-000000000001" in
  rebase runtime conn (R.entity 100 custom "Critical" @ [
    put custom "block/closed-value-property" (Ds.Ref_to (Ds.Ident "logseq.property/priority"));
    put custom "block/order" (Ds.String "a0")]);
  ignore (run session "Critical"); save session;
  check ~msg:"graph priorities are selectable" (value runtime Q.alpha "logseq.property/priority" <> None);
  ignore (run session "No priority"); save session;
  check_eq (value runtime Q.alpha "logseq.property/priority") None;
  List.iter (fun n -> ignore (run session ("Heading " ^ string_of_int n)); save session;
    check_eq (value runtime Q.alpha "logseq.property/heading") (Some (Ds.Int64 (Int64.of_int n)))) [1;2;3;4;5;6];
  ignore (run session "Clear heading"); save session;
  check_eq (value runtime Q.alpha "logseq.property/heading") None;
  List.iter (fun (label, typ) -> let response = run session label in
    let uuid = text (member "uuid" (draft response)) in
    save session;
    check_eq (value runtime uuid "logseq.property.node/display-type") (Some (Ds.Keyword typ));
    if label = "Calculator" then check_eq (value runtime uuid "logseq.property.code/lang") (Some (Ds.String "calc")))
    ["Quote", "quote"; "Math block", "math"; "Code block", "code"; "Calculator", "code"];
  ignore (run session "Clear heading"); save session;
  check_eq (value runtime Q.alpha "logseq.property/heading") None;
  ignore (run session "Todo"); save session;
  check ~msg:"task statuses are graph choices" (value runtime Q.alpha "logseq.property/status" <> None);
  List.iter (fun operation -> match Graph_runtime.prepare_sync runtime operation with
    | Ok _ -> () | Error message -> fail message) (Graph_runtime.pending_operations runtime))

let links_and_dates_use_shared_prompts () = R.with_runtime (fun session runtime _ ->
  ignore (run session "Link");
  let response = submit session {|{"url":"https://logseq.com/a b","label":"Logseq"}|} in
  check_eq (member "title" (draft response)) (`String "[Logseq](https://logseq.com/a%20b)"); save session;
  ignore (run session "Image link");
  let response = submit session {|{"url":"https://logseq.com/pic.png","label":"Picture"}|} in
  check_eq (member "title" (draft response)) (`String "![Picture](https://logseq.com/pic.png)");
  ignore (run session "Date picker");
  let response = submit session "2026-10-23" in
  check ~msg:"date selection inserts a journal reference" (String_kit.starts_with ~prefix:"[[" (text (member "title" (draft response))));
  List.iter (fun label -> ignore (run session label); let response = snapshot session in
    check ~msg:label (String.length (text (member "title" (draft response))) > 0)) ["Today"; "Yesterday"; "Tomorrow"; "Current time"];
  List.iter (fun (label, attr) -> ignore (run session label);
    ignore (submit session "1792719000000"); save session;
    let prop = Node_property_test.property attr (Node_property_test.result (Node_property_test.read session Q.alpha)) in
    check_eq (member "editorValue" prop) (`String "1792719000000"))
    ["Deadline", "logseq.property/deadline"; "Scheduled", "logseq.property/scheduled"];
  ignore (run session "Embed YouTube timestamp");
  let response = submit session "01:32" in
  check_eq (member "title" (draft response)) (`String "{{youtube-timestamp 92}}");
  ignore (run session "Link");
  let before = List.length (Graph_runtime.pending_operations runtime) in
  let bad = Rpc_test.dispatch_json session "outlinerEvent" {|{"type":"submitAutocomplete","value":"{\"url\":\"javascript:alert(1)\"}"}|} in
  check_eq (member "ok" bad) (`Bool false);
  check_eq (List.length (Graph_runtime.pending_operations runtime)) before;
  check ~msg:"invalid input leaves the prompt open" (member "autocomplete" (state (snapshot session)) <> `Null))

let embeds_delete_only_the_wrapper () = R.with_runtime (fun session runtime conn ->
  let child = "30000000-0000-4000-8000-000000000002" in
  rebase runtime conn (R.entity 101 child "Source child" @ [
    put child "block/page" (Ds.Ref_to (Q.ref_uuid Q.page));
    put child "block/parent" (Ds.Ref_to (Q.ref_uuid Q.beta)); put child "block/order" (Ds.String "a0")]);
  ignore (run session "Node embed");
  let response = event session "searchAutocomplete" ["query", `String "Beta"] in
  check ~msg:"embed search uses shared node candidates" (List.exists (fun row -> member "value" row = `String Q.beta) (choices response));
  ignore (choose session Q.beta); save session;
  let db = Graph_runtime.db runtime in
  let target = Option.get (Ds.entid db "block/uuid" (Ds.Uuid Q.beta)) in
  check_eq (value runtime Q.alpha "block/link") (Some (Ds.Ref target));
  ignore (event session "longPressBlock" ["uuid", `String Q.alpha]);
  ignore (event session "toolbar" ["action", `String "delete"]);
  ignore (event session "confirmDelete" []);
  check_eq (value runtime Q.alpha "block/title") None;
  check_eq (value runtime Q.beta "block/title") (Some (Ds.String "Beta result"));
  check_eq (value runtime child "block/title") (Some (Ds.String "Source child"));
  List.iter (fun operation -> match Graph_runtime.prepare_sync runtime operation with
    | Ok _ -> () | Error message -> fail message) (Graph_runtime.pending_operations runtime))

let linked_blocks_edit_source_contents () =
  List.iter (fun outside_page -> R.with_runtime (fun session runtime conn ->
    ignore (run session "Node embed");
    ignore (choose session Q.beta);
    save session;
    if outside_page then begin
      let page = "30000000-0000-4000-8000-000000000021" in
      rebase runtime conn (R.entity 121 page "Source page" @ [
        put page "block/name" (Ds.String "source page");
        put Q.beta "block/page" (Ds.Ref_to (Q.ref_uuid page));
        put Q.beta "block/parent" (Ds.Ref_to (Q.ref_uuid page))])
    end;
    let target = Option.get (Ds.entid (Graph_runtime.db runtime) "block/uuid" (Ds.Uuid Q.beta)) in
    check_eq ~msg:"The fixture must contain a link to the source block"
      (value runtime Q.alpha "block/link") (Some (Ds.Ref target));
    let response = event session "tapBlock" ["uuid", `String Q.alpha] in
    check_eq ~msg:"The editor stays mounted at the linked row"
      (member "uuid" (draft response)) (`String Q.alpha);
    check_eq ~msg:"Editing a linked block loads its source content instead of the empty wrapper"
      (member "title" (draft response)) (`String "Beta result");
    List.iter (fun backend ->
      Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
        let editor = App_test.extension_node app "outliner-editor" in
        check ~msg:"The linked row mounts a native editor" (editor <> -1);
        check_eq ~msg:"Both native hosts receive the linked source text"
          (App_test.extension_property app editor "title")
          (Some (Lui_protocol.StringValue "Beta result"));
        check_eq ~msg:"Native editor events retain the displayed row identity"
          (App_test.extension_property app editor "block-id")
          (Some (Lui_protocol.StringValue Q.alpha))))
      [App_test.ios_backend; App_test.kotlin_backend];
    let pending = List.length (Graph_runtime.pending_operations runtime) in
    save session;
    check_eq ~msg:"Opening and saving an unchanged linked block adds no write"
      (List.length (Graph_runtime.pending_operations runtime)) pending;
    List.iter (fun title ->
      ignore (type_at session title (Outliner_state.utf16_length title));
      save session;
      check_eq ~msg:"Edits are saved to the source block"
        (value runtime Q.beta "block/title") (Some (Ds.String title));
      check_eq ~msg:"Editing must not put a duplicate title on the link wrapper"
        (value runtime Q.alpha "block/title") (Some (Ds.String "")))
      ["Edited linked content"; "Edited linked content again"];
    ignore (event session "cancelEditing" []);
    let response = event session "tapBlock" ["uuid", `String Q.alpha] in
    check_eq ~msg:"Reopening a linked editor reads the saved source"
      (member "title" (draft response)) (`String "Edited linked content again");
    check_eq ~msg:"Editing retains the live block link"
      (value runtime Q.alpha "block/link") (Some (Ds.Ref target)))) [false; true]

let linked_pages_edit_the_unrendered_source () = R.with_runtime (fun session runtime conn ->
  rebase runtime conn [
    put Q.alpha "block/title" (Ds.String "");
    put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta));
    put Q.beta "block/name" (Ds.String "beta result");
    put Q.beta "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Page"))];
  let before = snapshot session in
  check ~msg:"The source page is not rendered alongside its link"
    (not (List.exists (fun row -> member "uuid" (member "block" row) = `String Q.beta)
      (items "outlinerRows" before)));
  let response = event session "tapBlock" ["uuid", `String Q.alpha] in
  check_eq ~msg:"A link to a source page enters editing in the current row"
    (member "uuid" (draft response)) (`String Q.alpha);
  check_eq ~msg:"A source page loads its title without being rendered first"
    (member "title" (draft response)) (`String "Beta result");
  ignore (type_at session "Renamed source page" 19);
  save session;
  check_eq (value runtime Q.beta "block/title") (Some (Ds.String "Renamed source page"));
  check_eq ~msg:"Source page edits preserve the shared page naming rules"
    (value runtime Q.beta "block/name") (Some (Ds.String "renamed source page"));
  check_eq ~msg:"The link wrapper remains an empty live link"
    (value runtime Q.alpha "block/title") (Some (Ds.String ""));
  ignore (event session "cancelEditing" []);
  let response = event session "tapBlock" ["uuid", `String Q.alpha] in
  check_eq (member "title" (draft response)) (`String "Renamed source page"))

let linked_pages_validate_saved_names () =
  List.iter (fun invalid -> R.with_runtime (fun session runtime conn ->
    rebase runtime conn [
      put Q.alpha "block/title" (Ds.String "");
      put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta));
      put Q.beta "block/name" (Ds.String "beta result")];
    let response = event session "tapBlock" ["uuid", `String Q.alpha] in
    check_eq ~msg:"The page link must open before testing name validation"
      (member "title" (draft response)) (`String "Beta result");
    ignore (type_at session invalid (Outliner_state.utf16_length invalid));
    let response = Rpc_test.dispatch_json session "outlinerEvent" {|{"type":"saveEditing"}|} in
    check_eq ~msg:"Linked page edits must retain shared name validation" (member "ok" response) (`Bool false);
    check_eq (value runtime Q.beta "block/title") (Some (Ds.String "Beta result"));
    check_eq (value runtime Q.beta "block/name") (Some (Ds.String "beta result"))))
    [""; "invalid#page"; "invalid/page"]

let linked_pages_keep_name_protections () =
  List.iter (fun protected -> R.with_runtime (fun session runtime conn ->
    rebase runtime conn ([
      put Q.alpha "block/title" (Ds.String "");
      put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta));
      put Q.beta "block/name" (Ds.String "beta result")] @ protected);
    let pending = List.length (Graph_runtime.pending_operations runtime) in
    let response = event session "tapBlock" ["uuid", `String Q.alpha] in
    check_eq ~msg:"Protected page names cannot be edited through a link" (draft response) `Null;
    check_eq (List.length (Graph_runtime.pending_operations runtime)) pending))
    [[put Q.beta "logseq.property/built-in?" (Ds.Bool true)];
     [put Q.beta "block/journal-day" (Ds.Int64 20261024L)]]

let linked_content_changes_refresh_visible_wrappers () = R.with_runtime (fun session runtime conn ->
  rebase runtime conn [
    put Q.alpha "block/title" (Ds.String "");
    put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta));
    put R.gamma "block/title" (Ds.String "");
    put R.gamma "block/link" (Ds.Ref_to (Q.ref_uuid Q.alpha))];
  ignore (event session "tapBlock" ["uuid", `String Q.alpha]);
  ignore (type_at session "Updated source" 14);
  let response = event session "saveEditing" [] in
  List.iter (fun uuid ->
    match List.find_opt (fun block -> member "uuid" block = `String uuid) (items "blocks" response) with
    | None -> fail "A source title change must patch every visible linked wrapper"
    | Some block ->
      let content = `List [`Assoc ["type", `String "text"; "text", `String "Updated source"]] in
      check_eq ~msg:"A patched link renders normal source markup without an added quote"
        (member "markup" block) content)
    [Q.alpha; R.gamma];
  let response = event session "tapBlock" ["uuid", `String R.gamma] in
  check_eq ~msg:"Chained links edit the final source content"
    (member "title" (draft response)) (`String "Updated source"))

let node_completion_renders_resolved_references () =
  List.iter (fun embed -> R.with_runtime (fun session runtime conn ->
    rebase runtime conn [
      put Q.beta "block/title" (Ds.String "Referenced node");
      put R.gamma "block/title" (Ds.String ("Hello [[" ^ Q.beta ^ "]]"));
      put R.gamma "block/refs" (Ds.Ref_to (Q.ref_uuid Q.beta))];
    let response = if embed then begin
      ignore (run session "Node embed");
      event session "searchAutocomplete" ["query", `String "Hello"]
    end else start session "[[Hello" in
    let index, candidate = List.mapi (fun i c -> i, c) (choices response)
      |> List.find (fun (_, c) -> member "value" c = `String R.gamma) in
    check_eq ~msg:"Both node and embed completion resolve referenced labels"
      (member "label" candidate) (`String "Hello Referenced node");
    let markup = items "markup" candidate in
    check ~msg:"Node completion carries the shared node-reference markup"
      (List.exists (fun node -> member "type" node = `String "nodeReference"
        && member "uuid" node = `String Q.beta && member "title" node = `String "Referenced node") markup);
    List.iter (fun backend -> Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let button = App_test.descendant_with_identifier host (Lui_app.root_node app)
        ("button.outliner.autocomplete." ^ string_of_int index) in
      check ~msg:"Resolved completion has a native selection action" (button <> -1);
      let renderer = App_test.descendant_with_extension host app button "outliner-block-content" in
      check ~msg:"Completion reuses the existing block/reference renderer" (renderer <> -1);
      App_test.dispatch app (Lui_protocol.Press button); App_test.flush app;
      check ~msg:"Tapping a reference-containing candidate chooses the original node"
        (List.exists (function Model.ChooseOutlinerAutocompleteEffect (_, value) -> value = R.gamma | _ -> false)
          ((App.model app).Model.pending_effects @ (App.model app).Model.in_flight_effects))))
      [App_test.ios_backend; App_test.kotlin_backend])) [false; true]

let linked_blocks_preserve_source_formatting () =
  List.iter (fun quoted -> R.with_runtime (fun session runtime conn ->
    rebase runtime conn ([
      put Q.alpha "block/title" (Ds.String "");
      put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta))] @
      if quoted then [put Q.beta "logseq.property.node/display-type" (Ds.Keyword "quote")] else []);
    let response = snapshot session in
    let markup uuid = member "markup" (List.find (fun row -> member "uuid" row = `String uuid) (items "blocks" response)) in
    check_eq ~msg:"Link presentation preserves the source markup without wrapping it in another quote"
      (markup Q.alpha) (markup Q.beta);
    let projection = match Response_snapshot.decode_response (Rpc_session.snapshot_visible session) with
      | Ok value -> value | Error message -> fail message in
    let linked = List.find (fun (row : Model.outline_row) -> row.row_uuid = Q.alpha) projection.outliner_rows in
    check_eq ~msg:"Native caret hit testing uses the source title, not the empty wrapper title"
      linked.row_title "Beta result")) [false; true]

let linked_content_keeps_outline_boundaries () =
  List.iter (fun (kind, caret) -> R.with_runtime (fun session runtime conn ->
    rebase runtime conn [
      put Q.alpha "block/title" (Ds.String "");
      put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta))];
    ignore (event session "tapBlock" ["uuid", `String Q.alpha]);
    ignore (type_at session "Edited source" caret);
    ignore (event session kind (if kind = "backspacePressed" then ["selectionLength", `Int 0] else []));
    check_eq ~msg:"Outline boundary editing keeps the linked source alive"
      (value runtime Q.beta "block/title")
      (Some (Ds.String (if kind = "returnPressed" && caret = 6 then "Edited" else "Edited source")));
    if kind = "returnPressed" then
      check_eq ~msg:"Splitting a linked row retains its empty wrapper title"
        (value runtime Q.alpha "block/title") (Some (Ds.String ""))
    else check_eq ~msg:"Backspace removes the wrapper, not the linked source"
      (value runtime Q.alpha "block/title") None))
    ["returnPressed", 13; "returnPressed", 6; "returnPressed", 0; "backspacePressed", 0]

let linked_editing_tracks_the_captured_source () = R.with_runtime (fun session runtime conn ->
  rebase runtime conn [
    put Q.alpha "block/title" (Ds.String "");
    put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta))];
  ignore (event session "tapBlock" ["uuid", `String Q.alpha]);
  rebase runtime conn [put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid R.gamma))];
  ignore (type_at session "Captured source" 15);
  save session;
  check_eq ~msg:"A retargeted wrapper cannot redirect an existing edit to another source"
    (value runtime Q.beta "block/title") (Some (Ds.String "Captured source"));
  check_eq (value runtime R.gamma "block/title") (Some (Ds.String "Gamma result")))

let cyclic_links_do_not_open_an_empty_editor () = R.with_runtime (fun session runtime conn ->
  rebase runtime conn [
    put Q.alpha "block/title" (Ds.String "");
    put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta));
    put Q.beta "block/link" (Ds.Ref_to (Q.ref_uuid Q.alpha))];
  let pending = List.length (Graph_runtime.pending_operations runtime) in
  let response = event session "tapBlock" ["uuid", `String Q.alpha] in
  check_eq ~msg:"Cyclic links have no editable source" (draft response) `Null;
  check_eq ~msg:"Tapping an invalid link does not create a write"
    (List.length (Graph_runtime.pending_operations runtime)) pending)

let switching_linked_rows_preserves_unsaved_content () = R.with_runtime (fun session runtime conn ->
  rebase runtime conn [
    put Q.alpha "block/title" (Ds.String "");
    put Q.alpha "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta));
    put R.gamma "block/title" (Ds.String "");
    put R.gamma "block/link" (Ds.Ref_to (Q.ref_uuid Q.beta))];
  ignore (event session "tapBlock" ["uuid", `String Q.alpha]);
  ignore (type_at session "Unsaved source" 14);
  let response = event session "tapBlock" ["uuid", `String R.gamma] in
  check_eq ~msg:"Switching between linked rows cannot restore stale source text"
    (member "title" (draft response)) (`String "Unsaved source");
  ignore (type_at session "Unsaved source continued" 24);
  save session;
  check_eq (value runtime Q.beta "block/title") (Some (Ds.String "Unsaved source continued")))

let templates_clone_without_mutating_the_source () = R.with_runtime (fun session runtime conn ->
  let child = "30000000-0000-4000-8000-000000000004" in
  let grandchild = "30000000-0000-4000-8000-000000000005" in
  rebase runtime conn ([put Q.beta "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Template"))]
    @ R.entity 103 child "Meeting <%current page%>"
    @ [put child "block/page" (Ds.Ref_to (Q.ref_uuid Q.page));
       put child "block/parent" (Ds.Ref_to (Q.ref_uuid Q.beta)); put child "block/order" (Ds.String "a0");
       put child "logseq.property/heading" (Ds.Int64 2L)]
    @ R.entity 104 grandchild "Nested note"
    @ [put grandchild "block/page" (Ds.Ref_to (Q.ref_uuid Q.page));
       put grandchild "block/parent" (Ds.Ref_to (Q.ref_uuid child)); put grandchild "block/order" (Ds.String "a0")]);
  ignore (run session "Template");
  ignore (event session "searchAutocomplete" ["query", `String "Beta"]);
  ignore (choose session Q.beta); save session;
  let inserted = value runtime Q.alpha "block/title" in
  check ~msg:"templates insert their children and resolve target-page variables"
    (match inserted with Some (Ds.String title) -> String_kit.starts_with ~prefix:"Meeting [[" title | _ -> false);
  check_eq (value runtime Q.alpha "logseq.property/heading") (Some (Ds.Int64 2L));
  let children = Graph_runtime.blocks_for_page runtime Q.page |> List.filter (fun (b : Cache_model.block) ->
    b.parent_id = Some Q.alpha) in
  check ~msg:"nested template children have new identities" (List.exists (fun (b : Cache_model.block) ->
    b.title = "Nested note" && b.uuid <> grandchild) children);
  check_eq (value runtime Q.beta "block/title") (Some (Ds.String "Beta result"));
  check_eq ~msg:"template application does not create a live link" (value runtime Q.alpha "block/link") None)

let code_commands_update_the_active_editor_style () =
  List.iter (fun backend -> List.iter (fun label -> R.with_runtime (fun session _ _ ->
    ignore (run session label);
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      let editor = App_test.extension_node app "outliner-editor" in
      check ~msg:"code conversion keeps the editor mounted" (editor <> -1);
      let policy = match App_test.extension_property app editor "input-policy" with
        | Some (Lui_protocol.StringValue value) -> J.from_string value | _ -> `Null in
      check_eq ~msg:"Code, Calculator and Math commands immediately select their editor presentation"
        (member "code" policy) (`Bool (label <> "Math block"));
      check_eq ~msg:"Enter inserts a line break in Code and Calculator while Math creates a block"
        (member "multiline" policy) (`Bool (label <> "Math block")))))
    ["Code block"; "Calculator"; "Math block"]) [App_test.ios_backend; App_test.kotlin_backend]

let calculator_last_tracks_successful_lines () = R.with_runtime (fun session _ _ ->
  ignore (run session "Calculator");
  List.iter (fun (source, expected) ->
    ignore (type_at session source (Outliner_state.utf16_length source)); save session;
    let response = snapshot session in
    let block = List.find (fun block -> member "uuid" block = `String Q.alpha) (items "blocks" response) in
    let rendered = J.to_string (member "markup" block) in
    check ~msg:("calculator last follows the previous successful expression: " ^ source)
      (String_kit.includes ~sub:expected rendered);
    ignore (event session "tapBlock" ["uuid", `String Q.alpha])) [
    "6*7\nlast*3", "last*3  = 126";
    "3^2+4^2\nsqrt(last)", "sqrt(last)  = 5";
    "2*3\n# a comment\n\n   \nlast*2", "last*2  = 12";
    "2*3\ninvalid(2)\nlast*2", "last*2  = Error";
    "last+1", "last+1  = Error"])

let command_output_has_native_presentation () = R.with_runtime (fun session runtime _ ->
  let block () = List.find (fun block -> member "uuid" block = `String Q.alpha) (items "blocks" (snapshot session)) in
  ignore (run session "Heading 2"); save session;
  check ~msg:"heading formatting reaches the renderer"
    (String_kit.includes ~sub:"heading-2" (J.to_string (member "markup" (block ()))));
  ignore (run session "Number list"); save session;
  check_eq ~msg:"ordered list numbers reach the native bullet slot" (member "listNumber" (block ())) (`Int 1);
  ignore (run session "Calculator");
  ignore (type_at session "2 + 3 * 4" 9); save session;
  let markup = J.to_string (member "markup" (block ())) in
  check ~msg:"calculator blocks show their evaluated result" (String_kit.includes ~sub:"14" markup);
  check ~msg:"calculator blocks retain their language" (String_kit.includes ~sub:"calc" markup);
  ignore (run session "Node embed");
  ignore (choose session Q.beta);
  let markup = J.to_string (member "markup" (block ())) in
  check ~msg:"embedded nodes render their source content" (String_kit.includes ~sub:"Beta result" markup);
  check_eq ~msg:"rendered embed identity stays the wrapper UUID" (member "uuid" (block ())) (`String Q.alpha))

let embedded_outliner_bullets_match_master () = R.with_runtime (fun session _ _ ->
  ignore (run session "Number list"); save session;
  ignore (run session "Node embed"); ignore (choose session Q.beta);
  let response = snapshot session in
  let embedded = List.find (fun block -> member "uuid" block = `String Q.alpha) (items "blocks" response) in
  check_eq ~msg:"only linked wrapper rows carry the embed marker" (member "isEmbed" embedded) (`Bool true);
  let ordinary = List.find (fun block -> member "uuid" block = `String Q.beta) (items "blocks" response) in
  check ~msg:"source blocks retain their ordinary bullet" (member "isEmbed" ordinary <> `Bool true);
  List.iter (fun (backend, ios) -> Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
    let host = Lui_app.runtime app in
    let row = App_test.descendant_with_identifier host (Lui_app.root_node app) ("outliner.block." ^ Q.alpha) in
    check ~msg:"embedded wrapper is present in the outliner" (row <> -1);
    let descriptor = if ios then (
      let payload = App_test.native_row_payload app row in
      check_eq ~msg:"embed arrows take precedence over numbered bullets" (member "listNumber" payload) `Null;
      member "nodeIcon" payload)
    else (
      let icon = App_test.descendant_with_extension host app row "node-icon" in
      match App_test.extension_property app icon "payload" with
      | Some (Lui_protocol.StringValue raw) -> J.from_string raw
      | _ -> `Null) in
    check_eq ~msg:"both platforms render master's arrow-narrow-right" (member "id" descriptor) (`String "arrow-narrow-right")))
    [App_test.ios_backend, true; App_test.kotlin_backend, false])

let embedding_in_text_preserves_the_original_block () = R.with_runtime (fun session runtime _ ->
  ignore (start session "Keep this /");
  ignore (command session "Node embed");
  ignore (choose session Q.beta);
  let db = Graph_runtime.db runtime in
  check_eq (value runtime Q.alpha "block/title") (Some (Ds.String "Keep this "));
  check_eq (value runtime Q.alpha "block/link") None;
  check ~msg:"a nonempty target gets a separate embedded sibling" (Seq.exists (fun (d : Ds.datom) ->
    Graph_read.ref_eids db d.e "block/link" <> []) (Ds.Db.datoms db Ds.Aevt ~a:"block/link" ())))

let html_images_and_underline_render_as_content () =
  let parsed source = Markup.parse [] [] source |> Markup.to_yojson |> J.to_string in
  List.iter (fun (source, expected) -> check ~msg:(source ^ " renders its content")
    (String_kit.includes ~sub:expected (parsed source))) [
    "@@html: <strong>Hello</strong>@@", "\"type\":\"html\"";
    "![Picture](https://example.com/a.png)", "\"type\":\"image\"";
    "Before <ins>underlined</ins> after", "\"style\":\"underline\"" ]

let numbered_lists_toggle_without_changing_source_text () = R.with_runtime (fun session runtime conn ->
  let child = "30000000-0000-4000-8000-000000000003" in
  rebase runtime conn (R.entity 102 child "Numbered child" @ [
    put child "block/page" (Ds.Ref_to (Q.ref_uuid Q.page));
    put child "block/parent" (Ds.Ref_to (Q.ref_uuid Q.alpha)); put child "block/order" (Ds.String "a0")]);
  List.iter (fun (label, uuid) ->
    ignore (run session label); save session;
    check ~msg:label (value runtime uuid "logseq.property/order-list-type" <> None);
    ignore (run session label); save session;
    check_eq ~msg:(label ^ " toggles off") (value runtime uuid "logseq.property/order-list-type") None)
    ["Number list", Q.alpha; "Number children", child])

let copied_urls_include_the_graph_identity () = R.with_runtime (fun session _ _ ->
  ignore (event session "longPressBlock" ["uuid", `String Q.alpha]);
  let response = event session "toolbar" ["action", `String "copyURL"] in
  let commands = items "outlinerCommands" response in
  check ~msg:"copied links identify the graph and block"
    (List.exists (fun command -> member "type" command = `String "setClipboardText"
      && member "text" command = `String ("logseq://graph/plain-1?block-id=" ^ Q.alpha)) commands))

let return_selects_completion_and_special_blocks_create_siblings () =
  R.with_runtime (fun session runtime _ ->
    ignore (start session "/h1");
    ignore (event session "returnPressed" []);
    check_eq ~msg:"Return selects the highlighted first command" (value runtime Q.alpha "logseq.property/heading") (Some (Ds.Int64 1L)));
  List.iter (fun label -> List.iter (fun (title, caret, before, after) ->
    R.with_runtime (fun session runtime _ ->
      ignore (run session label);
      let previous_ids = Graph_runtime.blocks_for_page runtime Q.page |> List.map (fun (b : Cache_model.block) -> b.uuid) in
      ignore (type_at session title caret);
      let response = event session "returnPressed" ["title", `String title; "caretUTF16Offset", `Int caret] in
      let next = text (member "uuid" (draft response)) in
      check ~msg:(label ^ " Enter focuses a new block") (next <> "" && next <> Q.alpha);
      check_eq ~msg:"Enter retains the expected content in the original block" (value runtime Q.alpha "block/title") (Some (Ds.String before));
      check_eq ~msg:"The new block receives the expected content" (value runtime next "block/title") (Some (Ds.String after));
      check_eq ~msg:"The new block starts as ordinary text" (value runtime next "logseq.property.node/display-type") None;
      check_eq ~msg:"Enter adds exactly one block"
        (List.length (Graph_runtime.blocks_for_page runtime Q.page)) (List.length previous_ids + 1)))
    ["", 0, "", ""; "x^2", 0, "x^2", ""; "x^2", 3, "x^2", "";
     "🙂A\nB", 3, "🙂A", "\nB"])
    ["Code block"; "Calculator"; "Math block"]

let special_commands_match_master_for_click_and_enter () =
  List.iter (fun (label, query, typ, language) ->
    List.iter (fun (prefix, suffix, existing_type) ->
      List.iter (fun via_enter -> R.with_runtime (fun session runtime conn ->
        Option.iter (fun typ -> rebase runtime conn [put Q.alpha "logseq.property.node/display-type" (Ds.Keyword typ)]) existing_type;
        let before = List.length (Graph_runtime.blocks_for_page runtime Q.page) in
        ignore (start session (prefix ^ query ^ suffix));
        ignore (type_at session (prefix ^ query ^ suffix) (Outliner_state.utf16_length (prefix ^ query)));
        let response = if via_enter then event session "returnPressed" [] else command session label in
        let uuid = text (member "uuid" (draft response)) in
        let remaining = prefix ^ suffix in
        let inserts = typ = "code" && (String.trim remaining <> "" || existing_type <> None) in
        check_eq ~msg:(label ^ " uses master conversion rules through both selection methods") (uuid <> Q.alpha) inserts;
        check_eq ~msg:"The slash command and query text are removed" (member "title" (draft response))
          (`String (if inserts then "" else remaining));
        check_eq (value runtime uuid "logseq.property.node/display-type") (Some (Ds.Keyword typ));
        check_eq (value runtime uuid "logseq.property.code/lang") (Option.map (fun lang -> Ds.String lang) language);
        check_eq ~msg:"Commands insert exactly one block only when master does"
          (List.length (Graph_runtime.blocks_for_page runtime Q.page)) (before + if inserts then 1 else 0);
        if inserts then check_eq ~msg:"Inserting code preserves the original prose"
          (value runtime Q.alpha "block/title") (Some (Ds.String (String.trim remaining))))) [false; true])
      ["", "", None; "Keep this ", "", None; "", " suffix", None;
       "🙂 前文 ", " 后文", None; "", "", Some "quote"])
    ["Code block", "/code", "code", None; "Calculator", "/calculator", "code", Some "calc";
     "Math block", "/math", "math", None]

let every_slash_command_removes_its_typed_query () =
  let entries = R.with_runtime (fun _ runtime _ -> Editor_command.catalog (Some (Graph_runtime.db runtime))) in
  List.iter (fun (entry : Editor_command.entry) ->
    List.iter (fun via_enter -> R.with_runtime (fun session runtime _ ->
      let prefix = "🙂 前文 " and suffix = " 后文" in
      let query = "/" ^ entry.label in
      let title = prefix ^ query ^ suffix in
      ignore (start session title);
      ignore (type_at session title (Outliner_state.utf16_length (prefix ^ query)));
      let response = if via_enter then event session "returnPressed" [] else command session entry.label in
      let active = text (member "title" (draft response)) in
      let original = match value runtime Q.alpha "block/title" with Some (Ds.String title) -> title | _ -> "" in
      check ~msg:(entry.label ^ " clears the slash and typed query")
        (not (String_kit.includes ~sub:query active) && not (String_kit.includes ~sub:query original));
      let content = match entry.action with Editor_command.Code _ -> original | _ -> active in
      check ~msg:(entry.label ^ " preserves surrounding text")
        (String.starts_with ~prefix content && String.ends_with ~suffix content))) [false; true]) entries

let code_in_text_creates_a_separate_block () = R.with_runtime (fun session runtime _ ->
  ignore (start session "Keep this /");
  ignore (command session "Code block");
  check_eq ~msg:"a code command preserves prose and trims its edges on leaving editing" (value runtime Q.alpha "block/title") (Some (Ds.String "Keep this"));
  check_eq (value runtime Q.alpha "logseq.property.node/display-type") None;
  check ~msg:"the code editor gets its own sibling" (List.exists (fun (b : Cache_model.block) ->
    b.uuid <> Q.alpha && b.display_type = Some "code") (Graph_runtime.blocks_for_page runtime Q.page)))

let shared_panel_for_commands_pages_and_tags () =
  List.iter (fun backend -> R.with_runtime (fun session _ _ ->
    List.iter (fun title -> ignore (start session title);
      Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
        let host = Lui_app.runtime app in
        let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
        check ~msg:title (find "toolbar.outliner.autocomplete" <> -1);
        check ~msg:"every completion offers explicit dismissal" (find "button.outliner.autocomplete.dismiss" <> -1);
        App_test.dispatch app (Lui_protocol.Press (find "button.outliner.autocomplete.dismiss"));
        App_test.flush app;
        check ~msg:"dismissal preserves editing" ((App.model app).Model.outliner_editing <> None)))
      ["/"; "[[Al"; "#Pro"])) [App_test.ios_backend; App_test.kotlin_backend]

let page_placeholders_are_lazy_and_editable () =
  List.iter (fun backend ->
    List.iter (fun (title, children, expected) ->
      let block = `Assoc ["uuid", `String "last"; "title", `String title;
        "pageId", `String Q.page; "parentId", `String Q.page] in
      let response = J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
        "selectedGraphId", `String "graph";
        "selectedPage", `Assoc ["uuid", `String Q.page; "title", `String "A page"];
        "outlinerRows", `List (if title = "<empty-page>" then [] else
          [`Assoc ["block", block; "depth", `Int 0; "hasChildren", `Bool children]])]]) in
      Q.with_ui backend response (fun app ->
        let host = Lui_app.runtime app in
        let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
        let placeholder = find ("button.outliner.placeholder." ^ Q.page) in
        check_eq ~msg:("placeholder for " ^ title) (placeholder <> -1) expected;
        check_eq ~msg:"reading never creates a block" (App.model app).pending_effects [];
        if expected then begin
          App_test.dispatch app (Lui_protocol.Press placeholder); App_test.flush app;
          check ~msg:"one tap starts block creation and editing"
            (List.exists (function Model.AddRootBlockEffect (_, uuid) -> uuid = Q.page | _ -> false)
              (App.model app).pending_effects)
        end)) ["<empty-page>", false, true; "Last text", false, true;
          "", false, false; "", true, true]
  ) [App_test.ios_backend; App_test.kotlin_backend];
  R.with_runtime (fun session runtime _ ->
    let before = Graph_runtime.blocks_for_page runtime Q.page in
    let response = event session "addRootBlock" ["uuid", `String Q.page] in
    let uuid = text (member "uuid" (draft response)) in
    check ~msg:"the newly inserted block is immediately focused" (uuid <> "");
    let after = Graph_runtime.blocks_for_page runtime Q.page in
    check_eq (List.length after) (List.length before + 1);
    check_eq (List.find (fun (b : Cache_model.block) -> b.uuid = uuid) after).title "")

let empty_journal_pages_keep_their_heading () =
  List.iter (fun backend ->
    let response = J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
      "selectedGraphId", `String "graph"; "outlinerRows", `List [];
      "emptyJournals", `List [`Assoc ["uuid", `String Q.page; "title", `String "Today";
        "journalDay", `Int 20261022]]]]) in
    Q.with_ui backend response (fun app ->
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      check ~msg:"an existing day remains visible even with no blocks"
        (find ("button.journal." ^ Q.page) <> -1);
      let placeholder = find ("button.outliner.placeholder." ^ Q.page) in
      check ~msg:"an empty day offers the same editable placeholder" (placeholder <> -1);
      check_eq ~msg:"rendering an empty journal has no writes" (App.model app).pending_effects [];
      App_test.dispatch app (Lui_protocol.Press placeholder); App_test.flush app;
      check ~msg:"the empty day is the insertion destination"
        (List.exists (function Model.AddRootBlockEffect (_, uuid) -> uuid = Q.page | _ -> false)
          (App.model app).pending_effects))) [App_test.ios_backend; App_test.kotlin_backend]

let zoom_placeholder_creates_a_child_in_the_same_page () = R.with_runtime (fun session runtime _ ->
  let response = event session "addRootBlock" ["uuid", `String Q.alpha] in
  let uuid = text (member "uuid" (draft response)) in
  check ~msg:"zoom insertion focuses the new child" (uuid <> "");
  let child = List.find (fun (block : Cache_model.block) -> block.uuid = uuid)
    (Graph_runtime.blocks_for_page runtime Q.page) in
  check_eq child.parent_id (Some Q.alpha);
  check_eq child.page_id Q.page)

let placeholders_hide_while_editing_and_keep_empty_journal_headings () =
  List.iter (fun backend ->
    let response = J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
      "selectedGraphId", `String "graph";
      "outlinerState", `Assoc ["editing", `Assoc ["uuid", `String "editing"; "title", `String "Hello"; "caretUTF16Offset", `Int 5]];
      "outlinerRows", `List [`Assoc ["depth", `Int 0; "block", `Assoc [
        "uuid", `String "editing"; "title", `String "Hello"; "pageId", `String Q.page;
        "journalTitle", `String "Today"; "journalDay", `Int 20261023]]];
      "emptyJournals", `List [`Assoc ["uuid", `String "empty-day"; "title", `String "Yesterday"; "journalDay", `Int 20261022]]]]) in
    Q.with_ui backend response (fun app ->
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      check ~msg:"the fixture is actually editing" ((App.model app).outliner_editing <> None);
      check_eq ~msg:"editing hides the current page placeholder" (find ("button.outliner.placeholder." ^ Q.page)) (-1);
      check_eq ~msg:"editing hides placeholders for other empty days" (find "button.outliner.placeholder.empty-day") (-1);
      check ~msg:"empty journal headings remain visible while editing" (find "button.journal.empty-day" <> -1)))
    [App_test.ios_backend; App_test.kotlin_backend]

let repeated_placeholder_taps_create_one_editor () =
  let model = Model.update (Model.initial ()) (Model.AddRootBlock "page") in
  let repeated = Model.update model (Model.AddRootBlock "page") in
  check_eq ~msg:"rapid taps cannot insert multiple empty blocks" repeated.pending_effects model.pending_effects

let empty_journals_are_projected_without_writes () = R.with_runtime (fun _ runtime conn ->
  let uuid = "50000000-0000-4000-8000-000000000001" in
  let day = Cache_model.journal_day_for_ms (Session_types.now_ms ()) in
  rebase runtime conn (R.entity 200 uuid "Today" @ [put uuid "block/name" (Ds.String "today");
    put uuid "block/journal-day" (Ds.Int64 (Int64.of_int day))]);
  let pending = Graph_runtime.pending_operations runtime in
  let session = Rpc_session.create_session {Rpc_session.default_options with
    graph_db = Some (fun () -> Some (Graph_runtime.db runtime));
    graph_blocks = Some (fun () -> Some (Graph_runtime.blocks runtime));
    empty_journals = Some (fun () -> Graph_runtime.empty_journals runtime)} in
  let response = snapshot session in
  check ~msg:"the current empty journal is projected independently of its blocks"
    (List.exists (fun page -> member "uuid" page = `String uuid) (items "emptyJournals" response));
  check_eq (Graph_runtime.pending_operations runtime) pending)

let display_titles_resolve_references_without_changing_source () = R.with_runtime (fun session runtime conn ->
  let nested = "60000000-0000-4000-8000-000000000001" in
  let cycle = "60000000-0000-4000-8000-000000000002" in
  let favorite = "60000000-0000-4000-8000-000000000004" in
  let source = "Read [[" ^ nested ^ "]]" in
  rebase runtime conn (R.entity 201 nested ("[[" ^ Q.beta ^ "]] notes") @
    R.entity 202 cycle ("[[" ^ cycle ^ "]]") @
    R.entity 204 favorite "" @ [
    put favorite "block/page" (Ds.Ref (Option.get (Graph_read.favorite_page_eid (Graph_runtime.db runtime))));
    put favorite "block/link" (Ds.Ref_to (Q.ref_uuid Q.page));
    put Q.page "block/title" (Ds.String source);
    put Q.alpha "block/title" (Ds.String source);
    put Q.alpha "block/refs" (Ds.Ref_to (Q.ref_uuid nested))]);
  let db = Graph_runtime.db runtime in
  let page = fst (Option.get (Graph_read.node_destination (fun x -> Ok x) db Q.page)) in
  check_eq ~msg:"scene titles resolve nested UUID references" page.title "Read Beta result notes";
  let sidebar = Graph_read.sidebar_pages (fun x -> Ok x) db in
  check_eq ~msg:"favorites use the same display title" (List.hd sidebar.favorites).title page.title;
  let table = R.find_view R.table_view (R.read session) in
  let row = List.find (fun row -> member "uuid" (member "block" row) = `String Q.alpha) (items "rows" table) in
  let name = List.find (fun p -> member "attr" p = `String "block/title") (items "properties" row) in
  check_eq ~msg:"table names resolve UUID references" (member "text" name) (`String page.title);
  check_eq ~msg:"gallery names use a resolved display title"
    (member "displayTitle" (member "block" row)) (`String page.title);
  check_eq ~msg:"editing and syncing retain the original reference syntax"
    (member "title" (member "block" row)) (`String source);
  let cycle_id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid cycle)) in
  let cycle_summary = Option.get (Graph_read.entity_summary (fun x -> Ok x) db cycle_id) in
  check ~msg:"cyclic title references remain bounded" (String.length cycle_summary.title < 100))

let saved_views_use_an_intrinsic_native_select () =
  List.iter (fun backend -> R.with_runtime (fun session _ _ ->
    let views = R.read ~owner:Q.project ~feature:"class-objects" session in
    let response = J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
      "selectedGraphId", `String "graph";
      "selectedPage", `Assoc ["uuid", `String Q.project; "title", `String "Project"];
      "selectedPageIsTag", `Bool true; "resultViews", views; "outlinerRows", `List []]]) in
    Q.with_ui backend response (fun app ->
      let host = Lui_app.runtime app in
      let root = Lui_app.root_node app in
      let find id = App_test.descendant_with_identifier host root id in
      check_eq ~msg:"view selection no longer mounts a tab bar" (find ("view.tabs." ^ Q.project)) (-1);
      let select = find ("view.select." ^ Q.project) in
      check ~msg:"view names use one native selection menu" (select <> -1);
      check ~msg:"the selection trigger keeps its intrinsic width"
        (App_test.property_float host select Lui_protocol.GrowValue <= 0.0))))
    [App_test.ios_backend; App_test.kotlin_backend]

let command_groups_follow_master_order () =
  List.iter (fun backend -> R.with_runtime (fun session _ _ ->
    let response = start session "/" in
    let commands = choices response in
    let groups = List.filter_map (fun candidate -> match member "group" candidate with
      | `String title -> Some title | _ -> None) commands in
    check_eq ~msg:"master group order survives command exclusions" groups
      ["BASIC"; "FORMAT"; "Heading"; "TASK STATUS"; "TASK DATE"; "PRIORITY"; "TIME & DATE"; "LIST TYPE"; "ADVANCED"];
    let labels = List.map (fun candidate -> text (member "label" candidate)) commands in
    let before a b =
      check ~msg:(a ^ " precedes " ^ b) (Option.get (List.find_index ((=) a) labels) < Option.get (List.find_index ((=) b) labels)) in
    before "Link" "Image link"; before "Image link" "Underline"; before "Heading 6" "Clear heading";
    before "Low" "No priority"; before "Calculator" "Template"; before "Embed Twitter tweet" "Cloze";
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      List.iter (fun group -> check ~msg:("native group header " ^ group)
        (App_test.descendant_with_identifier host (Lui_app.root_node app) ("outliner.autocomplete.group." ^ group) <> -1)) groups);
    let response = start session "/head" in
    check ~msg:"master search uses relevance without group headers"
      (List.for_all (fun candidate -> member "group" candidate = `Null) (choices response))))
    [App_test.ios_backend; App_test.kotlin_backend]

let enter_on_a_parent_matches_master_placement () =
  List.iter (fun (collapsed, caret, expected_parent, expected_title) -> R.with_runtime (fun session runtime conn ->
    let child = "70000000-0000-4000-8000-000000000001" in
    rebase runtime conn (R.entity 220 child "Existing child" @ [
      put child "block/page" (Ds.Ref_to (Q.ref_uuid Q.page));
      put child "block/parent" (Ds.Ref_to (Q.ref_uuid Q.alpha)); put child "block/order" (Ds.String "a0")]);
    if collapsed then ignore (event session "toggleCollapsed" ["uuid", `String Q.alpha]);
    ignore (event session "tapBlock" ["uuid", `String Q.alpha]);
    ignore (type_at session "Hello" caret);
    let response = event session "returnPressed" [] in
    let uuid = text (member "uuid" (draft response)) in
    let blocks = Graph_runtime.blocks_for_page runtime Q.page in
    let created = List.find (fun (b : Cache_model.block) -> b.uuid = uuid) blocks in
    check_eq ~msg:"Enter chooses the same parent as master" created.parent_id (Some expected_parent);
    check_eq created.title expected_title;
    let existing = List.find (fun (b : Cache_model.block) -> b.uuid = child) blocks in
    check_eq ~msg:"existing children keep their identity and parent" existing.parent_id (Some Q.alpha);
    if expected_parent = Q.alpha then check ~msg:"the new child comes before existing children" (created.order < existing.order);
    if caret = 0 then begin
      let parent = List.find (fun (b : Cache_model.block) -> b.uuid = Q.alpha) blocks in
      check_eq ~msg:"Enter at the start preserves the original block" parent.title "Hello";
      check ~msg:"Enter at the start inserts above the parent" (created.order < parent.order)
    end;
    List.iter (fun operation -> match Graph_runtime.prepare_sync runtime operation with
      | Ok _ -> () | Error message -> fail message) (Graph_runtime.pending_operations runtime)))
    [false, 5, Q.alpha, ""; false, 2, Q.alpha, "llo"; true, 5, Q.page, ""; false, 0, Q.page, ""]

let backspace_at_start_keeps_the_caret_at_the_merge_boundary () =
  List.iter (fun (previous_title, nested, collapsed) -> R.with_runtime (fun session runtime conn ->
    let descendant = "70000000-0000-4000-8000-000000000002" in
    rebase runtime conn ([put Q.alpha "block/title" (Ds.String previous_title);
      put Q.beta "block/title" (Ds.String "Hello")]
      @ (if nested then [put Q.beta "block/parent" (Ds.Ref_to (Q.ref_uuid Q.alpha))] else [])
      @ R.entity 221 descendant "Preserved child" @ [
        put descendant "block/page" (Ds.Ref_to (Q.ref_uuid Q.page));
        put descendant "block/parent" (Ds.Ref_to (Q.ref_uuid Q.beta));
        put descendant "block/order" (Ds.String "a0")]);
    if collapsed then ignore (event session "toggleCollapsed" ["uuid", `String Q.beta]);
    ignore (event session "tapBlock" ["uuid", `String Q.beta]);
    ignore (type_at session "Hello" 0);
    let response = event session "backspacePressed" ["title", `String "Hello"; "selectionLength", `Int 0] in
    check_eq ~msg:"Backspace edits the surviving previous block" (member "uuid" (draft response)) (`String Q.alpha);
    check_eq ~msg:"merged text is preserved" (member "title" (draft response)) (`String (previous_title ^ "Hello"));
    check_eq ~msg:"caret stays between the previous title and Hello, in native UTF-16 units"
      (member "caretUTF16Offset" (draft response)) (`Int (Outliner_state.utf16_length previous_title));
    let blocks = Graph_runtime.blocks_for_page runtime Q.page in
    check ~msg:"only the merged source is removed" (not (List.exists (fun (b : Cache_model.block) -> b.uuid = Q.beta) blocks));
    check_eq ~msg:"source children survive under the merged block"
      (List.find (fun (b : Cache_model.block) -> b.uuid = descendant) blocks).parent_id (Some Q.alpha)))
    ["World", false, false; "中文🙂", false, true; "Parent", true, false]

let unrelated_edit_does_not_create_issue_number_tags () = R.with_runtime (fun session runtime conn ->
  let source = {|Design question (reporter asks A vs B), not auto-fixed: A = text export writes the deprecated macro as text ("- Groceries {{embed [[Shopping]]}}") so export→paste round-trips (3 export-test assertions change); B = keep expanding as now. Reporter offers the PR for A. Related umbrella db-test#1442 (reporter withdrew symptom patches incl. #13730/#[[13732)]]. Needs Tienson decision before a code PR.|} in
  rebase runtime conn [put Q.alpha "block/title" (Ds.String source)];
  let session = Rpc_session.create_session { (Rpc_session.host session) with
    graph_normalize_titles = Some (Graph_runtime.normalize_titles runtime) } in
  ignore (Rpc_test.configure_plain_session session);
  Q.open_results session;
  let before = Graph_runtime.db runtime in
  let tags () = List.of_seq (Ds.Db.datoms (Graph_runtime.db runtime) Ds.Aevt ~a:"block/tags" ()) in
  let original_tags = tags () in
  ignore (event session "tapBlock" ["uuid", `String Q.alpha]);
  let updated = source ^ " 1" in
  ignore (type_at session updated (Outliner_state.utf16_length updated));
  save session;
  check_eq ~msg:"appending 1 cannot rewrite existing issue references"
    (value runtime Q.alpha "block/title") (Some (Ds.String updated));
  check_eq ~msg:"the edit cannot create or assign accidental tag entities" (tags ()) original_tags;
  List.iter (fun name ->
    check_eq ~msg:("no accidental tag: " ^ name)
      (Ds.entid (Graph_runtime.db runtime) "block/name" (Ds.String name))
      (Ds.entid before "block/name" (Ds.String name))) ["1442"; "13730/"; "13732)"])

let task_dates_are_visible_and_editable_in_the_outline () =
  List.iter (fun backend -> R.with_runtime (fun session runtime _ ->
    List.iter (fun label -> ignore (run session label); ignore (submit session "1792719000000"); save session)
      ["Scheduled"; "Deadline"];
    let response = snapshot session in
    let block = List.find (fun block -> member "uuid" block = `String Q.alpha) (items "blocks" response) in
    let dates = items "properties" (member "taskDates" block) in
    check_eq ~msg:"ordinary outline rows include populated task dates" (List.length dates) 2;
    List.iter (fun date -> let value = text (member "text" date) in
      check ~msg:"dates are local labels rather than numeric timestamps" (value <> "" && not (String_kit.includes ~sub:"1792719000000" value))) dates;
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      List.iter (fun attr ->
        let value = find ("property.value." ^ Q.alpha ^ "." ^ attr) in
        check ~msg:"task date is visible before zooming in" (value <> -1);
        let label = find ("property.label." ^ Q.alpha ^ "." ^ attr) in
        check_eq ~msg:"task date keys use compact icons" (App_test.property_string host label Lui_protocol.IconName)
          ("app:" ^ if attr = "logseq.property/scheduled" then "calendar" else "deadline");
        check ~msg:"date text uses a readable month rather than a numeric date"
          (not (String_kit.includes ~sub:"2026-10-" (App_test.property_string host value Lui_protocol.TextValue)));
        App_test.dispatch app (Lui_protocol.Press value); App_test.flush app;
        check ~msg:"task date opens the existing native date editor"
          (find ("view.edit.sheet.property." ^ Q.alpha ^ "." ^ attr) <> -1);
        let cancel = find ("view.edit.cancel.property." ^ Q.alpha ^ "." ^ attr) in
        check ~msg:"date editor has Cancel" (cancel <> -1);
        App_test.dispatch app (Lui_protocol.Press cancel); App_test.flush app)
        ["logseq.property/scheduled"; "logseq.property/deadline"]);
    ignore (Q.dispatch session "openNode" (Yojson.Basic.to_string (`Assoc ["uuid", `String Q.alpha])));
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      App_test.send app (Model.RequestAppNode Q.alpha);
      let snapshot = match Response_snapshot.decode_response (Rpc_session.snapshot_visible session) with
        | Ok value -> value | Error message -> fail message in
      App_test.send app (Model.ApplyCoreSnapshot snapshot); App_test.flush app;
      let host = Lui_app.runtime app in
      let screen = App_test.descendant_with_identifier host (Lui_app.root_node app) "screen.node" in
      let find id = App_test.descendant_with_identifier host screen id in
      let expand = find ("properties.expand." ^ Q.alpha) in
      if expand <> -1 then (App_test.dispatch app (Lui_protocol.Press expand); App_test.flush app);
      List.iter (fun (attr, title) ->
        let label = find ("property.label." ^ Q.alpha ^ "." ^ attr) in
        check ~msg:"zoomed task dates use ordinary property labels" (label <> -1);
        check_eq ~msg:"zoomed task date key is text rather than an icon" (App_test.node host label) (Some Lui_protocol.Text);
        check_eq (App_test.property_string host label Lui_protocol.TextValue) title)
        ["logseq.property/scheduled", "Scheduled"; "logseq.property/deadline", "Deadline"]);
    check ~msg:"displaying task dates does not add extra semantic writes" (List.length (Graph_runtime.pending_operations runtime) < 10)))
    [App_test.ios_backend; App_test.kotlin_backend]

let cases = [
  case "code commands immediately update the active editor presentation" code_commands_update_the_active_editor_style;
  case "calculator last remembers successful expressions across blank and comment lines" calculator_last_tracks_successful_lines;
  case "embedded outliner bullets use the master arrow" embedded_outliner_bullets_match_master;
  case "editing hides placeholders but keeps journal headings" placeholders_hide_while_editing_and_keep_empty_journal_headings;
  case "Backspace keeps the caret at the merge boundary" backspace_at_start_keeps_the_caret_at_the_merge_boundary;
  case "unrelated edits do not create issue number tags" unrelated_edit_does_not_create_issue_number_tags;
  case "Enter on a parent matches master placement" enter_on_a_parent_matches_master_placement;
  case "task dates are visible and editable in the outline" task_dates_are_visible_and_editable_in_the_outline;
  case "command groups follow master order" command_groups_follow_master_order;
  case "display titles resolve UUID references" display_titles_resolve_references_without_changing_source;
  case "views use an intrinsic native select" saved_views_use_an_intrinsic_native_select;
  case "zoom placeholder creates a child in its page" zoom_placeholder_creates_a_child_in_the_same_page;
  case "rapid placeholder taps create one editor" repeated_placeholder_taps_create_one_editor;
  case "empty journals project without writes" empty_journals_are_projected_without_writes;
  case "page placeholders are lazy and editable" page_placeholders_are_lazy_and_editable;
  case "empty journal headings stay visible" empty_journal_pages_keep_their_heading;
  case "Return selects completion and special blocks create siblings" return_selects_completion_and_special_blocks_create_siblings;
  case "special command selection matches master" special_commands_match_master_for_click_and_enter;
  case "every slash command removes its typed query" every_slash_command_removes_its_typed_query;
  case "code in prose creates a separate block" code_in_text_creates_a_separate_block;
  case "HTML images and underline render as content" html_images_and_underline_render_as_content;
  case "command output has native presentation" command_output_has_native_presentation;
  case "embedding in text preserves the original block" embedding_in_text_preserves_the_original_block;
  case "copied URLs include graph identity" copied_urls_include_the_graph_identity;
  case "pasted markers stay literal" pasted_markers_do_not_open_completion;
  case "catalog search and literal boundaries" catalog_search_and_literal_boundaries;
  case "inline commands preserve caret and suffix" inline_commands_preserve_caret_and_suffix;
  case "graph choices headings and block types" graph_choices_headings_and_block_types;
  case "links and dates use shared prompts" links_and_dates_use_shared_prompts;
  case "embeds delete only the wrapper" embeds_delete_only_the_wrapper;
  case "linked blocks edit source contents" linked_blocks_edit_source_contents;
  case "linked pages edit the unrendered source" linked_pages_edit_the_unrendered_source;
  case "linked pages validate saved names" linked_pages_validate_saved_names;
  case "linked pages keep name protections" linked_pages_keep_name_protections;
  case "linked editing tracks the captured source" linked_editing_tracks_the_captured_source;
  case "cyclic links do not open an empty editor" cyclic_links_do_not_open_an_empty_editor;
  case "switching linked rows preserves unsaved content" switching_linked_rows_preserves_unsaved_content;
  case "linked content changes refresh visible wrappers" linked_content_changes_refresh_visible_wrappers;
  case "node completion renders resolved references" node_completion_renders_resolved_references;
  case "linked blocks preserve source formatting" linked_blocks_preserve_source_formatting;
  case "linked content keeps outline boundaries" linked_content_keeps_outline_boundaries;
  case "templates clone without mutating the source" templates_clone_without_mutating_the_source;
  case "numbered lists toggle" numbered_lists_toggle_without_changing_source_text;
  case "shared panel for commands pages and tags" shared_panel_for_commands_pages_and_tags;
]
