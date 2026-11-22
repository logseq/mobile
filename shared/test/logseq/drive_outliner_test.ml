(* Journal outliner editing, selection, and block deletion. Scripts live in
   logseq/drive/outliner/. *)

let open_projection (host : Drive_host.host) (graph : Model.graph) =
  Drive_host.project host ~graph_id:graph.Model.id ~graph_name:graph.name
    ~encrypted:graph.is_encrypted ~unlocked:(not graph.is_encrypted)
    ~rows:host.Drive_host.rows ~sidebar:(Drive_host.host_sidebar host)
    ~flashcards:host.flashcards host.graphs

let selected_graph (host : Drive_host.host) model =
  Option.map (Drive_host.find_graph host) model.Model.selected_graph_id
  |> Option.join

let keep_editor (model : Model.logseq_model) projection =
  match model.outliner_editing with
  | Some editing ->
    Drive_host.editing_snapshot ~uuid:editing.editing_uuid ~title:editing.editing_title
      ~caret:editing.caret_utf16_offset projection
  | None -> projection

let editing_title (model : Model.logseq_model) uuid fallback =
  match model.outliner_editing with
  | Some editing when editing.editing_uuid = uuid -> editing.editing_title
  | _ -> fallback

let adjust_depth (host : Drive_host.host) uuid delta =
  Drive_host.map_row host uuid (fun row ->
      { row with Model.depth = max 0 (row.depth + delta) })

let rec swap_at index rows =
  match rows with
  | first :: second :: rest when index = 0 -> second :: first :: rest
  | row :: rest -> row :: swap_at (index - 1) rest
  | [] -> []

let move_row (host : Drive_host.host) uuid offset =
  let rec index_of index = function
    | [] -> None
    | (row : Model.outline_row) :: _ when row.row_uuid = uuid -> Some index
    | _ :: rest -> index_of (index + 1) rest
  in
  match index_of 0 host.rows with
  | None -> ()
  | Some index ->
    let target = index + offset in
    if target >= 0 && target < List.length host.rows then begin
      let reordered =
        if offset > 0 then swap_at index host.rows else swap_at target host.rows
      in
      host.rows <-
        List.map
          (fun (row : Model.outline_row) ->
            if row.row_uuid = uuid then
              { row with row_list_number = Some (if offset > 0 then 2 else 1) }
            else row)
          reordered
    end

let snapshot_editor (host : Drive_host.host) model =
  Drive_host.current_graph_projection host model ~extra:(keep_editor model)

let handle (host : Drive_host.host) model = function
  | Model.AddRootBlockEffect (id, _page_uuid) ->
    Drive_host.append_capture host id "New block" ();
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             projection)
      :: Drive_host.resolved id)
  | Model.DeleteBlockEffect (id, uuid, _) ->
    host.Drive_host.removed_blocks <- uuid :: host.removed_blocks;
    host.rows <-
      List.filter (fun (row : Model.outline_row) -> row.row_uuid <> uuid) host.rows;
    let refresh_search =
      if model.Model.search_query = "" then []
      else
        [ Model.ApplySearchResults (model.search_query, Drive_host.search_hits host) ]
    in
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             {
               projection with
               Model.projection_outliner_selected_block_ids = [];
             })
      :: refresh_search
      @ Drive_host.resolved id)
  | Model.LongPressOutlinerBlockEffect (id, uuid) ->
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             {
               projection with
               Model.projection_outliner_selected_block_ids = [ uuid ];
             })
      :: Drive_host.resolved id)
  | Model.SetOutlinerTaskStatusEffect (id, uuid, status) ->
    host.rows <-
      List.map
        (fun (row : Model.outline_row) ->
          if row.row_uuid = uuid then { row with row_status = Some status } else row)
        host.rows;
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             projection)
      :: Drive_host.resolved id)
  | Model.ToggleOutlinerCollapsedEffect (id, uuid) ->
    host.rows <-
      List.map
        (fun (row : Model.outline_row) ->
          if row.row_uuid = uuid then
            { row with is_collapsed = not row.is_collapsed }
          else row)
        host.rows;
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             projection)
      :: Drive_host.resolved id)
  | Model.OutlinerToolbarEffect (id, action) ->
    let autocomplete =
      if action = "pageReference" then
        Some
          {
            Model.autocomplete_kind = Model.NodeAutocomplete;
            autocomplete_query = "";
          }
      else if action = "tag" then
        Some
          { Model.autocomplete_kind = Model.TagAutocomplete; autocomplete_query = "" }
      else None
    in
    let clear_selection = action = "unselect" || action = "delete" in
    let structural =
      List.mem action [ "indent"; "outdent"; "moveUp"; "moveDown"; "lineBreak"; "newBlock" ]
    in
    let editing_uuid =
      Option.map (fun (editing : Model.outliner_editing) -> editing.editing_uuid)
        model.Model.outliner_editing
    in
    let structure_targets =
      match editing_uuid with
      | Some uuid -> [ uuid ]
      | None -> model.Model.outliner_selected_block_ids
    in
    if structural then
      (match action with
      | "indent" -> List.iter (fun uuid -> adjust_depth host uuid 1) structure_targets
      | "outdent" ->
        List.iter (fun uuid -> adjust_depth host uuid (-1)) structure_targets
      | "moveUp" -> List.iter (fun uuid -> move_row host uuid (-1)) structure_targets
      | "moveDown" -> List.iter (fun uuid -> move_row host uuid 1) structure_targets
      | "lineBreak" -> Drive_host.append_capture host id "Split block" ()
      | "newBlock" -> Drive_host.append_capture host id "New block" ()
      | _ -> ());
    Some
      (if action = "hideKeyboard" || clear_selection || Option.is_some autocomplete
          || structural
      then
         Model.DequeueEffect id
         :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
                let projection =
                  if clear_selection then
                    {
                      projection with
                      Model.projection_outliner_selected_block_ids = [];
                    }
                  else projection
                in
                match (model.Model.outliner_editing, autocomplete) with
                | Some editing, Some request ->
                  Drive_host.editing_snapshot ~uuid:editing.editing_uuid
                    ~title:editing.editing_title ~caret:editing.caret_utf16_offset
                    ~autocomplete:(Some request)
                    ~candidates:[ Drive_host.page_candidate ] projection
                | Some editing, None when structural ->
                  Drive_host.editing_snapshot ~uuid:editing.editing_uuid
                    ~title:editing.editing_title ~caret:editing.caret_utf16_offset
                    projection
                | _ -> projection)
         :: Drive_host.resolved id
       else Drive_host.resolved id)
  | Model.ChooseOutlinerAutocompleteEffect (id, _) ->
    Some
      (match model.Model.outliner_editing with
      | Some editing ->
        let title = "[[Alpha Doc]]" in
        host.rows <-
          List.map
            (fun (row : Model.outline_row) ->
              if row.row_uuid = editing.editing_uuid then { row with row_title = title }
              else row)
            host.rows;
        Model.DequeueEffect id
        :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
               Drive_host.editing_snapshot ~uuid:editing.editing_uuid ~title
                 ~caret:(String.length title) projection)
        :: Drive_host.resolved id
      | None -> Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.EditorOutlinerEventEffect (id, payload) ->
    Some
      (match
         ( Drive_host.json_string (Drive_host.json_fields payload) "type"
         , model.Model.outliner_editing )
       with
      | Some "dismissAutocomplete", Some editing ->
        host.Drive_host.completion_dismissed <- true;
        Model.DequeueEffect id
        :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
               Drive_host.editing_snapshot ~uuid:editing.editing_uuid
                 ~title:editing.editing_title ~caret:editing.caret_utf16_offset
                 projection)
        :: Drive_host.resolved id
      | _ -> Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.TapOutlinerBlockEffect (id, uuid) ->
    host.Drive_host.editing_title <- "";
    host.completion_dismissed <- false;
    Some
      (match selected_graph host model with
      | Some graph ->
        Model.DequeueEffect id
        :: Model.ApplyCoreSnapshot
             (Drive_host.editing_snapshot ~uuid ~title:"" ~caret:0
                (open_projection host graph))
        :: Drive_host.resolved id
      | None -> Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.ChangeOutlinerTextEffect (id, uuid, title, caret) ->
    let fresh =
      let bounded = max 0 (min caret (String.length title)) in
      let prefix = String.sub title 0 bounded in
      title <> host.Drive_host.editing_title
      && List.exists
           (fun suffix -> String.ends_with ~suffix prefix)
           [ "[["; "#"; "/" ]
    in
    let suggest =
      (not host.completion_dismissed || fresh)
      && (Drive_host.contains_substr title "[[" || fresh)
    in
    if fresh then host.completion_dismissed <- false;
    host.editing_title <- title;
    Some
      (match selected_graph host model with
      | Some graph ->
        Model.DequeueEffect id
        :: Model.ApplyCoreSnapshot
             (Drive_host.editing_snapshot ~uuid ~title ~caret
                ~autocomplete:
                  (if suggest then
                     Some
                       {
                         Model.autocomplete_kind = Model.NodeAutocomplete;
                         autocomplete_query = "Al";
                       }
                   else None)
                ~candidates:(if suggest then [ Drive_host.page_candidate ] else [])
                (open_projection host graph))
        :: Drive_host.resolved id
      | None -> Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.PasteOutlinerTextEffect (id, uuid, title, caret) ->
    Some
      (match selected_graph host model with
      | Some graph ->
        Drive_host.map_row host uuid (fun row -> { row with Model.row_title = title });
        Model.DequeueEffect id
        :: Model.ApplyCoreSnapshot
             (Drive_host.editing_snapshot ~uuid ~title ~caret (open_projection host graph))
        :: Drive_host.resolved id
      | None -> Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.BackspaceOutlinerEditorEffect (id, uuid, title, _selection) ->
    Some
      (match model.Model.outliner_editing with
      | Some editing ->
        Model.DequeueEffect id
        :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
               Drive_host.editing_snapshot ~uuid ~title ~caret:editing.caret_utf16_offset
                 projection)
        :: Drive_host.resolved id
      | None -> Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.MoveOutlinerCaretEffect (id, uuid, caret) ->
    let title = editing_title model uuid host.Drive_host.editing_title in
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             Drive_host.editing_snapshot ~uuid ~title ~caret projection)
      :: Drive_host.resolved id)
  | Model.DropOutlinerBlocksEffect (id, uuid, placement) ->
    let title =
      if placement = "before" then "Dropped before" else "Dropped after"
    in
    Drive_host.map_row host uuid (fun row -> { row with Model.row_title = title });
    Some (Model.DequeueEffect id :: snapshot_editor host model :: Drive_host.resolved id)
  | Model.SaveOutlinerEditingEffect (id, uuid) ->
    let title = editing_title model uuid host.Drive_host.editing_title in
    Drive_host.map_row host uuid (fun row -> { row with Model.row_title = title });
    Some (Model.DequeueEffect id :: snapshot_editor host model :: Drive_host.resolved id)
  | Model.CancelOutlinerEditingEffect id ->
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             projection)
      :: Drive_host.resolved id)
  | Model.SetOutlinerTaskPriorityEffect (id, uuid, priority) ->
    Drive_host.map_row host uuid (fun row -> { row with Model.row_priority = priority });
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             projection)
      :: Drive_host.resolved id)
  | Model.ResultViewEffect (id, _uuid, payload) ->
    let fields = Drive_host.json_fields payload in
    (match Drive_host.json_string fields "action" with
    | Some "setExpanded" ->
      Drive_host.set_query_expanded host
        (match List.assoc_opt "expanded" fields with
        | Some (`Bool value) -> value
        | _ -> true)
    | Some "save" ->
      let config = Drive_host.json_assoc fields "config" in
      (match Drive_host.json_string config "type" with
      | Some typ -> host.Drive_host.query_type <- typ
      | None -> ());
      if List.mem_assoc "filters" config then host.query_filtered <- true;
      if List.mem_assoc "sorting" config then host.query_sorted <- true;
      Drive_host.set_query_expanded host host.query_expanded
    | _ -> ());
    Some
      [ Model.DequeueEffect id
      ; Model.ApplyCoreSnapshot
          {
            (App_test.empty_core_projection ()) with
            Model.selected_graph_id = model.Model.selected_graph_id;
            query_update = Some ("query-block", Drive_host.live_query_json host);
          }
      ; Model.ResolveEffect (id, true, "") ]
  | Model.LoadResultRowsEffect (id, key, payload) when host.scenario = "query-retry.drive" ->
    Some
      [ Model.DequeueEffect id
      ; Model.ResolveEffect (id, false, "Could not load results") ]
  | Model.LoadResultRowsEffect (id, key, payload) ->
    let fields = Drive_host.json_fields payload in
    let input = Option.value (Drive_host.json_string fields "input") ~default:"" in
    let empty = host.scenario = "query-empty.drive" in
    let title =
      if host.query_filtered then "Filtered hit"
      else if host.query_sorted then "Sorted hit"
      else "Deferred query hit"
    in
    let rows =
      `Assoc
        [
          ("input", `String input);
          ("revision", `String "1");
          ("projectionRevision", `String "1");
          ("rowOffset", `Int 0);
          ("rowCount", `Int (if empty then 0 else 1));
          ( "rows"
          , if empty then `List []
            else
              `List
                [
                  `Assoc
                    [
                      ( "block"
                      , `Assoc
                          [
                            ("uuid", `String "query-hit");
                            ("title", `String title);
                            ("pageId", `String "journal");
                          ] );
                    ];
                ] );
        ]
    in
    Some
      [ Model.DequeueEffect id
      ; Model.ReceiveResultRows (key, Yojson.Basic.to_string rows, Lui_protocol.String_map.empty)
      ; Model.ResolveEffect (id, true, "") ]
  | Model.PdfAnnotationEffect (id, payload) ->
    let fields = Drive_host.json_fields payload in
    let graph = Option.value (Drive_host.json_string fields "graphId") ~default:"" in
    let asset = Option.value (Drive_host.json_string fields "assetUuid") ~default:"" in
    let note =
      if Drive_host.json_string fields "action" = Some "save" then "Noted paragraph"
      else ""
    in
    let highlights =
      if note = "" then `List []
      else `List [ `Assoc [ ("id", `String "hl-1"); ("text", `String note) ] ]
    in
    let update =
      Yojson.Basic.to_string
        (`Assoc
           [
             ("graphId", `String graph);
             ("assetUuid", `String asset);
             ("highlights", highlights);
             ("note", `String note);
           ])
    in
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             { projection with Model.pdf_update = Some update })
      :: Drive_host.resolved id)
  | Model.ReturnOutlinerEditorEffect (id, uuid, title, _caret) ->
    Some
      (match selected_graph host model with
      | Some graph ->
        host.rows <-
          List.map
            (fun (row : Model.outline_row) ->
              if row.row_uuid = uuid then { row with row_title = title } else row)
            host.rows;
        Model.DequeueEffect id
        :: Model.ApplyCoreSnapshot (open_projection host graph)
        :: Drive_host.resolved id
      | None -> Model.DequeueEffect id :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/outliner"
