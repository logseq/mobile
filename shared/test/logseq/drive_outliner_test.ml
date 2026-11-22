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

let handle (host : Drive_host.host) model = function
  | Model.AddRootBlockEffect (id, _page_uuid) ->
    Drive_host.append_capture host id "New block" ();
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             projection)
      :: Drive_host.resolved id)
  | Model.DeleteBlockEffect (id, uuid, _) ->
    host.rows <-
      List.filter (fun (row : Model.outline_row) -> row.row_uuid <> uuid) host.rows;
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             {
               projection with
               Model.projection_outliner_selected_block_ids = [];
             })
      :: Drive_host.resolved id)
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
    Some
      (if action = "unselect" || Option.is_some autocomplete then
         Model.DequeueEffect id
         :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
                let projection =
                  if action = "unselect" then
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
      | None -> [ Model.DequeueEffect id ])
  | Model.EditorOutlinerEventEffect (id, payload) ->
    Some
      (match
         ( Drive_host.json_string (Drive_host.json_fields payload) "type"
         , model.Model.outliner_editing )
       with
      | Some "dismissAutocomplete", Some editing ->
        Model.DequeueEffect id
        :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
               Drive_host.editing_snapshot ~uuid:editing.editing_uuid
                 ~title:editing.editing_title ~caret:editing.caret_utf16_offset
                 projection)
        :: Drive_host.resolved id
      | _ -> [ Model.DequeueEffect id; Model.ResolveEffect (id, true, "") ])
  | Model.TapOutlinerBlockEffect (id, uuid) ->
    Some
      (match selected_graph host model with
      | Some graph ->
        Model.DequeueEffect id
        :: Model.ApplyCoreSnapshot
             (Drive_host.editing_snapshot ~uuid ~title:"" ~caret:0
                (open_projection host graph))
        :: Drive_host.resolved id
      | None -> [ Model.DequeueEffect id ])
  | Model.ChangeOutlinerTextEffect (id, uuid, title, caret) ->
    Some
      (match selected_graph host model with
      | Some graph ->
        let referencing = Drive_host.contains_substr title "[[" in
        Model.DequeueEffect id
        :: Model.ApplyCoreSnapshot
             (Drive_host.editing_snapshot ~uuid ~title ~caret
                ~autocomplete:
                  (if referencing then
                     Some
                       {
                         Model.autocomplete_kind = Model.NodeAutocomplete;
                         autocomplete_query = "Al";
                       }
                   else None)
                ~candidates:
                  (if referencing then [ Drive_host.page_candidate ] else [])
                (open_projection host graph))
        :: Drive_host.resolved id
      | None -> [ Model.DequeueEffect id ])
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
      | None -> [ Model.DequeueEffect id ])
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/outliner"
