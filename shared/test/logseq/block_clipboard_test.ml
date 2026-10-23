open Test_util
module D = Datascript
module J = Yojson.Basic
module R = Result_view_test
module Q = Query_block_test
let member = Q.member
let text = R.text
let child = "81000000-0000-4000-8000-000000000001"
let grandchild = "81000000-0000-4000-8000-000000000002"
let target = R.gamma
let event session fields = Rpc_test.dispatch_json session "outlinerEvent" (J.to_string (`Assoc fields))
let success result = check_eq ~msg:(J.to_string result) (member "ok" result) (`Bool true)
let block_event session typ uuid = success (event session ["type", `String typ; "uuid", `String uuid])
let value runtime uuid attr = Editor_command_test.value runtime uuid attr
let rec semantic db = function
  | D.Ref eid -> (match Graph_read.uuid_for_eid db eid with Some uuid -> Pending_ops.Ref_uuid uuid
      | None -> (match Graph_read.value db eid "db/ident" with Some (D.Keyword ident) -> Pending_ops.Ref_ident ident | _ -> fail "Missing ref"))
  | D.Set xs -> Pending_ops.Set_value (List.map (semantic db) xs)
  | v -> (match Pending_ops.semantic_value_from_datascript v with Ok v -> v | Error message -> fail message)
let title runtime uuid = match value runtime uuid "block/title" with Some (D.String s) -> s | _ -> ""
let insert runtime uuid parent order content = check_ok (Graph_runtime.stage runtime
  {Pending_ops.operation_id = Graph_runtime.fresh_uuid (); base_t = 42; state = Pending_ops.Queued;
   intent = Pending_ops.Insert_block {uuid; page_uuid = Q.page; parent_uuid = parent; order; title = content; created_at = 1234}})
let set runtime uuid attr v = check_ok (Graph_runtime.stage runtime
  {Pending_ops.operation_id = Graph_runtime.fresh_uuid (); base_t = 42; state = Pending_ops.Queued;
   intent = Pending_ops.Set_property {uuid; attr; expected = Option.map (semantic (Graph_runtime.db runtime)) (value runtime uuid attr); value = Some v}})
let rename runtime uuid content = check_ok (Graph_runtime.stage runtime
  {Pending_ops.operation_id = Graph_runtime.fresh_uuid (); base_t = 42; state = Pending_ops.Queued;
   intent = Pending_ops.Save_title {uuid; expected_title = title runtime uuid; title = content}})
let children runtime parent = Graph_runtime.blocks_for_page runtime Q.page
  |> List.filter (fun (b : Cache_model.block) -> b.parent_id = Some parent)
  |> List.sort (fun (a : Cache_model.block) b -> compare a.order b.order)
let ids blocks = List.map (fun (b : Cache_model.block) -> b.uuid) blocks
let subtree runtime uuid =
  let rec collect uuid = uuid :: List.concat_map (fun (b : Cache_model.block) -> collect b.uuid) (children runtime uuid) in
  collect uuid
let copy session selected =
  (match selected with [] -> assert false | first :: rest ->
    block_event session "longPressBlock" first;
    List.iter (block_event session "tapBlock") rest);
  let result = event session ["type", `String "toolbar"; "action", `String "copy"] in
  success result;
  match List.find_opt (fun item -> member "type" item = `String "setClipboardBlocks")
    (Q.items "outlinerCommands" (member "result" result)) with
  | Some command -> J.from_string (text (member "text" command))
  | None -> fail "Copy must export native rich blocks and Markdown, not flatten selected titles"
let paste ?(rich = "") ?(start = 0) ?(length = 0) session uuid before plain =
  block_event session "tapBlock" uuid;
  event session ["type", `String "pasteContent"; "uuid", `String uuid;
    "beforeTitle", `String before; "selectionStart", `Int start; "selectionLength", `Int length;
    "plainText", `String plain; "blocksEDN", `String rich]
let paste_copy session runtime copied = paste ~rich:(text (member "blocksEDN" copied))
  session target (title runtime target) (text (member "plainText" copied))

let copies_nested_snapshots_without_moving_sources () = R.with_runtime (fun session runtime conn ->
  insert runtime child Q.alpha "a0" "Nested\nsecond line";
  insert runtime grandchild child "a0" "Deep child";
  set runtime child "logseq.property/collapsed?" (Pending_ops.Bool_value true);
  let original = subtree runtime Q.alpha in
  let copied = copy session [Q.alpha; child; Q.beta] in
  let markdown = text (member "plainText" copied) in
  check ~msg:"Markdown export preserves inline formatting" (String_kit.index_of ~sub:"- Alpha **result**" ~start:0 markdown <> None);
  check ~msg:"plain text export retains nested Markdown structure" (String_kit.index_of ~sub:"\t- Nested\n\t  second line" ~start:0 markdown <> None);
  check ~msg:"plain text export includes collapsed descendants" (String_kit.index_of ~sub:"Deep child" ~start:0 markdown <> None);
  rename runtime child "Changed after Copy";
  rename runtime target "";
  let result = paste_copy session runtime copied in success result;
  check_eq ~msg:"the first pasted root replaces the empty target identity" (title runtime target) (title runtime Q.alpha);
  let pasted_children = children runtime target in
  check_eq (List.length pasted_children) 1;
  let pasted_child = List.hd pasted_children in
  check_eq ~msg:"clipboard is a snapshot, not a live lookup" pasted_child.title "Nested\nsecond line";
  check ~msg:"copy creates new child identities" (not (List.mem pasted_child.uuid original));
  check_eq (List.map (fun (b : Cache_model.block) -> b.title) (children runtime pasted_child.uuid)) ["Deep child"];
  check_eq ~msg:"the original tree is never reparented" (subtree runtime Q.alpha) original;
  check_eq (title runtime child) "Changed after Copy";
  let copied_roots = children runtime Q.page |> List.filter (fun (b : Cache_model.block) -> b.uuid = target || b.title = title runtime Q.beta) in
  check_eq ~msg:"selected descendants are not duplicated as roots" (List.length copied_roots) 3;
  let restored = Graph_runtime.create runtime.path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
  check_eq ~msg:"nested paste survives pending-log restart" (subtree restored target) (subtree runtime target);
  Composer_tag_test.sync_all runtime conn)

let preserves_typed_properties_and_references () = R.with_runtime (fun session runtime _ ->
  insert runtime child Q.alpha "a0" "Value child";
  let db = Graph_runtime.db runtime in
  (* An existing ref property pointing inside the copied tree must follow the copy. *)
  set runtime Q.alpha R.summary (Pending_ops.Ref_uuid child);
  set runtime Q.alpha "logseq.property/status" (Pending_ops.Ref_ident "logseq.property/status.todo");
  rename runtime child ("Ref [[" ^ Q.alpha ^ "]]" );
  let copied = copy session [Q.alpha] in
  rename runtime target "";
  success (paste_copy session runtime copied);
  let copied_child = List.hd (children runtime target) in
  check_eq ~msg:"property refs within the tree are remapped" (value runtime target R.summary)
    (Some (D.Ref (Option.get (D.entid (Graph_runtime.db runtime) "block/uuid" (D.Uuid copied_child.uuid)))));
  List.iter (fun attr ->
    check_eq ~msg:("typed value retained: " ^ attr)
      (Option.map (semantic db) (value runtime Q.alpha attr))
      (Option.map (semantic (Graph_runtime.db runtime)) (value runtime target attr)))
    [R.score; R.ready; "block/tags"; "logseq.property/status"];
  check_eq ~msg:"normal copied inline references continue to refer to their sources, like master"
    copied_child.title ("Ref [[" ^ Q.alpha ^ "]]"))

let pasted_roots_keep_selection_order () = R.with_runtime (fun session runtime _ ->
  let copied = copy session [Q.beta; Q.alpha] in
  success (paste_copy session runtime copied);
  let siblings = children runtime Q.page in
  let rec after = function [] -> [] | (b : Cache_model.block) :: rest -> if b.uuid = target then rest else after rest in
  let added = after siblings in
  check_eq ~msg:"copy order follows the outliner rather than tap order" (List.map (fun (b : Cache_model.block) -> b.title) added)
    [title runtime Q.alpha; title runtime Q.beta];
  check_eq ~msg:"a nonempty paste target is preserved" (title runtime target) "Gamma result";
  let editing = Outliner_state.editing_uuid (Session_types.state session).outliner_state in
  check_eq ~msg:"the last inserted block receives editing focus" editing (Some (List.hd (List.rev added)).uuid))

let pastes_into_parent_before_existing_children () = R.with_runtime (fun session runtime _ ->
  insert runtime child target "a0" "Existing child";
  let copied = copy session [Q.alpha; Q.beta] in
  success (paste_copy session runtime copied);
  let result = children runtime target in
  check_eq ~msg:"a target with children receives pasted blocks as first children"
    (List.map (fun (b : Cache_model.block) -> b.title) result)
    [title runtime Q.alpha; title runtime Q.beta; "Existing child"];
  check_eq (List.hd (List.rev result)).uuid child)

let plain_text_preserves_inline_and_paragraph_semantics () =
  List.iter (fun (plain, expected, start, length, caret) -> R.with_runtime (fun session runtime _ ->
    rename runtime target "A😀Z";
    let before = List.length (Graph_runtime.blocks_for_page runtime Q.page) in
    success (paste ~start ~length session target "A😀Z" plain);
    check_eq (title runtime target) expected;
    check_eq ~msg:"ordinary single-newline text is not split into blocks" (List.length (Graph_runtime.blocks_for_page runtime Q.page)) before;
    let state = (Session_types.state session).outliner_state in
    check_eq (Option.map (fun (d : Outliner_state.editor_draft) -> d.caret) state.editing) (Some caret);
    check_eq ~msg:"paste markers do not open completion" state.autocomplete None))
    ["hello/", "Ahello/Z", 1, 2, 7; "one\r\ntwo", "Aone\ntwoZ", 1, 2, 8;
     "[[", "A😀[[Z", 3, 0, 5; "#", "#A😀Z", 0, 0, 1];
  R.with_runtime (fun session runtime _ ->
    rename runtime target "";
    success (paste session target "" "First\nline\n\nSecond paragraph");
    check_eq (title runtime target) "First\nline";
    let siblings = children runtime Q.page in
    check_eq (List.hd (List.rev siblings)).title "Second paragraph")

let markdown_paste_preserves_hierarchy_and_code () = R.with_runtime (fun session runtime _ ->
  rename runtime target "";
  success (paste session target "" "- Parent\n  - Child\n    - Grandchild\n- Tail\n  continued");
  check_eq (title runtime target) "Parent";
  let nested = List.hd (children runtime target) in
  check_eq nested.title "Child";
  check_eq (List.hd (children runtime nested.uuid)).title "Grandchild";
  check_eq (List.hd (List.rev (children runtime Q.page))).title "Tail\ncontinued");
  R.with_runtime (fun session runtime _ ->
  rename runtime target "";
  success (paste session target "" "```clojure\n- literal\n\n# still code\n```\n- After code");
  check_eq (title runtime target) "- literal\n\n# still code";
  check_eq (value runtime target "logseq.property.node/display-type") (Some (D.Keyword "code"));
  check_eq (List.hd (List.rev (children runtime Q.page))).title "After code")

let code_editors_paste_literal_text () = R.with_runtime (fun session runtime _ ->
  set runtime target "logseq.property.node/display-type" (Pending_ops.Keyword_value "code");
  rename runtime target "";
  let before = List.length (Graph_runtime.blocks_for_page runtime Q.page) in
  success (paste session target "" "- First\n\n- Second");
  check_eq (title runtime target) "- First\n\n- Second";
  check_eq (List.length (Graph_runtime.blocks_for_page runtime Q.page)) before)

let empty_targets_with_children_match_master () =
  List.iter (fun kind -> R.with_runtime (fun session runtime _ ->
    insert runtime child target "a0" "Keep child";
    rename runtime target "";
    if kind = "nested" then insert runtime grandchild Q.alpha "a0" "Nested copy";
    let copied = copy session (if kind = "single" then [Q.alpha] else [Q.alpha; Q.beta]) in
    success (paste_copy session runtime copied);
    if kind = "single" then begin
      check_eq (title runtime target) (title runtime Q.alpha);
      check_eq (ids (children runtime target)) [child]
    end else if kind = "flat" then begin
      check_eq (title runtime target) "";
      check_eq (List.map (fun (b : Cache_model.block) -> b.title) (children runtime target))
        [title runtime Q.alpha; title runtime Q.beta; "Keep child"]
    end else begin
      check_eq ~msg:"nested clipboard inserts beside an empty parent without stealing its children" (title runtime target) "";
      check_eq (ids (children runtime target)) [child];
      let reversed = List.rev (children runtime Q.page) in
      check_eq (List.hd reversed).uuid target;
      check_eq (List.nth reversed 1).title (title runtime Q.beta);
      let root = List.nth reversed 2 in
      check_eq root.title (title runtime Q.alpha);
      check_eq (List.hd (children runtime root.uuid)).title "Nested copy"
    end)) ["single"; "flat"; "nested"]

let selected_links_and_wrapped_references_match_master () =
  List.iter (fun (before, start, length, plain, expected) -> R.with_runtime (fun session runtime _ ->
    rename runtime target before;
    success (paste ~start ~length session target before plain);
    check_eq (title runtime target) expected))
    ["A😀Z", 1, 2, "https://example.com", "A[😀](https://example.com)Z";
     "https://old.example", 0, 19, "https://new.example", "https://new.example";
     "[Label](https://old.example)", 8, 19, "https://new.example", "[Label](https://new.example)";
     "[Label](https://old.example)", 16, 3, "https://new.example", "[Label](https://https://new.example.example)";
     "[Label](https://old.example)", 1, 5, "https://new.example", "[https://new.example](https://old.example)";
     "[Label](https://old.example)", 1, 5, "New label", "[New label](https://old.example)";
     "[Outer [Label]](https://old.example)", 8, 5, "https://new.example", "[Outer [https://new.example]](https://old.example)";
     "Outside [Label](https://old.example)", 0, 7, "https://new.example", "[Outside](https://new.example) [Label](https://old.example)";
     "[One](https://one) gap [Two](https://two)", 19, 3, "https://new.example", "[One](https://one) [gap](https://new.example) [Two](https://two)";
     "(())", 2, 0, "((" ^ Q.alpha ^ "))", "((" ^ Q.alpha ^ "))"]

let nonadjacent_selection_excludes_unselected_siblings () = R.with_runtime (fun session runtime _ ->
  insert runtime child Q.page "a5" "Paste here";
  let copied = copy session [target; Q.alpha] in
  success (paste ~rich:(text (member "blocksEDN" copied)) session child "Paste here" (text (member "plainText" copied)));
  let all = children runtime Q.page in
  let rec after = function [] -> [] | (b : Cache_model.block) :: rest -> if b.uuid = child then rest else after rest in
  check_eq ~msg:"unselected siblings between selected roots are not copied"
    (List.map (fun (b : Cache_model.block) -> b.title) (after all)) [title runtime Q.alpha; title runtime target];
  check_eq ~msg:"the unselected source sibling remains unchanged" (title runtime Q.beta) "Beta result")

let alternate_markdown_markers_and_math_match_master () =
  R.with_runtime (fun session runtime _ ->
    rename runtime target "";
    success (paste session target "" "+ Parent\n  * Child\n* Tail");
    check_eq (title runtime target) "Parent";
    check_eq (List.map (fun (b : Cache_model.block) -> b.title) (children runtime target)) ["Child"];
    check_eq (List.hd (List.rev (children runtime Q.page))).title "Tail");
  R.with_runtime (fun session runtime _ ->
    rename runtime target "";
    success (paste session target "" "$$\nx + y\n\n- literal\n$$\n- After math");
    check_eq (title runtime target) "x + y\n\n- literal";
    check_eq (value runtime target "logseq.property.node/display-type") (Some (D.Keyword "math"));
    check_eq (List.hd (List.rev (children runtime Q.page))).title "After math")

let invalid_and_foreign_clipboard_use_plain_text () = R.with_runtime (fun session runtime _ ->
  let copied = copy session [Q.alpha; Q.beta] in
  let rich = text (member "blocksEDN" copied) in
  let foreign = Str.global_replace (Str.regexp_string "plain-1") "another-graph" rich in
  List.iter (fun data ->
    block_event session "cancelEditing" target;
    rename runtime target "";
    success (paste ~rich:data session target "" "Plain fallback");
    check_eq (title runtime target) "Plain fallback") [foreign; "{broken"; "{:blocks [true]}"])

let invalid_tree_and_failed_storage_are_atomic () = R.with_runtime (fun session runtime _ ->
  let copied = copy session [Q.alpha; Q.beta] in
  let before = Graph_runtime.pending_operations runtime in
  let cyclic = Printf.sprintf "{:graph \"plain-1\" :op :copy :blocks [{:block/uuid #uuid \"%s\" :block/title \"Cycle\" :block/parent [:block/uuid #uuid \"%s\"]}]}" Q.alpha Q.alpha in
  let response = paste ~rich:cyclic session target (title runtime target) "Cycle" in
  check_eq (member "ok" response) (`Bool false);
  check_eq ~msg:"invalid clipboard leaves graph and pending operations unchanged" (Graph_runtime.pending_operations runtime) before;
  check_eq (title runtime target) "Gamma result";
  let failing = Rpc_session.create_session {Rpc_session.default_options with
    load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
    sync_cursor = Some (fun () -> Some 42);
    graph_db = Some (fun () -> Some (Graph_runtime.db runtime));
    graph_blocks = Some (fun () -> Some (Graph_runtime.blocks_for_page runtime Q.page));
    prepare_operation = Some (Graph_runtime.prepare_sync runtime);
    stage_operation = Some (fun _ -> Error "Storage failed")} |> Rpc_test.configure_plain_session in
  let response = paste_copy failing runtime copied in
  check_eq (member "ok" response) (`Bool false);
  check_eq (Graph_runtime.pending_operations runtime) before;
  check_eq ~msg:"failed insertion keeps the target draft available" (Outliner_state.editing_title (Session_types.state failing).outliner_state) (Some "Gamma result"))

let cases = [
  case "nested copy is a snapshot and syncs without moving sources" copies_nested_snapshots_without_moving_sources;
  case "typed properties and copied references survive" preserves_typed_properties_and_references;
  case "paste preserves outliner order and focuses the last block" pasted_roots_keep_selection_order;
  case "parent targets receive first children" pastes_into_parent_before_existing_children;
  case "plain text keeps inline and paragraph semantics" plain_text_preserves_inline_and_paragraph_semantics;
  case "Markdown keeps hierarchy and literal fenced code" markdown_paste_preserves_hierarchy_and_code;
  case "code editors paste literal text" code_editors_paste_literal_text;
  case "empty targets with children keep master placement" empty_targets_with_children_match_master;
  case "selected links and wrapped refs keep master semantics" selected_links_and_wrapped_references_match_master;
  case "nonadjacent selected roots exclude intervening siblings" nonadjacent_selection_excludes_unselected_siblings;
  case "alternate Markdown markers and literal math keep structure" alternate_markdown_markers_and_math_match_master;
  case "foreign and malformed clipboard use plain text" invalid_and_foreign_clipboard_use_plain_text;
  case "invalid trees and failed storage have no partial writes" invalid_tree_and_failed_storage_are_atomic;
]
