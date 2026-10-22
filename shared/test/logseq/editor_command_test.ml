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
     "Normal text"; "Clear heading"; "Heading 1"; "Heading 6"; "Deadline"; "Scheduled";
     "Tomorrow"; "Yesterday"; "Today"; "Current time"; "Date picker"; "Number list";
     "Number children"; "Calculator"; "Template"; "Embed HTML"; "Embed Video URL";
     "Embed YouTube timestamp"; "Embed Twitter tweet"; "Cloze"; "No priority"];
  List.iter (fun label -> check ~msg:("excluded command: " ^ label) (not (List.mem label labels)))
    ["Query"; "Advanced Query"; "Query function"; "Add property"; "Add comment";
     "Upload an asset"; "Node reference"];
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
  ignore (run session "Normal text"); save session;
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

let return_selects_completion_and_code_keeps_line_breaks () = R.with_runtime (fun session runtime _ ->
  ignore (start session "/h1");
  ignore (event session "returnPressed" []);
  check_eq ~msg:"Return selects the highlighted first command" (value runtime Q.alpha "logseq.property/heading") (Some (Ds.Int64 1L));
  ignore (run session "Code block");
  ignore (event session "returnPressed" ["title", `String "let x = 1"; "caretUTF16Offset", `Int 9]);
  let response = snapshot session in
  check_eq ~msg:"a code block keeps Return inside the same block"
    (member "uuid" (draft response)) (`String Q.alpha);
  check_eq (member "title" (draft response)) (`String "let x = 1\n"))

let code_in_text_creates_a_separate_block () = R.with_runtime (fun session runtime _ ->
  ignore (start session "Keep this /");
  ignore (command session "Code block");
  check_eq ~msg:"a code command preserves nonempty prose" (value runtime Q.alpha "block/title") (Some (Ds.String "Keep this "));
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

let cases = [
  case "display titles resolve UUID references" display_titles_resolve_references_without_changing_source;
  case "views use an intrinsic native select" saved_views_use_an_intrinsic_native_select;
  case "zoom placeholder creates a child in its page" zoom_placeholder_creates_a_child_in_the_same_page;
  case "rapid placeholder taps create one editor" repeated_placeholder_taps_create_one_editor;
  case "empty journals project without writes" empty_journals_are_projected_without_writes;
  case "page placeholders are lazy and editable" page_placeholders_are_lazy_and_editable;
  case "empty journal headings stay visible" empty_journal_pages_keep_their_heading;
  case "Return selects completion and code keeps line breaks" return_selects_completion_and_code_keeps_line_breaks;
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
  case "templates clone without mutating the source" templates_clone_without_mutating_the_source;
  case "numbered lists toggle" numbered_lists_toggle_without_changing_source_text;
  case "shared panel for commands pages and tags" shared_panel_for_commands_pages_and_tags;
]
