open Test_util
module J = Yojson.Basic
module U = Yojson.Basic.Util

let member = U.member
let kind dispatch = match dispatch with
  | "" -> ""
  | body -> (try member "effect" (J.from_string body) |> member "kind" |> U.to_string with _ -> "wait")
let effect_id dispatch = member "effect" (J.from_string dispatch) |> member "id" |> U.to_int
let pending_kinds () = List.map (fun eff ->
  member "kind" (J.from_string (Native_bridge.encode_effect eff)) |> U.to_string)
  (App.model (Native_bridge.app ())).Model.pending_effects
let send action = ignore (Native_bridge.flush_action action)

let call session event = Rpc_session.call session
  (J.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "outlinerEvent"; "payload", `String (J.to_string (`Assoc event))]]))

let with_editor run =
  let original = { (Cache_model.local_block "editing" "Before" "page" (Some "page") 1) with
    Cache_model.order = Some "a0"; sync_status = "synced" } in
  let saved = ref original in
  let session = Rpc_session.create_session
    { Rpc_session.default_options with
      graph_blocks = Some (fun () -> Some [!saved]);
      authoritative_graph_blocks = Some (fun () -> Some [!saved]);
      sync_cursor = Some (fun () -> Some 41);
      stage_operation = Some (fun operation ->
        (match operation.Pending_ops.intent with
         | Pending_ops.Save_title value -> saved := { !saved with Cache_model.title = value.title }
         | _ -> ()); Ok ());
      prepare_operation = Some (fun operation -> Ok (Pending_ops.outliner_op operation.Pending_ops.intent, "[]")) } in
  ignore (Rpc_session.call session
    {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"http://localhost\",\"graphId\":\"plain-1\",\"token\":\"access\"}"}}|});
  ignore (Native_bridge.initialize 2 2 3);
  ignore (Native_bridge.apply_response (call session ["type", `String "tapBlock"; "uuid", `String "editing"]));
  Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ())) (fun () -> run session saved)

let take_ready () =
  let deadline = Unix.gettimeofday () +. 2. in
  let rec loop () =
    let dispatch = Native_bridge.take_effect () in
    if kind dispatch <> "wait" then dispatch
    else begin
      check ~msg:"core deadlines eventually dispatch" (Unix.gettimeofday () < deadline);
      let wait = U.member "waitMs" (J.from_string dispatch) |> U.to_int in
      Unix.sleepf (float_of_int wait /. 1000.);
      loop ()
    end in
  loop ()

let apply_effect session dispatch event =
  let response = call session event in
  ignore (Native_bridge.apply_response response);
  ignore (Native_bridge.resolve_effect (effect_id dispatch) true response)

let type_text session title =
  send (Model.ChangeOutlinerText ("editing", title, String.length title));
  let dispatch = take_ready () in
  check_eq (kind dispatch) "change-outliner-text";
  apply_effect session dispatch ["type", `String "textChanged"; "title", `String title;
    "caretUTF16Offset", `Int (String.length title)]

let idle_save_commits_once_then_wakes_sync () = with_editor (fun session saved ->
  type_text session "After";
  check_eq (!saved).Cache_model.title "Before";
  check_eq ~msg:"the core emits an explicit deadline before autosave" (kind (Native_bridge.take_effect ())) "wait";
  let save = take_ready () in
  check_eq (kind save) "save-outliner-editing";
  apply_effect session save ["type", `String "saveEditing"];
  check_eq (!saved).Cache_model.title "After";
  let sync = take_ready () in
  check_eq ~msg:"shared save policy wakes pending sync" (kind sync) "sync-pending";
  ignore (Native_bridge.resolve_effect (effect_id sync) true "");
  check_eq (Native_bridge.take_effect ()) "")

let autocomplete_suppresses_idle_save () = with_editor (fun session saved ->
  type_text session "#";
  check_eq (pending_kinds ()) [];
  check_eq (Native_bridge.take_effect ()) "";
  check_eq (!saved).Cache_model.title "Before")

let completion_resumes_the_save_deadline () = with_editor (fun session _ ->
  type_text session "[[";
  check_eq (pending_kinds ()) [];
  send (Model.ChooseOutlinerAutocomplete "Another");
  let choice = take_ready () in
  check_eq (kind choice) "choose-outliner-autocomplete";
  apply_effect session choice ["type", `String "chooseAutocomplete"; "value", `String "Another"];
  check ~msg:"completed input gets a shared save deadline"
    (List.mem "save-outliner-editing" (pending_kinds ())))

let newer_text_replaces_deadline_and_stale_resolution () = with_editor (fun session _ ->
  type_text session "First";
  let old_save = List.find (fun eff ->
    member "kind" (J.from_string (Native_bridge.encode_effect eff)) = `String "save-outliner-editing")
    (App.model (Native_bridge.app ())).Model.pending_effects in
  send (Model.ChangeOutlinerText ("editing", "Second", 6));
  check ~msg:"new input removes the old save" (not (List.mem "save-outliner-editing" (pending_kinds ())));
  ignore (Native_bridge.resolve_effect (Model.effect_id old_save) true "stale");
  let input = take_ready () in
  apply_effect session input ["type", `String "textChanged"; "title", `String "Second"; "caretUTF16Offset", `Int 6];
  check_eq (pending_kinds ()) ["save-outliner-editing"];
  check ~msg:"the new deadline has its own token"
    (Model.effect_id (List.hd (App.model (Native_bridge.app ())).Model.pending_effects) <> Model.effect_id old_save))

let structural_input_cancels_save_without_waiting () =
  List.iter (fun action -> with_editor (fun session _ ->
    type_text session "Draft";
    send action;
    check ~msg:"structure operations cancel the old save" (not (List.mem "save-outliner-editing" (pending_kinds ())));
    check ~msg:"structure operations are immediately dispatchable" (kind (Native_bridge.take_effect ()) <> "wait")))
    [Model.ReturnOutlinerEditor ("editing", "Draft", 5);
     Model.BackspaceOutlinerEditor ("editing", "Draft", 0);
     Model.BeginOutlinerEdit "another";
     Model.SelectSidebarPage "another"]

let caret_and_hydration_keep_the_save_deadline () = with_editor (fun session _ ->
  type_text session "Draft";
  let save_id = Model.effect_id (List.hd (App.model (Native_bridge.app ())).Model.pending_effects) in
  send (Model.MoveOutlinerCaret ("editing", 2));
  send (Model.EnsureOutlinerRows ["editing"]);
  check ~msg:"transient native caret and viewport updates retain the save token"
    (List.exists (fun eff -> Model.effect_id eff = save_id)
      (App.model (Native_bridge.app ())).Model.pending_effects);
  check_eq (kind (Native_bridge.take_effect ())) "hydrate-outliner-rows";
  let caret = take_ready () in
  check_eq ~msg:"caret input is not blocked behind a later autosave" (kind caret) "move-outliner-caret";
  check_eq (kind (Native_bridge.take_effect ())) "wait")

let late_text_resolution_after_navigation_does_not_arm_save () = with_editor (fun session _ ->
  send (Model.ChangeOutlinerText ("editing", "Draft", 5));
  let input = take_ready () in
  send (Model.SelectSidebarPage "another");
  apply_effect session input ["type", `String "textChanged"; "title", `String "Draft"; "caretUTF16Offset", `Int 5];
  check ~msg:"a late response cannot schedule a save on another route"
    (not (List.mem "save-outliner-editing" (pending_kinds ()))))

let platform_delete_confirmation_uses_shared_effects () = with_editor (fun session _ ->
  ignore (Native_bridge.apply_response (call session ["type", `String "cancelEditing"]));
  ignore (Native_bridge.apply_response (call session ["type", `String "longPressBlock"; "uuid", `String "editing"]));
  ignore (Native_bridge.apply_response (call session ["type", `String "toolbar"; "action", `String "delete"]));
  ignore (Native_bridge.apply_host_update "confirm-outliner-delete" "null");
  let dispatch = take_ready () in
  check_eq (kind dispatch) "confirm-outliner-delete";
  apply_effect session dispatch ["type", `String "confirmDelete"];
  check ~msg:"platform confirmations use the core mutation sync policy"
    (List.mem "sync-pending" (pending_kinds ())))

let externally_restored_pending_work_wakes_sync_once () = with_editor (fun session _ ->
  ignore (call session ["type", `String "textChanged"; "title", `String "Restored"; "caretUTF16Offset", `Int 8]);
  let response = call session ["type", `String "saveEditing"] in
  ignore (Native_bridge.apply_response response);
  check_eq ~msg:"external core responses share the mutation wake policy" (pending_kinds ()) ["sync-pending"];
  ignore (Native_bridge.apply_response response);
  check_eq (pending_kinds ()) ["sync-pending"];
  let sync = take_ready () in
  ignore (Native_bridge.apply_response response);
  check_eq ~msg:"an active sync pump owns its remaining operations" (pending_kinds ()) [];
  ignore (Native_bridge.resolve_effect (effect_id sync) true response))

let full_pending_responses_do_not_restart_a_completed_pump () = with_editor (fun session _ ->
  ignore (call session ["type", `String "textChanged"; "title", `String "Draft"; "caretUTF16Offset", `Int 5]);
  ignore (Native_bridge.apply_response (call session ["type", `String "saveEditing"]));
  let sync = take_ready () in
  check_eq (kind sync) "sync-pending";
  ignore (Native_bridge.resolve_effect (effect_id sync) true "");
  let dispatch action payload = Rpc_session.call session (J.to_string (`Assoc [
    "apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String action; "payload", `String payload;
      "projection", `String "snapshot"]])) in
  let started = dispatch "beginPendingSync" "" in
  ignore (Native_bridge.apply_response started);
  check_eq ~msg:"the pump's own full snapshots cannot request another pump" (pending_kinds ()) [];
  let id = member "result" (J.from_string started) |> member "pendingSyncRequest" |> member "id" in
  let failed = dispatch "completePendingSync" (J.to_string (`Assoc [
    "id", id; "status", `Int 403; "body", `String "denied"; "error", `Null])) in
  ignore (Native_bridge.apply_response failed);
  check_eq ~msg:"a permanent failure cannot bypass the retry budget through snapshot wakeups" (pending_kinds ()) [])

let toolbar_actions_that_keep_editing_preserve_autosave () =
  List.iter (fun action -> with_editor (fun session saved ->
    type_text session "Draft";
    let before = List.find (function Model.SaveOutlinerEditingEffect _ -> true | _ -> false)
      (App.model (Native_bridge.app ())).Model.pending_effects in
    send (Model.PerformOutlinerToolbarAction action);
    check ~msg:(action ^ " retains the current save deadline")
      (List.exists (fun pending -> Model.effect_id pending = Model.effect_id before)
        (App.model (Native_bridge.app ())).Model.pending_effects);
    let toolbar = take_ready () in
    check_eq (kind toolbar) "outliner-toolbar";
    apply_effect session toolbar ["type", `String "toolbar"; "action", `String action];
    let rec next_save () =
      let pending = take_ready () in
      if kind pending = "sync-pending" then next_save () else pending in
    let save = next_save () in
    check_eq (kind save) "save-outliner-editing";
    apply_effect session save ["type", `String "saveEditing"];
    check_eq ~msg:(action ^ " cannot strand the draft") (!saved).Cache_model.title "Draft"))
    ["indent"; "outdent"; "moveUp"; "moveDown"; "task"; "camera"; "audio"; "attachment"]

let an_old_noop_save_cannot_mark_newer_typing_synced () = with_editor (fun session _ ->
  ignore (Native_bridge.apply_response (Rpc_session.call session
    {|{"apiVersion":1,"method":"dispatch","params":{"action":"startWebSocket"}}|}));
  type_text session "Before";
  let save = take_ready () in
  check_eq (kind save) "save-outliner-editing";
  send (Model.ChangeOutlinerText ("editing", "New draft", 9));
  apply_effect session save ["type", `String "saveEditing"];
  check_eq ~msg:"a save acknowledgement cannot hide newer native input"
    (App.model (Native_bridge.app ())).Model.sync_state Model.SyncingState;
  check ~msg:"new input remains dispatchable" (kind (take_ready ()) = "change-outliner-text"))

let backspace_without_a_merge_target_still_saves_the_draft () = with_editor (fun session saved ->
  type_text session "Draft";
  let revision = (App.model (Native_bridge.app ())).Model.outliner_selection_revision in
  send (Model.BackspaceOutlinerEditor ("editing", "Draft", 0));
  let backspace = take_ready () in
  check_eq (kind backspace) "backspace-outliner-editor";
  apply_effect session backspace ["type", `String "backspacePressed"; "uuid", `String "editing";
    "title", `String "Draft"; "selectionLength", `Int 0];
  check_eq ~msg:"a no-op backspace acknowledges the native editor handoff"
    (App.model (Native_bridge.app ())).Model.outliner_selection_revision (revision + 1);
  check ~msg:"a structural no-op cannot cancel the final save" (List.mem "save-outliner-editing" (pending_kinds ()));
  let save = take_ready () in
  check_eq (kind save) "save-outliner-editing";
  apply_effect session save ["type", `String "saveEditing"];
  check_eq (!saved).Cache_model.title "Draft")

let failed_structural_input_releases_the_native_handoff () =
  List.iter (fun action -> with_editor (fun _ _ ->
    let revision = (App.model (Native_bridge.app ())).Model.outliner_selection_revision in
    send action;
    let dispatch = take_ready () in
    ignore (Native_bridge.resolve_effect (effect_id dispatch) false "Operation rejected");
    check_eq ~msg:"a failed structural request cannot leave native typing buffered forever"
      (App.model (Native_bridge.app ())).Model.outliner_selection_revision (revision + 1)))
    [Model.BackspaceOutlinerEditor ("editing", "Before", 0);
     Model.ReturnOutlinerEditor ("editing", "Before", 0)]

let deleting_text_replaces_the_save_with_the_latest_content () =
  List.iter (fun title -> with_editor (fun session saved ->
    type_text session "Text to delete 中文 😀";
    type_text session title;
    let save = take_ready () in
    check_eq (kind save) "save-outliner-editing";
    apply_effect session save ["type", `String "saveEditing"];
    check_eq ~msg:"backspace and selected text deletion save the remaining content" (!saved).Cache_model.title title))
    ["Text to delete 中文 "; "Text 中文 😀"; ""]

let rapid_editing_and_reparenting_settles_after_the_last_save () =
  let module G = Graph_runtime_test in
  let module R = Graph_runtime in
  let module Ds = Datascript in
  let page = "00000000-0000-4000-8000-000000000001" in
  let editing = "00000000-0000-4000-8000-000000000010" in
  let previous = "00000000-0000-4000-8000-000000000011" in
  G.with_runtime (fun path conn runtime ->
    Fun.protect ~finally:(fun () -> ignore (Native_bridge.dispose ()); G.cleanup_store path) (fun () ->
      ignore (Ds.reset_conn conn (Ds.db_with [
        G.add 1 "block/uuid" (Ds.Uuid page);
        G.add 10 "block/uuid" (Ds.Uuid editing);
        G.add 10 "block/order" (Ds.String "a1");
        G.add 11 "block/uuid" (Ds.Uuid previous);
        G.add 11 "block/title" (Ds.String "Previous");
        G.add 11 "block/page" (Ds.Ref 1);
        G.add 11 "block/parent" (Ds.Ref 1);
        G.add 11 "block/order" (Ds.String "a0")
      ] (Ds.conn_db conn)));
      R.rebase runtime 42 [] [];
      let apply_journal body =
        let ( let* ) = Result.bind in
        let* journal = Journal_sync.decode body in
        let* ids, changed = Journal_sync.apply (fun value -> Ok value) conn (R.state runtime).server_t journal in
        R.rebase runtime journal.t ids changed;
        Ok () in
      let session = Rpc_session.create_session { Rpc_session.default_options with
        graph_blocks = Some (fun () -> Some (R.blocks_for_page runtime page));
        graph_page_blocks = Some (fun uuid -> Some (R.blocks_for_page runtime uuid));
        graph_sidebar_pages = Some (fun () -> Some (R.sidebar_pages runtime));
        authoritative_graph_blocks = Some (fun () -> Some (Graph_read.blocks_for_page (fun value -> Ok value) (Ds.conn_db conn) page));
        sync_cursor = Some (fun () -> Some (R.state runtime).server_t);
        stage_operation = Some (R.stage runtime);
        prepare_operation = Some (R.prepare_sync runtime);
        prepare_operations = Some (R.prepare_sync_batch runtime);
        pending_operations = Some (fun () -> R.pending_operations runtime);
        apply_sync_event = Some apply_journal } in
      let dispatch action payload = Rpc_session.call session (J.to_string (`Assoc [
        "apiVersion", `Int 1; "method", `String "dispatch";
        "params", `Assoc ["action", `String action; "payload", `String payload]])) in
      ignore (dispatch "configure" {|{"baseUrl":"http://localhost","graphId":"plain-1","token":"access"}|});
      ignore (dispatch "selectPage" page);
      ignore (dispatch "startWebSocket" "");
      ignore (Native_bridge.initialize 2 2 3);
      ignore (Native_bridge.apply_response (call session ["type", `String "tapBlock"; "uuid", `String editing]));
      let held_sync = ref None in
      let perform action expected event =
        send action;
        let rec next () =
          let pending = take_ready () in
          match kind pending with
          | "sync-pending" -> held_sync := Some (effect_id pending); next ()
          | "save-outliner-editing" when expected <> "save-outliner-editing" ->
            apply_effect session pending ["type", `String "saveEditing"]; next ()
          | actual -> check_eq actual expected; apply_effect session pending event in
        next () in
      for index = 1 to 60 do
        let title = Printf.sprintf "Draft %d" index in
        perform (Model.ChangeOutlinerText (editing, title, String.length title)) "change-outliner-text"
          ["type", `String "textChanged"; "title", `String title; "caretUTF16Offset", `Int (String.length title)];
        let action = if index mod 2 = 1 then "indent" else "outdent" in
        perform (Model.PerformOutlinerToolbarAction action) "outliner-toolbar"
          ["type", `String "toolbar"; "action", `String action]
      done;
      let rec save () =
        let pending = take_ready () in
        if kind pending = "sync-pending" then (held_sync := Some (effect_id pending); save ())
        else (check_eq (kind pending) "save-outliner-editing";
          apply_effect session pending ["type", `String "saveEditing"]) in
      save ();
      let rec pump response count =
        check ~msg:"the pending pump makes bounded progress" (count <= 122);
        check_eq ~msg:response (member "ok" (J.from_string response)) (`Bool true);
        ignore (Native_bridge.apply_response response);
        match member "pendingSyncRequest" (member "result" (J.from_string response)) with
        | `Null -> count
        | request ->
          let txs = member "bodyObject" request |> member "txs" |> U.to_list in
          let before = (R.state runtime).server_t in
          let body = J.to_string (`Assoc ["type", `String "tx/batch/ok";
            "t-before", `Int before; "t", `Int (before + List.length txs);
            "txs", `List (List.mapi (fun index tx -> `Assoc [
              "t", `Int (before + index + 1); "tx-id", member "tx-id" tx; "tx", member "tx" tx]) txs)]) in
          pump (dispatch "completePendingSync" (J.to_string (`Assoc ["id", member "id" request;
            "status", `Int 200; "body", `String body; "error", `Null]))) (count + List.length txs) in
      let requests = pump (dispatch "beginPendingSync" "") 0 in
      check ~msg:"rapid structural changes actually reached the server" (requests >= 60);
      Option.iter (fun id -> ignore (Native_bridge.resolve_effect id true "")) !held_sync;
      (* The last keystrokes may undo a draft after the network has caught up. *)
      List.iter (fun title ->
        perform (Model.ChangeOutlinerText (editing, title, String.length title)) "change-outliner-text"
          ["type", `String "textChanged"; "title", `String title; "caretUTF16Offset", `Int (String.length title)])
        ["Draft 60x"; "Draft 60"];
      save ();
      check_eq ~msg:"all semantic operations have been acknowledged" (R.pending_operations runtime) [];
      check_eq ~msg:"a final no-op autosave settles the visible sync status"
        (App.model (Native_bridge.app ())).Model.sync_state Model.SyncedState;
      check_eq (G.title (Ds.conn_db conn) editing) "Draft 60";
      check_eq (List.find (fun (block : Cache_model.block) -> block.uuid = editing)
        (R.blocks_for_page runtime page)).parent_id (Some page)))

let cases = [
  case "backspace without a merge target still saves the draft" backspace_without_a_merge_target_still_saves_the_draft;
  case "failed structural input releases the native handoff" failed_structural_input_releases_the_native_handoff;
  case "deleting text saves the latest content" deleting_text_replaces_the_save_with_the_latest_content;
  case "an old no-op save cannot mark newer typing synced" an_old_noop_save_cannot_mark_newer_typing_synced;
  case "toolbar actions that keep editing preserve autosave" toolbar_actions_that_keep_editing_preserve_autosave;
  case "rapid editing and reparenting settles after the last save" rapid_editing_and_reparenting_settles_after_the_last_save;
  case "full pending responses never restart their own pump" full_pending_responses_do_not_restart_a_completed_pump;
  case "external pending work wakes sync once" externally_restored_pending_work_wakes_sync_once;
  case "platform deletion confirmation uses shared effects" platform_delete_confirmation_uses_shared_effects;
  case "idle save commits once then wakes sync" idle_save_commits_once_then_wakes_sync;
  case "autocomplete suppresses idle save" autocomplete_suppresses_idle_save;
  case "completion resumes the save deadline" completion_resumes_the_save_deadline;
  case "new text replaces deadline and ignores stale resolution" newer_text_replaces_deadline_and_stale_resolution;
  case "structural input cancels save without waiting" structural_input_cancels_save_without_waiting;
  case "caret and hydration keep the save deadline" caret_and_hydration_keep_the_save_deadline;
  case "late text resolution after navigation does not arm save" late_text_resolution_after_navigation_does_not_arm_save;
]
