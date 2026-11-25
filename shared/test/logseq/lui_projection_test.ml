module Json = Yojson.Basic

let object_fields json =
  match json with
  | `Assoc fields -> fields
  | _ -> failwith "expected a JSON object"

let object_member name json =
  match List.assoc_opt name (object_fields json) with
  | Some value -> value
  | None -> `Null

let string_member name json =
  match object_member name json with
  | `String value -> Some value
  | _ -> None

let int_member name json =
  match object_member name json with
  | `Int value -> Some value
  | _ -> None

let graph_response =
  "{\"apiVersion\":1,\"ok\":true,\"result\":{\"revision\":1,\"blocks\":[],\"selectedBlock\":null,\"lastRefreshAt\":null,\"graphName\":\"Local graph\",\"selectedGraphId\":\"local\",\"graphs\":[{\"id\":\"local\",\"name\":\"Local graph\",\"schemaVersion\":\"65.33\",\"isEncrypted\":false,\"isReady\":true}]}}"

let take_effect () =
  `Assoc
    (object_fields
       (object_member "effect"
          (Json.from_string (Native_bridge.take_effect ()))))

let rec persisted_session remaining =
  if remaining = 0 then
    failwith "restored session did not emit persistence effect"
  else
    let eff = take_effect () in
    if string_member "kind" eff = Some "persist-ui-session" then
      Option.value ~default:"" (string_member "text" eff)
    else (
      Native_bridge.resolve_effect
        (Option.value ~default:0 (int_member "id" eff))
        true ""
      |> ignore;
      persisted_session (remaining - 1))

let node_route_projection_retains_journal_and_editor_state () =
  match
    Response_snapshot.decode_response
      "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerRows\":[{\"block\":{\"uuid\":\"journal\",\"title\":\"Journal\"},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false}],\"nodeRoutes\":[{\"uuid\":\"node-a\",\"isTag\":false,\"isProperty\":false,\"page\":{\"uuid\":\"page-a\",\"title\":\"Project\"},\"outlinerState\":{\"editing\":{\"uuid\":\"child\",\"title\":\"Child\",\"caretUTF16Offset\":5},\"selectedBlockIds\":[\"child\"],\"autocomplete\":null},\"outlinerAutocompleteCandidates\":[],\"outlinerRows\":[{\"block\":{\"uuid\":\"child\",\"title\":\"Child\"},\"depth\":1,\"hasChildren\":false,\"isCollapsed\":false}]}]}}"
  with
  | Error message -> Alcotest.fail message
  | Ok projection ->
    let routes = projection.Model.node_routes in
    let route = List.nth routes 0 in
    Test_util.check_eq (List.length routes) 1;
    Test_util.check_eq
      (List.map (fun row -> row.Model.row_uuid)
         route.Model.node_outliner_rows)
      [ "child" ];
    Test_util.check_eq
      (Option.map (fun editing -> editing.Model.editing_uuid)
         route.Model.node_outliner_editing)
      (Some "child");
    Test_util.check_eq route.Model.node_outliner_selected_block_ids
      [ "child" ];
    Test_util.check_eq
      (List.map (fun row -> row.Model.row_uuid)
         projection.Model.journal_outliner_rows)
      [ "journal" ]

let node_route_title_uses_resolved_markup () =
  let source = "[[Project]] #[[6ad51977-c95d-47a2-880a-00056f684f2e]]" in
  let block =
    `Assoc
      [ "uuid", `String "block-a";
        "title", `String source;
        "markup", `List
          [ `Assoc [ "type", `String "nodeReference";
                     "uuid", `String "page-a";
                     "title", `String "Project" ];
            `Assoc [ "type", `String "text"; "text", `String " " ];
            `Assoc [ "type", `String "tagReference";
                     "uuid", `String "6ad51977-c95d-47a2-880a-00056f684f2e";
                     "title", `String "标签" ] ] ]
  in
  let response =
    `Assoc
      [ "ok", `Bool true;
        "result", `Assoc
          [ "nodeRoutes", `List
              [ `Assoc
                  [ "uuid", `String "block-a";
                    "page", `Assoc [ "uuid", `String "page-a";
                                     "title", `String "Project" ];
                    "blocks", `List [ block ];
                    "outlinerRows", `List
                      [ `Assoc [ "block", block; "depth", `Int 0 ] ] ] ] ] ]
    |> Json.to_string
  in
  match Response_snapshot.decode_response response with
  | Error message -> Alcotest.fail message
  | Ok projection ->
    let route = List.hd projection.Model.node_routes in
    Test_util.check_eq route.Model.node_title "Project #标签";
    Test_util.check_eq
      (List.hd route.Model.node_outliner_rows).Model.row_title source

let first_authoritative_snapshot_publishes_retained_patch () =
  ignore (Native_bridge.initialize 2 2 0);
  Fun.protect
    ~finally:(fun () -> ignore (Native_bridge.dispose ()))
    (fun () ->
       Test_util.check ~msg:"authoritative snapshot produced a patch"
         (Native_bridge.apply_response graph_response <> ""))

let native_session_roundtrip_preserves_assets_and_returns_home () =
  let asset =
    { Model.uuid = "pending-photo";
      title = "照片.jpg";
      local_path = "/tmp/photo.jpg";
      payload = "{\"uuid\":\"pending-photo\"}" }
  in
  let original =
    { (Model.initial ()) with
      Model.selected_graph_id = Some "local";
      composer_draft = "Unsent\n草稿";
      composer_expanded = true;
      composer_assets = [ asset ];
      search_open = true;
      search_query = "hello";
      app_navigation_path = [ Model.NodeRoute "page-a" ];
      search_navigation_path = [ Model.NodeRoute "block-b" ] }
  in
  let defaults = Model.default_tasks_view in
  let selected_tab = Model.update original (Model.SetTasksView { defaults with tab = Model.TasksUpcoming }) in
  Test_util.check_eq ~msg:"switching Tasks tabs is transient" selected_tab.pending_effects [];
  let preferences = {
    Model.tab = Model.TasksUpcoming;
    group_by_page = false; sort_tasks = Model.DeadlineDate; sort_pages = Model.PageCreated;
    compact = true; show_completed = false; show_past = false;
  } in
  let original = Model.update selected_tab (Model.SetTasksView preferences) in
  let saved = match original.pending_effects with
    | [Model.PersistUISessionEffect (_, session)] -> Native_bridge.encode_ui_session session
    | _ -> Alcotest.fail "Changing Tasks display preferences must save them immediately" in
  ignore (Native_bridge.initialize 2 2 3);
  Fun.protect
    ~finally:(fun () -> ignore (Native_bridge.dispose ()))
    (fun () ->
       ignore (Native_bridge.apply_response graph_response);
       ignore
         (Native_bridge.apply_host_update "restore-ui-session" saved);
       let current = App.model (Native_bridge.app ()) in
       Test_util.check_eq ~msg:"Tasks preferences survive relaunch while the tab is transient"
         current.tasks_view { preferences with tab = Model.TasksToday };
       ignore (Native_bridge.apply_host_update "save-ui-session" "null");
       let expected = { (Model.ui_session original) with
         composer_expanded = false; search_open = false; query = "";
         app_path = []; search_path = [] } in
       Test_util.check_eq
         (Json.from_string (Native_bridge.encode_ui_session expected))
         (Json.from_string (persisted_session 8)))

let reaction_picker_preserves_account_recency_and_canonical_ids () =
  let account id = `Assoc ["account", `String id] in
  let current = { (Model.initial ()) with selected_graph_id = Some "local";
    collaboration = account "alice" } in
  let choose current emoji =
    Model.update (Model.update current (Model.OpenReactionPicker ("block-a", [])))
      (Model.ChooseDiscussionReaction ("block-a", emoji)) in
  let current = choose (choose (choose current "heart") "rocket") "heart" in
  Test_util.check_eq current.reaction_picker None;
  Test_util.check_eq (Model.recent_reaction_ids current) ["heart"; "rocket"];
  let ids entries = List.map (fun (emoji : Reaction_emoji.emoji) -> emoji.id) entries in
  Test_util.check_eq (ids (Reaction_emoji.quick ~limit:3 (Model.recent_reaction_ids current)))
    ["heart"; "rocket"; "+1"];
  Test_util.check_eq (Node_presentation.reaction_emoji "thumbsup") "👍";
  Test_util.check_eq (Node_presentation.reaction_emoji "rocket") "🚀";
  Test_util.check_eq ~msg:"search ranks the exact ID before keyword matches"
    (List.hd (ids (Reaction_emoji.search "rocket"))) "rocket";
  let session = Model.ui_session current |> Native_bridge.encode_ui_session in
  ignore (Native_bridge.initialize 2 2 3);
  Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ())) (fun () ->
    ignore (Native_bridge.apply_response graph_response);
    ignore (Native_bridge.apply_host_update "restore-ui-session" session);
    let restored = App.model (Native_bridge.app ()) in
    Test_util.check_eq (Model.recent_reaction_ids {restored with collaboration = account "alice"})
      ["heart"; "rocket"];
    Test_util.check_eq (Model.recent_reaction_ids {restored with collaboration = account "bob"}) [])

let quick_actions_clear_selection_before_opening_native_recorder () =
  List.iter
    (fun kind ->
       ignore (Native_bridge.initialize 2 2 3);
       Fun.protect
         ~finally:(fun () -> ignore (Native_bridge.dispose ()))
         (fun () ->
            ignore
              (Native_bridge.apply_host_update "open-quick-action"
                 (Json.to_string (`String kind)));
            let clear = take_effect () in
            Test_util.check_eq (string_member "kind" clear)
              (Some "clear-selected-page");
            ignore
              (Native_bridge.resolve_effect
                 (Option.value ~default:0 (int_member "id" clear))
                 true "");
            if kind = "audio" then (
              let recorder = take_effect () in
              Test_util.check_eq (string_member "kind" recorder)
                (Some "present-attachment");
              Test_util.check_eq (string_member "text" recorder)
                (Some "audio"))))
    [ "capture"; "journal"; "audio" ]

let search_queries_wait_200ms_and_only_dispatch_the_latest_input () =
  ignore (Native_bridge.initialize 2 2 3);
  Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ())) (fun () ->
    ignore (Native_bridge.flush_action (Model.ChangeSearchQuery "abc"));
    let waiting () =
      let response = Json.from_string (Native_bridge.take_effect ()) in
      Test_util.check ~msg:"a pending query returns a nonblocking wakeup"
        (match int_member "waitMs" response with Some ms -> ms > 0 && ms <= 200 | None -> false)
    in
    waiting ();
    ignore (Unix.select [] [] [] 0.11);
    ignore (Native_bridge.flush_action (Model.ChangeSearchQuery "abcd"));
    ignore (Unix.select [] [] [] 0.11);
    waiting ();
    ignore (Unix.select [] [] [] 0.11);
    let eff = take_effect () in
    Test_util.check_eq (string_member "kind" eff) (Some "search-nodes");
    Test_util.check_eq (string_member "text" eff) (Some "abcd");
    ignore (Native_bridge.flush_action (Model.ChangeSearchQuery ""));
    Test_util.check_eq (Native_bridge.take_effect ()) "")

let autocomplete_debounces_queries_but_flushes_before_structural_actions () =
  ignore (Native_bridge.initialize 2 2 3);
  Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ())) (fun () ->
    ignore (Native_bridge.apply_response
      {|{"ok":true,"result":{"outlinerState":{"editing":{"uuid":"block-a","title":"","caretUTF16Offset":0}}}}|});
    ignore (Native_bridge.flush_action (Model.ChangeOutlinerText ("block-a", "#a", 2)));
    ignore (Native_bridge.flush_action (Model.ChangeOutlinerText ("block-a", "#ab", 3)));
    ignore (Native_bridge.flush_action (Model.MoveOutlinerCaret ("block-a", 2)));
    Test_util.check_eq ~msg:"typing and caret updates coalesce into the latest query"
      (List.length (App.model (Native_bridge.app ())).Model.pending_effects) 1;
    let waiting = Json.from_string (Native_bridge.take_effect ()) in
    Test_util.check ~msg:"autocomplete waits for the debounce deadline"
      (int_member "waitMs" waiting <> None);
    ignore (Native_bridge.flush_action (Model.ReturnOutlinerEditor ("block-a", "#ab", 2)));
    let edit = take_effect () in
    Test_util.check_eq (string_member "kind" edit) (Some "change-outliner-text");
    Test_util.check_eq (string_member "text" edit) (Some "#ab");
    Test_util.check_eq (int_member "value" edit) (Some 2);
    let enter = take_effect () in
    Test_util.check_eq (string_member "kind" enter) (Some "return-outliner-editor"))

let viewport_hydration_does_not_bypass_the_query_debounce () =
  ignore (Native_bridge.initialize 2 2 3);
  Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ())) (fun () ->
    ignore (Native_bridge.flush_action (Model.ChangeSearchQuery "pending"));
    ignore (Native_bridge.flush_action (Model.EnsureOutlinerRows ["row"]));
    let first = take_effect () in
    Test_util.check_eq ~msg:"viewport reads remain responsive while the input timer is pending"
      (string_member "kind" first) (Some "hydrate-outliner-rows");
    let waiting = Json.from_string (Native_bridge.take_effect ()) in
    Test_util.check ~msg:"hydrating rows does not dispatch the search query early"
      (int_member "waitMs" waiting <> None))

let pending_references_schedule_a_separate_query () =
  ignore (Native_bridge.initialize 2 2 3);
  let response pending = Yojson.Basic.to_string (`Assoc ["ok", `Bool true;
    "result", `Assoc ["selectedPage", `Assoc ["uuid", `String "page"; "title", `String "Page"];
      "pendingReferenceUuid", pending]]) in
  ignore (Native_bridge.apply_response (response (`String "page")));
  let encoded = Native_bridge.take_effect () in
  Test_util.check ~msg:"page snapshot schedules deferred references" (encoded <> "");
  let eff = object_member "effect" (Json.from_string encoded) in
  Test_util.check_eq (string_member "kind" eff) (Some "load-page-references");
  Test_util.check_eq (string_member "text" eff) (Some "page");
  ignore (Native_bridge.apply_response (response (`String "page")));
  let next = Native_bridge.take_effect () in
  Test_util.check ~msg:"in-flight reference requests are not duplicated" (next = "");
  ignore (Native_bridge.apply_response (response `Null));
  ignore (Native_bridge.dispose ())

let reference_updates_preserve_body_and_ignore_stale_pages () =
  ignore (Native_bridge.initialize 2 2 3);
  ignore (Native_bridge.apply_response
    {|{"ok":true,"result":{"selectedGraphId":"g","selectedPage":{"uuid":"page","title":"Page"},"outlinerRows":[{"block":{"uuid":"body","title":"Body"}}]}}|});
  let before = (App.model (Native_bridge.app ())).Model.outliner_rows in
  ignore (Native_bridge.apply_response
    {|{"ok":true,"result":{"isReferencePatch":true,"selectedGraphId":"g","referenceUuid":"page","referenceBlocks":[{"uuid":"ref","title":"Reference"}]}}|});
  let after = App.model (Native_bridge.app ()) in
  Test_util.check ~msg:"reference updates preserve the exact body rows" (before == after.Model.outliner_rows);
  Test_util.check_eq (List.map (fun row -> row.Model.row_uuid) after.related_rows) ["ref"];
  ignore (Native_bridge.apply_response
    {|{"ok":true,"result":{"isReferencePatch":true,"selectedGraphId":"g","referenceUuid":"other","referenceBlocks":[]}}|});
  Test_util.check_eq (List.map (fun row -> row.Model.row_uuid) (App.model (Native_bridge.app ())).related_rows) ["ref"];
  ignore (Native_bridge.dispose ())

let cases =
  [ Test_util.case "references preserve body and ignore stale pages" reference_updates_preserve_body_and_ignore_stale_pages; Test_util.case "pending references schedule a separate query" pending_references_schedule_a_separate_query; Test_util.case "node route projection retains journal and editor state"
      node_route_projection_retains_journal_and_editor_state;
    Test_util.case "node route title uses resolved markup"
      node_route_title_uses_resolved_markup;
    Test_util.case "first authoritative snapshot publishes retained patch"
      first_authoritative_snapshot_publishes_retained_patch;
    Test_util.case
      "native session roundtrip preserves assets and returns home"
      native_session_roundtrip_preserves_assets_and_returns_home;
    Alcotest.test_case "Reaction recency persists per account" `Quick
      reaction_picker_preserves_account_recency_and_canonical_ids;
    Test_util.case "quick actions clear selection before opening native recorder"
      quick_actions_clear_selection_before_opening_native_recorder;
    Test_util.case "search waits 200ms and dispatches only the latest input"
      search_queries_wait_200ms_and_only_dispatch_the_latest_input;
    Test_util.case "autocomplete debounces queries and flushes before structural actions"
      autocomplete_debounces_queries_but_flushes_before_structural_actions;
    Test_util.case "viewport hydration does not bypass the query debounce"
      viewport_hydration_does_not_bypass_the_query_debounce ]
