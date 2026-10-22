open Lui_protocol

let patch_batches : patch_batch list ref = ref []

let take_patch () =
  match !patch_batches with
  | [] -> ""
  | [batch] -> patch_batches := []; Lui_wire.encode_batch batch
  | latest :: _ as batches ->
    (* Reentrant flushes can emit several batches. Preserve every operation
       in order while returning the final generation through the native ABI. *)
    patch_batches := [];
    let ops = List.fold_left (fun reversed batch -> List.rev_append batch.ops reversed)
      [] (List.rev batches) |> List.rev in
    Lui_wire.encode_batch {generation = latest.generation; ops}

let current_app :
    (Model.logseq_model, Model.logseq_action) Lui_app.reducer_app option ref =
  ref None

let operating_system platform_code =
  match platform_code with
  | 2 -> IOS
  | 3 -> AndroidOS
  | _ -> GenericOS

(* Matches the host-code table in lui's components_bridge.ml. *)
let host_kind = function
  | 1 -> WebHost
  | 2 -> SwiftUIHost
  | 4 -> KotlinHost
  | _ -> GenericHost

let app () =
  match !current_app with
  | Some value -> value
  | None -> invalid_arg "Logseq native runtime is not started"

let effect_deadlines = Hashtbl.create 8

let debounced_query = function
  | Model.SearchNodesEffect _ | Model.ChangeOutlinerTextEffect _
  | Model.MoveOutlinerCaretEffect _ -> true
  | _ -> false

let effect_delay_seconds eff = match eff with
  | Model.SaveOutlinerEditingEffect _ -> 1.
  | _ -> if debounced_query eff then 0.2 else 0.

let note_effect_deadlines () =
  let pending = (App.model (app ())).Model.pending_effects in
  let active = Hashtbl.create 8 in
  List.iter (fun eff ->
    if effect_delay_seconds eff > 0. then begin
      let id = Model.effect_id eff in
      Hashtbl.replace active id ();
      if not (Hashtbl.mem effect_deadlines id) then
        Hashtbl.add effect_deadlines id (Unix.gettimeofday () +. effect_delay_seconds eff)
    end) pending;
  Hashtbl.filter_map_inplace (fun id deadline ->
    if Hashtbl.mem active id then Some deadline else None) effect_deadlines

let flush_event event =
  patch_batches := [];
  ignore (Lui_app.dispatch_event (app ()) event);
  ignore (Lui_app.flush (app ()));
  note_effect_deadlines ();
  take_patch ()

let flush_action action =
  patch_batches := [];
  ignore (Lui_app.send (app ()) action);
  ignore (Lui_app.flush (app ()));
  note_effect_deadlines ();
  take_patch ()

let apply_response encoded =
  flush_action
    (match Response_snapshot.decode_response encoded with
     | Ok projection -> Model.ApplyCoreSnapshot projection
     | Error message -> Model.SyncFailed message)

let session_asset (asset : Host_update.host_composer_asset) :
    Model.composer_asset =
  { Model.uuid = asset.uuid;
    title = asset.title;
    local_path = asset.local_path;
    payload = asset.payload }

let host_action (update : Host_update.host_update) =
  match update with
  | Settings settings ->
    Model.ApplySettingsSnapshot
      { Model.appearance = settings.appearance;
        language = settings.language;
        spell_check = settings.spell_check;
        auto_correction = settings.auto_correction;
        sidebar_tabs = settings.sidebar_tabs;
        base_url = settings.base_url;
        version = settings.version;
        revision = settings.revision }
  | Runtime_log records ->
    Model.ApplyRuntimeLog
      (List.map
         (fun (entry : Host_update.host_runtime_log_record) ->
           { Model.id = entry.id;
             level = entry.level;
             source = entry.source;
             timestamp = entry.timestamp;
             message = entry.message })
         records)
  | Local_graph_ids ids -> Model.ApplyLocalGraphIds ids
  | Composer_asset asset -> Model.StageComposerAsset (session_asset asset)
  | Save_ui_session -> Model.SaveUISession
  | Restore_ui_session session ->
    Model.RestoreUISession
      { Model.graph_id = session.graph_id;
        destination =
          (match session.destination with
           | "flashcards" -> Model.FlashcardsDestination
           | "graphs" -> Model.GraphsDestination
           | _ -> Model.JournalsDestination);
        assets = List.map session_asset session.assets;
        composer_tags = List.map (fun (uuid, title) -> ({Model.uuid; title} : Model.sidebar_page)) session.composer_tags;
        composer_expanded = session.composer_expanded;
        search_open = session.search_open;
        query = session.query;
        app_path =
          List.map (fun uuid -> Model.NodeRoute uuid) session.app_path;
        search_path =
          List.map (fun uuid -> Model.NodeRoute uuid) session.search_path;
        selected_page_id = session.selected_page_id;
        settings_open = session.settings_open;
        recent_graph_ids = session.recent_graph_ids }
  | Composer_draft draft -> Model.ApplyComposerDraft draft
  | Graph_loading loading -> Model.ApplyGraphLoading loading
  | Authentication authentication ->
    Model.ApplyAuthentication
      (authentication.state, authentication.error_message)
  | Open_quick_action kind -> Model.OpenQuickAction kind
  | Confirm_outliner_delete -> Model.ConfirmOutlinerDelete
  | Open_capture -> Model.ExpandComposer
  | Open_node uuid -> Model.RequestAppNode uuid
  | Asset_preview_resolved (title, path) ->
    Model.ResolveAssetPreview (title, path)

let apply_host_update kind payload =
  flush_action
    (match Host_update.decode kind payload with
     | Ok update -> host_action update
     | Error message -> Model.SyncFailed message)

let encode_string_vector values =
  "[" ^ String.concat "," (List.map Lui_wire.quoted values) ^ "]"

let encode_option_string value =
  match value with
  | Some text -> Lui_wire.quoted text
  | None -> "null"

let encode_session_asset (asset : Model.composer_asset) =
  "{\"uuid\":" ^ Lui_wire.quoted asset.uuid ^ ",\"title\":"
  ^ Lui_wire.quoted asset.title ^ ",\"localPath\":"
  ^ Lui_wire.quoted asset.local_path ^ ",\"payload\":"
  ^ Lui_wire.quoted asset.payload ^ "}"

let encode_session_routes routes =
  encode_string_vector
    (List.map (fun (Model.NodeRoute uuid) -> uuid) routes)

let encode_ui_session (session : Model.ui_session) =
  "{\"graphId\":" ^ encode_option_string session.graph_id
  ^ ",\"destination\":"
  ^ Lui_wire.quoted
      (match session.destination with
       | Model.FlashcardsDestination -> "flashcards"
       | Model.GraphsDestination -> "graphs"
       | Model.JournalsDestination -> "journals")
  ^ ",\"assets\":["
  ^ String.concat "," (List.map encode_session_asset session.assets)
  ^ "]" ^ ",\"composerTags\":"
  ^ Yojson.Basic.to_string (`List (List.map (fun (tag : Model.sidebar_page) ->
    `Assoc ["uuid", `String tag.uuid; "title", `String tag.title]) session.composer_tags))
  ^ ",\"composerExpanded\":"
  ^ string_of_bool session.composer_expanded
  ^ ",\"searchOpen\":" ^ string_of_bool session.search_open
  ^ ",\"query\":" ^ Lui_wire.quoted session.query ^ ",\"appPath\":"
  ^ encode_session_routes session.app_path
  ^ ",\"searchPath\":"
  ^ encode_session_routes session.search_path
  ^ ",\"selectedPageId\":"
  ^ encode_option_string session.selected_page_id
  ^ ",\"settingsOpen\":" ^ string_of_bool session.settings_open
  ^ ",\"recentGraphIds\":" ^ encode_string_vector session.recent_graph_ids ^ "}"

let encode_task_status (status : Model.task_status) =
  "{\"uuid\":" ^ Lui_wire.quoted status.uuid ^ ",\"ident\":"
  ^ encode_option_string status.ident
  ^ ",\"title\":" ^ Lui_wire.quoted status.title ^ ",\"iconType\":"
  ^ encode_option_string status.icon_type
  ^ ",\"iconId\":" ^ encode_option_string status.icon_id
  ^ ",\"iconColor\":" ^ encode_option_string status.icon_color ^ "}"

let encode_asset_presentation title asset_type local_path =
  "{\"title\":" ^ Lui_wire.quoted title ^ ",\"assetType\":"
  ^ Lui_wire.quoted asset_type ^ ",\"localPath\":"
  ^ Lui_wire.quoted local_path ^ "}"

let encode_settings (settings : Model.settings_projection) =
  "{\"appearance\":" ^ Lui_wire.quoted settings.appearance
  ^ ",\"language\":" ^ Lui_wire.quoted settings.language
  ^ ",\"spellCheck\":" ^ string_of_bool settings.spell_check
  ^ ",\"autoCorrection\":" ^ string_of_bool settings.auto_correction
  ^ ",\"sidebarTabs\":" ^ encode_string_vector settings.sidebar_tabs
  ^ ",\"baseURL\":" ^ Lui_wire.quoted settings.base_url ^ "}"

let encode_runtime_log_record (record : Model.runtime_log_record) =
  "{\"id\":" ^ Lui_wire.quoted record.id ^ ",\"level\":"
  ^ Lui_wire.quoted record.level ^ ",\"source\":"
  ^ Lui_wire.quoted record.source ^ ",\"timestamp\":"
  ^ Lui_wire.quoted record.timestamp ^ ",\"message\":"
  ^ Lui_wire.quoted record.message ^ "}"

let encode_runtime_log_records records =
  "[" ^ String.concat "," (List.map encode_runtime_log_record records)
  ^ "]"

let encode_effect (eff : Model.logseq_effect) =
  match eff with
  | SendAssetEffect (id, asset, _, _) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"send-asset\",\"text\":"
    ^ Lui_wire.quoted asset.payload ^ "}"
  | LoadComposerTagsEffect (id, _) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"load-composer-tags\",\"text\":\"\"}"
  | SendTaggedCaptureEffect (id, capture) ->
    let status = match capture.capture_status with None -> `Null
      | Some status -> Yojson.Basic.from_string (encode_task_status status) in
    let payload = Yojson.Basic.to_string (`Assoc ["text", `String capture.capture_text;
      "tags", Model.composer_tag_selection capture.capture_tags; "status", status]) in
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"send-tagged\",\"text\":" ^ Lui_wire.quoted payload ^ "}"
  | SendCaptureEffect (id, text) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"send-capture\",\"text\":" ^ Lui_wire.quoted text ^ "}"
  | SendTaskEffect (id, text, status) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"send-task\",\"text\":" ^ Lui_wire.quoted text
    ^ ",\"metadata\":" ^ Lui_wire.quoted (encode_task_status status) ^ "}"
  | PersistUISessionEffect (id, session) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"persist-ui-session\",\"text\":"
    ^ Lui_wire.quoted (encode_ui_session session) ^ "}"
  | PersistComposerDraftEffect (id, draft) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"persist-composer-draft\",\"text\":"
    ^ Lui_wire.quoted draft ^ "}"
  | PresentJournalCalendarEffect id ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"present-journal-calendar\",\"text\":\"\"}"
  | PresentAttachmentEffect (id, kind) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"present-attachment\",\"text\":" ^ Lui_wire.quoted kind
    ^ "}"
  | PresentAssetEffect (id, title, asset_type, local_path) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"present-asset\",\"text\":\"\",\"metadata\":"
    ^ Lui_wire.quoted
        (encode_asset_presentation title asset_type local_path)
    ^ "}"
  | PresentPageShareEffect (id, text, paths) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"present-page-share\",\"text\":" ^ Lui_wire.quoted text
    ^ ",\"metadata\":"
    ^ Lui_wire.quoted (encode_string_vector paths)
    ^ "}"
  | SetPageFavoriteEffect (id, uuid, favorite) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"set-page-favorite\",\"text\":" ^ Lui_wire.quoted uuid
    ^ ",\"value\":" ^ (if favorite then "1" else "0") ^ "}"
  | DeletePageEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"delete-page\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | ResultViewEffect (id, _, payload) ->
    Yojson.Basic.to_string (`Assoc ["id", `Int id; "kind", `String "result-view"; "text", `String payload])
  | SetJournalTitleFormatEffect (id, payload) ->
    Yojson.Basic.to_string (`Assoc ["id", `Int id; "kind", `String "set-journal-title-format"; "text", `String payload])
  | NodePropertyEffect (id, _, payload) ->
    Yojson.Basic.to_string (`Assoc ["id", `Int id; "kind", `String "node-property"; "text", `String payload])
  | SyncNowEffect id ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"sync-now\",\"text\":\"\"}"
  | SyncPendingEffect id ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"sync-pending\",\"text\":\"\"}"
  | SetOutlinerTaskStatusEffect (id, block_id, status) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"set-outliner-task-status\",\"text\":"
    ^ Lui_wire.quoted block_id ^ ",\"metadata\":"
    ^ Lui_wire.quoted (encode_task_status status)
    ^ "}"
  | SetOutlinerTaskPriorityEffect (id, block_id, priority) ->
    Yojson.Basic.to_string (`Assoc ["id", `Int id; "kind", `String "set-outliner-task-priority";
      "text", `String block_id; "metadata", `String (Option.fold ~none:"null" ~some:encode_task_status priority)])
  | LoadPageReferencesEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"load-page-references\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | HydrateOutlinerRowsEffect (id, ids) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"hydrate-outliner-rows\",\"text\":"
    ^ Lui_wire.quoted (Yojson.Basic.to_string (`List (List.map (fun id -> `String id) ids))) ^ "}"
  | LoadSearchPageEffect (id, query, offset) ->
    Yojson.Basic.to_string (`Assoc ["id", `Int id; "kind", `String "load-search-page";
      "text", `String query; "value", `Int offset])
  | SearchNodesEffect (id, query) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"search-nodes\",\"text\":" ^ Lui_wire.quoted query ^ "}"
  | TapOutlinerBlockEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"tap-outliner-block\",\"text\":" ^ Lui_wire.quoted uuid
    ^ "}"
  | EditorOutlinerEventEffect (id, payload) ->
    Yojson.Basic.to_string (`Assoc ["id", `Int id; "kind", `String "editor-outliner-event"; "text", `String payload])
  | PasteOutlinerTextEffect (id, uuid, title, caret) ->
    Yojson.Basic.to_string (`Assoc ["id", `Int id; "kind", `String "paste-outliner-text";
      "text", `String title; "uuid", `String uuid; "value", `Int caret])
  | ChangeOutlinerTextEffect (id, uuid, title, caret) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"change-outliner-text\",\"text\":"
    ^ Lui_wire.quoted title ^ ",\"uuid\":" ^ Lui_wire.quoted uuid
    ^ ",\"value\":" ^ string_of_int caret ^ "}"
  | ReturnOutlinerEditorEffect (id, uuid, title, caret) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"return-outliner-editor\",\"text\":"
    ^ Lui_wire.quoted title ^ ",\"uuid\":" ^ Lui_wire.quoted uuid
    ^ ",\"value\":" ^ string_of_int caret ^ "}"
  | BackspaceOutlinerEditorEffect (id, uuid, title, selection_length) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"backspace-outliner-editor\",\"text\":"
    ^ Lui_wire.quoted title ^ ",\"uuid\":" ^ Lui_wire.quoted uuid
    ^ ",\"value\":" ^ string_of_int selection_length ^ "}"
  | MoveOutlinerCaretEffect (id, uuid, caret) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"move-outliner-caret\",\"text\":\"\",\"uuid\":"
    ^ Lui_wire.quoted uuid ^ ",\"value\":" ^ string_of_int caret ^ "}"
  | ToggleOutlinerCollapsedEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"toggle-outliner-collapsed\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | LongPressOutlinerBlockEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"long-press-outliner-block\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | DropOutlinerBlocksEffect (id, target_uuid, placement) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"drop-outliner-blocks\",\"text\":"
    ^ Lui_wire.quoted target_uuid ^ ",\"metadata\":"
    ^ Lui_wire.quoted placement ^ "}"
  | OutlinerToolbarEffect (id, action) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"outliner-toolbar\",\"text\":" ^ Lui_wire.quoted action
    ^ "}"
  | ChooseOutlinerAutocompleteEffect (id, value) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"choose-outliner-autocomplete\",\"text\":"
    ^ Lui_wire.quoted value ^ "}"
  | ConfirmOutlinerDeleteEffect id ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"confirm-outliner-delete\",\"text\":\"\"}"
  | SaveOutlinerEditingEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"save-outliner-editing\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | CancelOutlinerEditingEffect id ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"cancel-outliner-editing\",\"text\":\"\"}"
  | OpenSearchResultEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"open-search-result\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | OpenAppNodeEffect (id, uuid) | OpenSearchNodeEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"open-node\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | CloseAppNodeEffect (id, uuid) | CloseSearchNodeEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"close-node\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | AddRootBlockEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"add-root-block\",\"text\":"
    ^ Lui_wire.quoted uuid ^ "}"
  | SelectSidebarPageEffect (id, uuid) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"select-sidebar-page\",\"text\":" ^ Lui_wire.quoted uuid
    ^ "}"
  | ClearSelectedPageEffect id ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"clear-selected-page\",\"text\":\"\"}"
  | LoadOlderJournalsEffect id ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"load-older-journals\",\"text\":\"\"}"
  | LoadFlashcardsEffect id ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"load-flashcards\",\"text\":\"\"}"
  | ReviewFlashcardEffect (id, uuid, rating) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"review-flashcard\",\"text\":" ^ Lui_wire.quoted rating
    ^ ",\"uuid\":" ^ Lui_wire.quoted uuid ^ "}"
  | RefreshGraphsEffect id ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"refresh-graphs\",\"text\":\"\"}"
  | OpenGraphEffect (id, graph_id) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"open-graph\",\"text\":"
    ^ Lui_wire.quoted graph_id ^ "}"
  | UnlockGraphEffect (id, password) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"unlock-graph\",\"text\":"
    ^ Lui_wire.quoted password ^ "}"
  | CreateGraphEffect (id, name, is_encrypted, password) ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"create-graph\",\"text\":"
    ^ Lui_wire.quoted name ^ ",\"value\":"
    ^ (if is_encrypted then "1" else "0")
    ^ ",\"metadata\":" ^ Lui_wire.quoted password ^ "}"
  | DeleteLocalGraphEffect (id, graph_id) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"delete-local-graph\",\"text\":"
    ^ Lui_wire.quoted graph_id ^ "}"
  | SaveSettingsEffect (id, settings) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"save-settings\",\"text\":"
    ^ Lui_wire.quoted (encode_settings settings) ^ "}"
  | ExportGraphDatabaseEffect id ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"export-graph-database\",\"text\":\"\"}"
  | OpenExternalURLEffect (id, url) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"open-external-url\",\"text\":" ^ Lui_wire.quoted url
    ^ "}"
  | RefreshRuntimeLogEffect (id, source, errors_only, newest_first) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"refresh-runtime-log\",\"text\":"
    ^ Lui_wire.quoted source ^ ",\"value\":"
    ^ string_of_int
        ((if errors_only then 1 else 0) + if newest_first then 2 else 0)
    ^ "}"
  | CopyRuntimeLogEffect (id, records) ->
    "{\"id\":" ^ string_of_int id
    ^ ",\"kind\":\"copy-runtime-log\",\"text\":"
    ^ Lui_wire.quoted (encode_runtime_log_records records) ^ "}"
  | SignInEffect id ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"sign-in\",\"text\":\"\"}"
  | SignOutEffect id ->
    "{\"id\":" ^ string_of_int id ^ ",\"kind\":\"sign-out\",\"text\":\"\"}"

let encode_effect_dispatch eff patch =
  "{\"effect\":" ^ encode_effect eff ^ ",\"patch\":"
  ^ Lui_wire.quoted patch ^ "}"

let take_effect () =
  let effects = (App.model (app ())).pending_effects in
  let independent = function
    | Model.HydrateOutlinerRowsEffect _ | Model.PersistUISessionEffect _ -> true
    | _ -> false in
  let urgent = List.exists (fun eff ->
    not (independent eff) && not (debounced_query eff)
    && (match eff with Model.SaveOutlinerEditingEffect _ -> false | _ -> true)) effects in
  let now = Unix.gettimeofday () in
  let remaining eff =
    let waits = match eff with Model.SaveOutlinerEditingEffect _ -> true | _ -> debounced_query eff && not urgent in
    if waits then max 0. (Option.value ~default:now
      (Hashtbl.find_opt effect_deadlines (Model.effect_id eff)) -. now)
    else 0. in
  match effects with
  | [] -> ""
  | _ ->
    match List.find_opt (fun eff -> remaining eff <= 0.) effects with
    | Some eff ->
      let patch = flush_action (Model.DequeueEffect (Model.effect_id eff)) in
      encode_effect_dispatch eff patch
    | None ->
      let delay = List.fold_left (fun delay eff -> min delay (remaining eff)) 0.2 effects in
      Printf.sprintf "{\"waitMs\":%d}" (max 1 (int_of_float (ceil (delay *. 1000.))))

let resolve_effect id succeeded message =
  flush_action (Model.ResolveEffect (id, succeeded, message))

let initial_authentication_state authentication_code =
  match authentication_code with
  | 1 -> "signedOut"
  | 2 -> "signingIn"
  | 3 -> "signedIn"
  | 4 -> "signingOut"
  | _ -> "restoring"

let backend host_profile =
  {
    backend_profile = host_profile;
    apply_batch =
      (fun batch ->
         patch_batches := batch :: !patch_batches;
         true);
  }

let start_application application =
  Hashtbl.clear effect_deadlines;
  current_app := Some application;
  ignore (Lui_app.start application);
  ignore (Lui_app.flush application);
  take_patch ()

let initialize platform_code host_code authentication_code =
  patch_batches := [];
  let authentication_state =
    initial_authentication_state authentication_code
  in
  start_application
    (App.create_with_authentication
       (backend
          (profile (operating_system platform_code) (host_kind host_code)))
       authentication_state)

let linked () = true

let press node = flush_event (Press node)

let appear node = flush_event (Appear node)

let long_press node = flush_event (LongPress node)

let text_changed node text = flush_event (TextChanged (node, text))

let submit node = flush_event (Submit node)

let toggle_changed node checked = flush_event (ToggleChanged (node, checked))

let change node = flush_event (Change node)

let value_changed node value = flush_event (ValueChanged (node, value))

let dismiss node = flush_event (Dismiss node)

let double_press node = flush_event (DoublePress node)

let picked node payload = flush_event (Picked (node, payload))

let visible_range node first last =
  flush_event (VisibleRange (node, first, last))

let scroll_completed node token outcome =
  flush_event (ScrollCompleted (node, token, outcome))

let extension_event node identifier name text value =
  let open Lui_protocol in
  let values =
    match identifier, name with
    | "outliner-block-row", "set-priority" -> ["priority", StringValue text]
    | "outliner-block-row", "set-status" -> ["uuid", StringValue text; "count", IntValue value]
    | "outliner-block-row", "drop" -> ["uuid", StringValue text; "placement", StringValue
        (match value with 0 -> "before" | 1 -> "inside" | _ -> "after")]
    | "outliner-block-row", _ -> ["uuid", StringValue text]
    | "outliner-block-content", "open-node"
    | "outliner-block-content", "drag-start"
    | "outliner-block-content", "edit" ->
      [ "uuid", StringValue text ]
    | "outliner-block-content", "drop" ->
      [
        "uuid", StringValue text;
        ( "placement",
          StringValue
            (match value with
             | 0 -> "before"
             | 1 -> "inside"
             | _ -> "after") );
      ]
    | _, "paste-content" -> ["value", StringValue text]
    | _, ("text-change" | "paste" | "return") ->
      [
        "title", StringValue text;
        "caret-utf16-offset", IntValue value;
      ]
    | _, "backspace" ->
      [ "title", StringValue text; "selection-length", IntValue value ]
    | _, "caret-change" -> [ "caret-utf16-offset", IntValue value ]
    | "native-property-date", "change" -> ["value", StringValue text]
    | _, "query-changed" -> [ "query", StringValue text ]
    | "native-navigation-stack", "viewport-changed" -> [ "width", IntValue value ]
    | _, "back" -> [ "count", IntValue value ]
    | _ -> []
  in
  let value_map =
    List.fold_left
      (fun acc (key, value) -> Lui_protocol.String_map.add key value acc)
      Lui_protocol.String_map.empty values
  in
  flush_event (ExtensionEvent (node, identifier, name, value_map))

let dispose () =
  patch_batches := [];
  ignore (Lui_app.dispose (app ()));
  current_app := None;
  take_patch ()

let root_node () = Lui_app.root_node (app ())

let () =
  Callback.register "logseq_lui_init" initialize;
  Callback.register "logseq_lui_appear" appear;
  Callback.register "logseq_lui_press" press;
  Callback.register "logseq_lui_long_press" long_press;
  Callback.register "logseq_lui_text_changed" text_changed;
  Callback.register "logseq_lui_submit" submit;
  Callback.register "logseq_lui_toggle_changed" toggle_changed;
  Callback.register "logseq_lui_change" change;
  Callback.register "logseq_lui_value_changed" value_changed;
  Callback.register "logseq_lui_dismiss" dismiss;
  Callback.register "logseq_lui_double_press" double_press;
  Callback.register "logseq_lui_picked" picked;
  Callback.register "logseq_lui_visible_range" visible_range;
  Callback.register "logseq_lui_scroll_completed" scroll_completed;
  Callback.register "logseq_lui_extension_event" extension_event;
  Callback.register "logseq_lui_dispose" dispose;
  Callback.register "logseq_lui_root_node" root_node;
  Callback.register "logseq_lui_take_effect" take_effect;
  Callback.register "logseq_lui_resolve_effect" resolve_effect;
  Callback.register "logseq_lui_apply_snapshot" apply_response;
  Callback.register "logseq_lui_apply_host_update" apply_host_update
