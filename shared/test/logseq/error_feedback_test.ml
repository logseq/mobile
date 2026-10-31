open Test_util
module M = Model

let reports (model : M.logseq_model) = List.filter_map (function
  | M.ReportErrorEffect (_, message) -> Some message | _ -> None) model.pending_effects

let errors_are_reported_without_changing_failure_state () =
  let message = "com.apple.AuthenticationServices.WebAuthenticationSession error 1" in
  let initial = { (M.initial ()) with in_flight_effects = [M.SignInEffect 7]; next_effect_id = 8 } in
  let failed = App.update initial (M.ResolveEffect (7, false, message)) in
  check_eq (reports failed) [message];
  check_eq failed.authentication_error (Some message);
  let reporting = App.update failed (M.DequeueEffect 8) in
  let finished = App.update reporting (M.ResolveEffect (8, true, "")) in
  check_eq ~msg:"logging cannot clear or resolve the original failure" finished.effect_error failed.effect_error;
  check_eq finished.authentication_error failed.authentication_error;
  check_eq ~msg:"logging never creates another report" (reports finished) []

let host_and_snapshot_errors_are_reported_once () =
  let authenticated = App.update (M.initial ()) (M.ApplyAuthentication ("signedIn", Some "Offline refresh")) in
  check_eq (reports authenticated) ["Offline refresh"];
  let repeated = App.update authenticated (M.ApplyAuthentication ("signedIn", Some "Offline refresh")) in
  check_eq (reports repeated) ["Offline refresh"];
  let snapshot = { (App_test.empty_core_projection ()) with pending_sync_error = Some "Upload failed";
    flashcard_decks_json = {|{"error":"Card query failed"}|} } in
  let first = App.update (M.initial ()) (M.ApplyCoreSnapshot snapshot) in
  check_eq (List.sort compare (reports first)) ["Card query failed"; "Upload failed"];
  let second = App.update first (M.ApplyCoreSnapshot snapshot) in
  check_eq (reports second) (reports first);
  let synced = App.update (M.initial ()) (M.SyncFailed "Connection failed") in
  check_eq (reports synced) ["Connection failed"]

let technical_errors_do_not_render_inside_pages () =
  List.iter (fun backend ->
    let app = App.create backend in
    App_test.start app;
    App_test.send app (M.ApplyAuthentication ("signedOut", Some "Raw hosted authentication error"));
    App_test.flush app;
    let renderer = Lui_app.runtime app and root = Lui_app.root_node app in
    List.iter (fun identifier ->
      check_eq ~msg:("technical errors belong in the host log/alert: " ^ identifier)
        (App_test.descendant_with_identifier renderer root identifier) (-1))
      ["layout.error.banner"; "error.banner"; "text.authentication-error"])
    [App_test.ios_backend (); App_test.kotlin_backend ()]

let last_error_stays_visible_outside_log_filters () =
  List.iter (fun backend ->
    let app = App.create backend in
    App_test.start app;
    App_test.send app M.OpenSettings;
    App_test.send app M.OpenRuntimeLog;
    let error : M.runtime_log_record = { id = "99"; level = "ERROR"; source = "ui";
      timestamp = "2026-10-31 22:00"; message = "Latest authentication error" } in
    App_test.send app (M.ApplyRuntimeLog ([], Some error));
    App_test.flush app;
    let renderer = Lui_app.runtime app and root = Lui_app.root_node app in
    let detail = App_test.descendant_with_identifier renderer root "log.last-error.message" in
    check_eq (App_test.property_string renderer detail Lui_protocol.TextValue) error.message;
    App_test.send app M.ToggleRuntimeLogSource;
    App_test.send app M.ToggleRuntimeLogErrors;
    App_test.send app (M.ApplyRuntimeLog ([], Some error));
    App_test.flush app;
    check_eq (App_test.property_string renderer
      (App_test.descendant_with_identifier renderer root "log.last-error.message") Lui_protocol.TextValue) error.message;
    App_test.send app M.CopyRuntimeLog;
    App_test.flush app;
    check ~msg:"copy includes the visible last error even when the filtered list is empty"
      (List.exists (function M.CopyRuntimeLogEffect (_, records) -> List.mem error records | _ -> false)
        (App.model app).pending_effects)) [App_test.ios_backend (); App_test.kotlin_backend ()]

let host_log_payload_carries_the_last_error () =
  ignore (Native_bridge.initialize 2 2 3);
  ignore (Native_bridge.apply_host_update "runtime-log"
    {|{"records":[],"lastError":{"id":"99","level":"ERROR","source":"ui","timestamp":"22:00","message":"Latest error"}}|});
  check_eq (Option.map (fun (record : M.runtime_log_record) -> record.message)
    (App.model (Native_bridge.app ())).runtime_log_last_error) (Some "Latest error");
  ignore (Native_bridge.dispose ())

let cases = [
  case "last error survives the log filters" last_error_stays_visible_outside_log_filters;
  case "host log payload carries the last error" host_log_payload_carries_the_last_error;
  case "errors report once and preserve their failure state" errors_are_reported_without_changing_failure_state;
  case "host and snapshot errors enter diagnostics once" host_and_snapshot_errors_are_reported_once;
  case "technical errors do not render inside pages" technical_errors_do_not_render_inside_pages;
]
