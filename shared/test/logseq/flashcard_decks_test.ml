open Test_util
module D = Datascript
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let items = Q.items
let put = Q.put
let scope_page = "94000000-0000-4000-8000-000000000001"
let page_deck = "94000000-0000-4000-8000-000000000002"
let tag_deck = "94000000-0000-4000-8000-000000000003"
let page_query = "94000000-0000-4000-8000-000000000004"
let tag_query = "94000000-0000-4000-8000-000000000005"
let future = "94000000-0000-4000-8000-000000000006"
let subclass = "94000000-0000-4000-8000-000000000007"
let now () = int_of_float (Unix.gettimeofday () *. 1000.)
let result response =
  check_eq ~msg:(Yojson.Basic.to_string (member "error" response)) (member "ok" response) (`Bool true);
  member "result" response
let dispatch session action fields = Rpc_test.dispatch_json session action (Yojson.Basic.to_string (`Assoc fields))
let deck session fields = dispatch session "flashcardDeck" fields
let snapshot session = result (Yojson.Basic.from_string (Rpc_session.snapshot_visible session))
let metadata response = member "flashcardDecks" response
let ids response = List.map (fun card -> member "uuid" (member "block" card)) (items "flashcards" response) |> List.sort compare
let expect expected response = check_eq (List.sort compare (List.map (fun s -> `String s) expected)) (ids response)

let fixture () =
  let current = now () in
  let ref_ uuid = D.Ref_to (Q.ref_uuid uuid) in
  let group id uuid title definition source = R.entity id uuid title @ R.entity (id + 1) definition source @ [
    put uuid "block/page" (ref_ Q.page); put uuid "block/parent" (ref_ Q.page);
    put uuid "block/order" (D.String ("b" ^ string_of_int id));
    put uuid "block/tags" (D.Ref_to (D.Ident "logseq.class/Cards"));
    put uuid "logseq.property/query" (ref_ definition)] in
  D.db_with (
    [D.Retract (Q.ref_uuid Q.alpha, "block/tags", None);
     D.Retract (Q.ref_uuid Q.beta, "block/tags", None);
     D.Retract (Q.ref_uuid R.gamma, "block/tags", None);
     D.Retract (Q.ref_uuid Q.alpha, "block/refs", None)] @
    R.entity 940001 scope_page "Topic page" @ [put scope_page "block/name" (D.String "topic page")] @
    R.entity 940007 subclass "Special card" @ [
      put subclass "block/tags" (D.Ref_to (D.Ident "logseq.class/Tag"));
      put subclass "logseq.property.class/extends" (D.Ref_to (D.Ident "logseq.class/Card"))] @
    [put Q.alpha "block/tags" (D.Ref_to (D.Ident "logseq.class/Card"));
     put Q.alpha "block/refs" (ref_ scope_page);
     put Q.beta "block/tags" (D.Ref_to (D.Ident "logseq.class/Card"));
     put Q.beta "block/tags" (ref_ Q.project);
     put R.gamma "block/tags" (ref_ subclass); put R.gamma "block/tags" (ref_ Q.project);
     put R.gamma "block/refs" (ref_ scope_page); put R.gamma "block/parent" (ref_ Q.alpha)] @
    R.entity 940006 future "Future card" @ [put future "block/page" (ref_ Q.page);
      put future "block/parent" (ref_ Q.page); put future "block/order" (D.String "z0");
      put future "block/tags" (D.Ref_to (D.Ident "logseq.class/Card"));
      put future "block/tags" (ref_ Q.project); put future "block/refs" (ref_ scope_page);
      put future "logseq.property.fsrs/due" (D.Int64 (Int64.of_int (current + 86400000)))] @
    group 940020 page_deck "Page cards" page_query ("[[" ^ scope_page ^ "]]") @
    group 940030 tag_deck "Tag cards" tag_query ("(tags [[" ^ Q.project ^ "]])")) (R.fixture ())

let with_runtime ?(reject = false) f = Graph_runtime_test.with_store (fun path ->
  let search_path = path ^ ".search" in
  Fun.protect ~finally:(fun () -> Graph_runtime_test.cleanup_store path;
    List.iter Graph_runtime_test.remove_if_exists [search_path; search_path ^ "-wal"; search_path ^ "-shm"]) (fun () ->
    let conn = D.conn_from_db (fixture ()) in
    let runtime = Graph_runtime.create path 42 conn {Graph_runtime.default_options with
      auto_create_today = false; search_index_path = Some search_path} in
    let session = Rpc_session.create_session {Rpc_session.default_options with
      load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
      sync_cursor = Some (fun () -> Some (Graph_runtime.state runtime).server_t);
      graph_db = Some (fun () -> Some (Graph_runtime.db runtime));
      graph_due_flashcards = Some (Graph_runtime.due_flashcards runtime);
      graph_review_flashcard = Some (Graph_runtime.review_flashcard runtime);
      stage_operation = Some (if reject then (fun _ -> Error "Rejected test stage") else Graph_runtime.stage runtime);
      prepare_operation = Some (Graph_runtime.prepare_sync runtime);
      pending_operations = Some (fun () -> Graph_runtime.pending_operations runtime);
      graph_search_page = Some (Graph_runtime.search_page runtime)} in
    ignore (Rpc_test.configure_plain_session session);
    f session runtime conn))

let select session uuid = result (deck session ["action", `String "select"; "uuid", uuid])
let create session kind target title = deck session ["action", `String "create";
  "kind", `String kind; "targetUuid", `String target; "title", `String title]

let selects_saved_cards_queries () = with_runtime (fun session _ _ ->
  let all = result (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ()))) in
  expect [Q.alpha; Q.beta; R.gamma] all;
  check_eq (List.length (items "items" (metadata all))) 2;
  expect [Q.alpha; R.gamma] (select session (`String page_deck));
  expect [Q.beta; R.gamma] (select session (`String tag_deck));
  expect [Q.alpha; Q.beta; R.gamma] (select session `Null);
  check_eq (member "selectedUuid" (metadata (snapshot session))) `Null)

let creates_canonical_persistent_groups () =
  List.iter (fun (kind, target, source, expected) -> with_runtime (fun session runtime _ ->
    let response = result (create session kind target "My cards") in
    let uuid = R.text (member "selectedUuid" (metadata response)) in
    expect expected response;
    let db = Graph_runtime.db runtime in
    let eid = Option.get (D.entid db "block/uuid" (D.Uuid uuid)) in
    check (Graph_read.entity_is_instance_of db eid "logseq.class/Cards");
    let definition = List.hd (Graph_read.ref_eids db eid "logseq.property/query") in
    check_eq (Graph_read.entity_title (fun s -> Ok s) db definition) (Some source);
    check_eq (Graph_read.ref_eids db definition "logseq.property/created-from-property")
      [Option.get (D.entid db "db/ident" (D.Keyword "logseq.property/query"))];
    let reopened = Graph_runtime.create runtime.path 42 (D.conn_from_db (fixture ()))
      {Graph_runtime.default_options with auto_create_today = false} in
    check ~msg:"New card groups survive reopening the graph from the persisted operation queue"
      (D.entid (Graph_runtime.db reopened) "block/uuid" (D.Uuid uuid) <> None);
    List.iter (fun operation -> check_ok (Graph_runtime.prepare_sync runtime operation)) (Graph_runtime.pending_operations runtime)))
    ["page", scope_page, "[[" ^ scope_page ^ "]]", [Q.alpha; R.gamma];
     "tag", Q.project, "(tags [[" ^ Q.project ^ "]])", [Q.beta; R.gamma]]

let invalid_requests_do_not_mutate () =
  List.iter (fun (kind, target, title) -> with_runtime (fun session runtime _ ->
    let pending = List.length (Graph_runtime.pending_operations runtime) in
    check_eq (member "ok" (create session kind target title)) (`Bool false);
    check_eq (List.length (Graph_runtime.pending_operations runtime)) pending))
    ["tag", scope_page, "Bad tag"; "page", Q.alpha, "Not a page";
     "page", "missing", "Missing"; "invalid", scope_page, "Invalid kind";
     "page", scope_page, "   "];
  with_runtime ~reject:true (fun session runtime _ ->
    check_eq (member "ok" (create session "page" scope_page "Rejected")) (`Bool false);
    check_eq (Graph_runtime.pending_operations runtime) []);
  with_runtime (fun session runtime _ ->
    ignore (select session (`String page_deck));
    check_eq (member "ok" (deck session ["action", `String "select"; "uuid", `String Q.alpha])) (`Bool false);
    check_eq (member "selectedUuid" (metadata (snapshot session))) (`String page_deck);
    check_eq (Graph_runtime.pending_operations runtime) [])

let target_picker_restricts_pages_and_tags () = with_runtime (fun session _ _ ->
  let search kind query = result (deck session ["action", `String "search"; "kind", `String kind; "query", `String query]) in
  let targets response = items "items" (member "targetSearch" (metadata response)) in
  let page = targets (search "page" "Topic") in
  check (List.exists (fun item -> member "uuid" item = `String scope_page) page);
  let tags = targets (search "tag" "Project") in
  check (List.exists (fun item -> member "uuid" item = `String Q.project) tags);
  check (not (List.exists (fun item -> member "uuid" item = `String scope_page) tags)))

let reload_review_and_graph_changes_keep_the_correct_scope () = with_runtime (fun session runtime conn ->
  ignore (select session (`String tag_deck));
  expect [Q.beta; R.gamma] (result (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ()))));
  let reviewed = result (dispatch session "reviewFlashcard" ["uuid", `String Q.beta;
    "rating", `String "good"; "operationId", `String "94000000-0000-4000-8000-000000000099"; "now", `Int (now ())]) in
  expect [R.gamma] reviewed;
  check_eq (member "selectedUuid" (metadata reviewed)) (`String tag_deck);
  let pending = List.length (Graph_runtime.pending_operations runtime) in
  check_eq (member "ok" (deck session ["action", `String "create"; "kind", `String "page";
    "targetUuid", `String scope_page; "title", `String "Wrong graph"; "graphId", `String "other"])) (`Bool false);
  check_eq (List.length (Graph_runtime.pending_operations runtime)) pending;
  ignore (D.transact_conn conn [put page_query "block/title" (D.String "(")]);
  Graph_runtime.rebase runtime 42 [] [];
  check_eq ~msg:"An invalid saved query never silently becomes All cards"
    (member "ok" (deck session ["action", `String "select"; "uuid", `String page_deck])) (`Bool false);
  check_eq (member "selectedUuid" (metadata (snapshot session))) (`String tag_deck);
  ignore (Rpc_test.dispatch_json session "configure" {|{"graphId":"other","baseUrl":"https://api.logseq.io","token":"test-token"}|});
  check_eq ~msg:"A different graph cannot inherit the selected card group"
    (member "selectedUuid" (metadata (snapshot session))) `Null)

let native_controls_remain_available_when_empty () =
  List.iter (fun backend -> with_runtime (fun session runtime conn ->
    ignore (D.transact_conn conn (List.map (fun uuid ->
      put uuid "logseq.property.fsrs/due" (D.Int64 (Int64.of_int (now () + 86400000)))) [Q.alpha; Q.beta; R.gamma]));
    Graph_runtime.rebase runtime 42 [] [];
    ignore (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ())));
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      App_test.send app Model.ShowFlashcards; App_test.flush app;
      let host = Lui_app.runtime app in
      let find id = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
      check (find "menu.flashcards.deck" <> -1);
      let add = find "button.flashcards.deck.add" in
      check ~msg:"A card group can be added from the review screen" (add <> -1);
      App_test.dispatch app (Lui_protocol.Press add); App_test.flush app;
      check ~msg:"New groups use a native sheet" (find "sheet.flashcards.deck.create" <> -1);
      check (find "field.flashcards.deck.search" <> -1);
      App_test.dispatch app (Lui_protocol.Press (find "button.flashcards.deck.cancel")); App_test.flush app;
      check (find "sheet.flashcards.deck.create" = -1)))) [App_test.ios_backend; App_test.kotlin_backend]

let changing_groups_resets_the_reveal_phase () = with_runtime (fun session _ _ ->
  ignore (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ())));
  Q.with_ui App_test.ios_backend (Rpc_session.snapshot_visible session) (fun app ->
    App_test.send app Model.RevealFlashcardAnswer;
    App_test.flush app;
    check (App.model app).Model.flashcard_answer_revealed;
    ignore (select session (`String page_deck));
    let projection = match Response_snapshot.decode_response (Rpc_session.snapshot_visible session) with
      | Ok value -> value | Error message -> fail message in
    App_test.send app (Model.ApplyCoreSnapshot projection);
    App_test.flush app;
    check ~msg:"A new group resets the answer even when its first card is the same"
      (not (App.model app).Model.flashcard_answer_revealed)))

let malformed_selections_keep_the_current_group () = with_runtime (fun session runtime _ ->
  ignore (select session (`String page_deck));
  List.iter (fun uuid ->
    check_eq (member "ok" (deck session ["action", `String "select"; "uuid", uuid])) (`Bool false);
    check_eq (member "selectedUuid" (metadata (snapshot session))) (`String page_deck))
    [`Bool true; `Int 42; `List []; `Assoc []];
  check_eq (member "ok" (deck session ["action", `String "select"])) (`Bool false);
  check_eq (Graph_runtime.pending_operations runtime) [])

let existing_journal_keeps_its_children () = with_runtime (fun session runtime conn ->
  let current = now () in
  let day = Cache_model.journal_day_for_ms current in
  let journal = "94000000-0000-4000-8000-000000000010" in
  let child = "94000000-0000-4000-8000-000000000011" in
  let ref_ uuid = D.Ref_to (Q.ref_uuid uuid) in
  ignore (D.transact_conn conn (R.entity 940010 journal "Existing journal" @ [
    put journal "block/name" (D.String "existing journal");
    put journal "block/journal-day" (D.Int64 (Int64.of_int day))] @ R.entity 940011 child "Keep this block" @ [
    put child "block/page" (ref_ journal); put child "block/parent" (ref_ journal);
    put child "block/order" (D.String "a0")]));
  Graph_runtime.rebase runtime 42 [] [];
  let response = result (create session "page" scope_page "  New group  ") in
  let uuid = R.text (member "selectedUuid" (metadata response)) in
  let db = Graph_runtime.db runtime in
  let eid = Option.get (D.entid db "block/uuid" (D.Uuid uuid)) in
  let journal_eid = Option.get (D.entid db "block/uuid" (D.Uuid journal)) in
  check_eq (Graph_read.journal_page_uuid db day) (Some journal);
  check_eq (Graph_read.entity_title (fun s -> Ok s) db eid) (Some "New group");
  check_eq (Graph_read.ref_eids db eid "block/parent") [journal_eid];
  let children = Datascript_value.datoms_by_ref db D.Aevt "block/parent" journal_eid
    |> Seq.filter_map (fun (d : D.datom) -> Graph_read.string_value (Graph_read.value db d.e "block/title"))
    |> List.of_seq |> List.sort compare in
  check_eq children ["Keep this block"; "New group"];
  check (Option.get (Graph_read.string_value (Graph_read.value db eid "block/order")) > "a0");
  check_eq (List.length (Graph_runtime.pending_operations runtime)) 1)

let hidden_deleted_and_invalid_selected_groups () = with_runtime (fun session runtime conn ->
  ignore (select session (`String page_deck));
  ignore (D.transact_conn conn [put page_query "block/title" (D.String "(")]);
  Graph_runtime.rebase runtime 42 [] [];
  let reloaded = result (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ()))) in
  expect [] reloaded;
  check_eq (member "selectedUuid" (metadata reloaded)) (`String page_deck);
  check (member "error" (metadata reloaded) <> `Null);
  ignore (D.transact_conn conn [D.RetractEntity (Q.ref_uuid page_deck)]);
  Graph_runtime.rebase runtime 42 [] [];
  let reloaded = result (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ()))) in
  expect [] reloaded;
  check (not (List.exists (fun item -> member "uuid" item = `String page_deck) (items "items" (metadata reloaded))));
  expect [Q.alpha; Q.beta; R.gamma] (select session `Null))

let search_preserves_the_review_scope () = with_runtime (fun session runtime _ ->
  ignore (select session (`String page_deck));
  List.iter (fun (kind, query) ->
    let searched = result (deck session ["action", `String "search"; "kind", `String kind; "query", `String query]) in
    expect [Q.alpha; R.gamma] searched;
    check_eq (member "selectedUuid" (metadata searched)) (`String page_deck);
    let search = member "targetSearch" (metadata searched) in
    check_eq (member "kind" search) (`String kind);
    check_eq (member "query" search) (`String query)) ["page", "Topic"; "tag", "Project"];
  check_eq (Graph_runtime.pending_operations runtime) [])

let inherited_groups_and_empty_queries_follow_master () = with_runtime (fun session runtime conn ->
  let inherited = "94000000-0000-4000-8000-000000000040" in
  ignore (D.transact_conn conn (R.entity 940040 inherited "Special group" @ [
    put inherited "block/tags" (D.Ref_to (D.Ident "logseq.class/Tag"));
    put inherited "logseq.property.class/extends" (D.Ref_to (D.Ident "logseq.class/Cards"));
    D.Retract (Q.ref_uuid page_deck, "block/tags", None);
    put page_deck "block/tags" (D.Ref_to (Q.ref_uuid inherited));
    put page_query "block/title" (D.String "  ");
    put tag_deck "logseq.property/hide?" (D.Bool true)]));
  Graph_runtime.rebase runtime 42 [] [];
  let loaded = result (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ()))) in
  check_eq (List.map (member "uuid") (items "items" (metadata loaded))) [`String page_deck];
  expect [Q.alpha; Q.beta; R.gamma] (select session (`String page_deck));
  check_eq (member "ok" (deck session ["action", `String "select"; "uuid", `String tag_deck])) (`Bool false))

let find app id = App_test.descendant_with_identifier (Lui_app.runtime app) (Lui_app.root_node app) id
let press app id =
  let node = find app id in
  check ~msg:("Missing native control: " ^ id) (node <> -1);
  App_test.dispatch app (Lui_protocol.Press node); App_test.flush app
let input app id value =
  let node = find app id in
  check ~msg:("Missing native field: " ^ id) (node <> -1);
  App_test.dispatch app (Lui_protocol.TextChanged (node, value)); App_test.flush app
let finish_deck_effect app session =
  let eff = List.find (function Model.FlashcardDeckEffect _ -> true | _ -> false)
    (App.model app).pending_effects in
  let id = Model.effect_id eff in
  App_test.send app (Model.DequeueEffect id); App_test.flush app;
  let response = Core_effect_test.execute session "flashcard-deck"
    ["text", (match eff with Model.FlashcardDeckEffect (_, payload) -> `String payload | _ -> assert false)] in
  let succeeded = member "ok" response = `Bool true in
  App_test.send app (Model.ResolveEffect (id, succeeded, if succeeded then Yojson.Basic.to_string response
    else R.text (member "message" (member "error" response))));
  App_test.flush app;
  if succeeded then (
    match Response_snapshot.decode_response (Yojson.Basic.to_string response) with
    | Ok projection -> App_test.send app (Model.ApplyCoreSnapshot projection); App_test.flush app
    | Error message -> fail message);
  succeeded

let native_create_and_select_roundtrip () =
  List.iter (fun backend -> with_runtime (fun session runtime _ ->
    ignore (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ())));
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      App_test.send app Model.ShowFlashcards; App_test.flush app;
      press app ("flashcards.deck.select." ^ page_deck);
      check (finish_deck_effect app session);
      check_eq (List.length (App.model app).flashcards) 2;
      press app "button.flashcards.deck.add";
      check (finish_deck_effect app session);
      press app "button.flashcards.deck.create";
      check_eq ~msg:"Creating without a selected target is disabled" (List.filter
        (function Model.FlashcardDeckEffect _ -> true | _ -> false) (App.model app).pending_effects) [];
      input app "field.flashcards.deck.search" "Topic";
      check (finish_deck_effect app session);
      press app ("flashcards.deck.target." ^ scope_page);
      input app "field.flashcards.deck.name" "Native page cards";
      press app "button.flashcards.deck.create";
      press app "button.flashcards.deck.create";
      check_eq ~msg:"Rapid repeated taps enqueue only one create" (List.length
        (List.filter (function Model.FlashcardDeckEffect _ -> true | _ -> false) (App.model app).pending_effects)) 1;
      check (finish_deck_effect app session);
      check_eq ~msg:"Successful creation closes the sheet after applying the core snapshot"
        (find app "sheet.flashcards.deck.create") (-1);
      check_eq (List.length (App.model app).flashcards) 2;
      check_eq (List.length (Graph_runtime.pending_operations runtime)) 1;
      let created = R.text (member "createdUuid" (metadata (snapshot session))) in
      check (find app ("flashcards.deck.select." ^ created) <> -1);
      press app "flashcards.deck.select.all";
      check (finish_deck_effect app session);
      check_eq (List.length (App.model app).flashcards) 3;
      press app "button.flashcards.deck.add";
      check (finish_deck_effect app session);
      press app "flashcards.deck.kind.tag";
      check (finish_deck_effect app session);
      input app "field.flashcards.deck.search" "Project";
      check (finish_deck_effect app session);
      press app ("flashcards.deck.target." ^ Q.project);
      press app "button.flashcards.deck.create";
      check (finish_deck_effect app session);
      check_eq (find app "sheet.flashcards.deck.create") (-1);
      check_eq (List.length (App.model app).flashcards) 2;
      check_eq (List.length (Graph_runtime.pending_operations runtime)) 2)))
    [App_test.ios_backend; App_test.kotlin_backend]

let native_failed_create_can_retry_or_cancel () =
  List.iter (fun backend -> with_runtime ~reject:true (fun session runtime _ ->
    ignore (Rpc_test.dispatch_json session "loadFlashcards" (string_of_int (now ())));
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      App_test.send app Model.ShowFlashcards; App_test.flush app;
      App_test.send app Model.RevealFlashcardAnswer; App_test.flush app;
      press app "button.flashcards.deck.add";
      check (finish_deck_effect app session);
      input app "field.flashcards.deck.search" "Topic";
      check (finish_deck_effect app session);
      press app ("flashcards.deck.target." ^ scope_page);
      press app "button.flashcards.deck.create";
      check (not (finish_deck_effect app session));
      check (find app "sheet.flashcards.deck.create" <> -1);
      check (find app "error.flashcards.deck" <> -1);
      check_eq (Graph_runtime.pending_operations runtime) [];
      press app "button.flashcards.deck.create";
      check (not (finish_deck_effect app session));
      press app "button.flashcards.deck.cancel";
      check_eq (find app "sheet.flashcards.deck.create") (-1);
      check ~msg:"Searching, a rejected save and cancellation preserve the current answer"
        (App.model app).flashcard_answer_revealed;
      check_eq (member "selectedUuid" (metadata (snapshot session))) `Null)))
    [App_test.ios_backend; App_test.kotlin_backend]

let cases = [
  case "saved card groups filter due cards without dropping nested or inherited cards" selects_saved_cards_queries;
  case "new groups store the canonical Cards tag and query property" creates_canonical_persistent_groups;
  case "invalid selections and failed creates leave graph and selection intact" invalid_requests_do_not_mutate;
  case "group targets use a page or tag picker" target_picker_restricts_pages_and_tags;
  case "reload, review, invalid queries and graph changes retain safe scopes" reload_review_and_graph_changes_keep_the_correct_scope;
  case "both hosts expose group selection and creation" native_controls_remain_available_when_empty;
  case "changing groups resets reveal state even for the same first card" changing_groups_resets_the_reveal_phase;
  case "malformed selection payloads cannot clear the current group" malformed_selections_keep_the_current_group;
  case "creating a group appends to the actual existing journal" existing_journal_keeps_its_children;
  case "invalid and deleted selected groups never become All cards" hidden_deleted_and_invalid_selected_groups;
  case "target searches preserve the active review scope" search_preserves_the_review_scope;
  case "Cards subclasses, hidden groups and empty queries follow master" inherited_groups_and_empty_queries_follow_master;
  case "both native hosts create and select page and tag groups through the real core" native_create_and_select_roundtrip;
  case "both native hosts retain drafts and review state after failed saves" native_failed_create_can_retry_or_cancel;
]
