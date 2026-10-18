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

let native_session_roundtrip_preserves_draft_assets_and_navigation () =
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
  let saved =
    Native_bridge.encode_ui_session (Model.ui_session original)
  in
  ignore (Native_bridge.initialize 2 2 3);
  Fun.protect
    ~finally:(fun () -> ignore (Native_bridge.dispose ()))
    (fun () ->
       ignore (Native_bridge.apply_response graph_response);
       ignore
         (Native_bridge.apply_host_update "restore-ui-session" saved);
       ignore (Native_bridge.apply_host_update "save-ui-session" "null");
       Test_util.check_eq
         (Json.from_string saved)
         (Json.from_string (persisted_session 8)))

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

let cases =
  [ Test_util.case "node route projection retains journal and editor state"
      node_route_projection_retains_journal_and_editor_state;
    Test_util.case "node route title uses resolved markup"
      node_route_title_uses_resolved_markup;
    Test_util.case "first authoritative snapshot publishes retained patch"
      first_authoritative_snapshot_publishes_retained_patch;
    Test_util.case
      "native session roundtrip preserves draft assets and navigation"
      native_session_roundtrip_preserves_draft_assets_and_navigation;
    Test_util.case "quick actions clear selection before opening native recorder"
      quick_actions_clear_selection_before_opening_native_recorder ]
