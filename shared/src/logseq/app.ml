let diagnostic_errors (current : Model.logseq_model) =
  let messages = ref [] in
  let add = function
    | Some message when String.trim message <> "" -> messages := message :: !messages
    | _ -> () in
  List.iter add [current.effect_error; current.authentication_error];
  let add_sync_error = function
    | Some message when not (Model.sync_error_is_offline message) -> add (Some message)
    | _ -> () in
  add_sync_error current.pending_sync_error;
  (match current.sync_state with Model.FailedState message -> add_sync_error (Some message) | _ -> ());
  List.iter (fun (_, _, message) -> add message) current.result_view_feedback;
  let rec json_errors = function
    | `Assoc fields -> List.iter (fun (key, value) ->
      match key, value with
      | "error", `String message -> add (Some message)
      | _ -> json_errors value) fields
    | `List values -> List.iter json_errors values
    | _ -> () in
  let metadata value =
    if value <> "" then try json_errors (Yojson.Basic.from_string value)
      with Yojson.Json_error message -> add (Some ("Invalid view metadata: " ^ message)) in
  List.iter metadata [current.result_views_json; current.properties_json; current.flashcard_decks_json];
  List.iter (fun rows -> List.iter (fun (row : Model.outline_row) -> metadata row.query_json) rows)
    [current.outliner_rows; current.navigation_root_rows; current.journal_outliner_rows;
     current.related_rows; current.linked_reference_rows];
  List.iter (fun (route : Model.node_projection) ->
    metadata route.node_result_views_json; metadata route.node_properties_json) current.app_navigation_previews;
  List.iter (fun (_, value) -> metadata value) current.property_value_catalogs;
  List.iter (fun (_, value) -> metadata value) current.result_row_windows;
  List.rev !messages

let update current action =
  let updated = Model.update current action in
  let query_snapshot = match action with
    | Model.ApplyCoreSnapshot projection -> projection.Model.query_update <> None
      || List.exists (fun (row : Model.outline_row) -> row.query_json <> "") projection.outliner_rows
    | _ -> false in
  let changed = query_snapshot || current.Model.effect_error <> updated.effect_error
    || current.authentication_error <> updated.authentication_error
    || current.pending_sync_error <> updated.pending_sync_error
    || current.sync_state <> updated.sync_state
    || current.result_view_feedback != updated.result_view_feedback
    || current.result_views_json != updated.result_views_json
    || current.properties_json != updated.properties_json
    || current.flashcard_decks_json != updated.flashcard_decks_json
    || current.app_navigation_previews != updated.app_navigation_previews
    || current.property_value_catalogs != updated.property_value_catalogs
    || current.result_row_windows != updated.result_row_windows in
  let failed = match action with Model.ResolveEffect (_, false, _) -> true | _ -> false in
  if not changed && not failed then updated else
  let previous = Hashtbl.create 8 in
  List.iter (fun message -> Hashtbl.replace previous message ()) (diagnostic_errors current);
  let fresh = Hashtbl.create 8 in
  let messages = match action with
    | Model.ResolveEffect (id, false, message) ->
      (match Model.effect_with_id current.in_flight_effects id with
       | Some (Model.SignInEffect _) | Some (Model.ReportErrorEffect _)
       | Some (Model.PushPreferenceEffect _) | None -> diagnostic_errors updated
       | Some (Model.CreateGraphEffect _) when updated.new_graph_password_required -> diagnostic_errors updated
       | Some _ -> message :: diagnostic_errors updated)
    | _ -> diagnostic_errors updated in
  let reports, next_id = List.fold_left (fun (reports, id) message ->
    let repeated_failure = match action with Model.ResolveEffect (_, false, failed) -> message = failed | _ -> false in
    if String.trim message = "" || Hashtbl.mem fresh message
       || (Hashtbl.mem previous message && not repeated_failure) then reports, id
    else begin
      Hashtbl.add fresh message ();
      Model.ReportErrorEffect (id, message) :: reports, id + 1
    end) ([], updated.next_effect_id) messages in
  match reports with
  | [] -> updated
  | _ -> { updated with next_effect_id = next_id;
      pending_effects = List.rev_append (List.rev updated.pending_effects) (List.rev reports) }

let ui_silent_resolved_effect = function
  | Model.SyncPendingEffect _ | Model.PersistUISessionEffect _
  | Model.HydrateOutlinerRowsEffect _ | Model.MoveOutlinerCaretEffect _
  | Model.SaveOutlinerEditingEffect _ | Model.MaintainSearchIndexEffect _ -> true
  | _ -> false

let make_app backend initial_model =
  let ui_version = ref 0 in
  let seen_version = ref 0 in
  let reducer current action =
    let next = update current action in
    let silent =
      next == current
      || match action with
         | Model.DequeueEffect _ -> true
         | Model.ReturnOutlinerEditor _ ->
           Option.map (fun (e : Model.outliner_editing) -> e.editing_uuid) next.Model.outliner_editing =
           Option.map (fun (e : Model.outliner_editing) -> e.editing_uuid) current.Model.outliner_editing
           && next.effect_error = current.effect_error
         | Model.ResolveEffect (id, true, _) ->
           (match Model.effect_with_id current.in_flight_effects id with
            | Some eff ->
              ui_silent_resolved_effect eff
              && next.outliner_selection_revision = current.outliner_selection_revision
              && next.pending_effects == current.pending_effects
              && next.effect_error = current.effect_error
            | None -> true)
         | _ -> false in
    if not silent then incr ui_version;
    next in
  let view context model_source send =
    let gated = Signal.own_signal context.Lui_ui.ui_scope
      (Signal.cutoff (fun _ _ ->
        let v = !ui_version in
        if v = !seen_version then true
        else (seen_version := v; false)) model_source) in
    View.logseq_view context gated send in
  Lui_app.create_with_extensions backend (View.extension_registry ())
    initial_model reducer view

let create backend =
  make_app backend (Model.initial ())

let create_with_authentication backend authentication_state =
  make_app backend
    (update (Model.initial ())
       (Model.ApplyAuthentication (authentication_state, None)))

let model application = Lui_app.model application
