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
  check_eq ~msg:"shared save policy wakes pending sync" (kind sync) "sync-now";
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
    (List.mem "sync-now" (pending_kinds ())))

let externally_restored_pending_work_wakes_sync_once () = with_editor (fun session _ ->
  ignore (call session ["type", `String "textChanged"; "title", `String "Restored"; "caretUTF16Offset", `Int 8]);
  let response = call session ["type", `String "saveEditing"] in
  ignore (Native_bridge.apply_response response);
  check_eq ~msg:"external core responses share the mutation wake policy" (pending_kinds ()) ["sync-now"];
  ignore (Native_bridge.apply_response response);
  check_eq (pending_kinds ()) ["sync-now"];
  let sync = take_ready () in
  ignore (Native_bridge.apply_response response);
  check_eq ~msg:"an active sync pump owns its remaining operations" (pending_kinds ()) [];
  ignore (Native_bridge.resolve_effect (effect_id sync) true response))

let cases = [
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
