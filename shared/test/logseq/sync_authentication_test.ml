open Test_util
open App_test

let local_application backend =
  let application = App.create backend in
  start application;
  send application (Model.ApplyCoreSnapshot {
    (empty_core_projection ()) with selected_graph_id = Some "local";
    graph_name = Some "Local"; graphs = [graph "local" "Local" false true];
  });
  send application (Model.ApplyLocalGraphIds ["local"]);
  application

let signed_out_indicator_opens_sign_in () =
  List.iter (fun backend ->
    let application = local_application backend in
    send application (Model.ApplyAuthentication ("signedOut", None));
    flush application;
    let runtime = Lui_app.runtime application in
    let root = Lui_app.root_node application in
    let indicator = descendant_with_identifier runtime root "sync.disconnected" in
    check ~msg:"local graphs retain the sync indicator" (indicator <> -1);
    check_eq ~msg:"signed-out sync is gray"
      (property_string runtime indicator Lui_protocol.ForegroundValue) "muted-foreground";
    dispatch application (Lui_protocol.Press indicator);
    dispatch application (Lui_protocol.Press indicator);
    flush application;
    let current = App.model application in
    check_eq ~msg:"the indicator starts Hosted UI once" current.pending_effects [Model.SignInEffect 1];
    check ~msg:"sign-in does not open sync details" (not current.sync_details_open);
    check ~msg:"local journals stay available during sign-in"
      (descendant_with_identifier runtime root "pane.journals" <> -1))
    [ios_backend (); kotlin_backend ()]

let sync_now_requires_authentication () =
  List.iter (fun state ->
    let current = {(Model.initial ()) with Model.authentication_state = state} in
    check_eq ~msg:"unauthenticated sync never schedules an upload"
      (Model.update current Model.SyncNow).pending_effects [];
    let projected = Model.update current (Model.ApplyCoreSnapshot {
      (empty_core_projection ()) with has_pending_semantic_operations = true;
      sync_connected = true;
    }) in
    check_eq ~msg:"local pending work cannot start unauthenticated uploads"
      projected.pending_effects [];
    check_eq ~msg:"a stale connected projection cannot enable signed-out sync"
      (View_base.sync_indicator_foreground projected) "muted-foreground")
    ["signedOut"; "restoring"; "signingIn"; "signingOut"];
  List.iter (fun backend ->
    let application = local_application backend in
    send application (Model.ApplyAuthentication ("signedIn", None));
    send application Model.OpenSyncDetails;
    send application (Model.ApplyAuthentication ("signedOut", None));
    flush application;
    let runtime = Lui_app.runtime application in
    check_eq ~msg:"Sync now is disabled after signing out"
      (descendant_enabled runtime (Lui_app.root_node application) "button.sync-now") (Some false);
    send application (Model.ApplyAuthentication ("signedIn", None));
    flush application;
    check_eq ~msg:"sign-in re-enables Sync now"
      (descendant_enabled runtime (Lui_app.root_node application) "button.sync-now") (Some true))
    [ios_backend (); kotlin_backend ()]

let failed_refresh_prompts_for_sign_in () =
  List.iter (fun backend ->
    let application = local_application backend in
    send application (Model.ApplyAuthentication ("signedIn", None));
    send application (Model.ApplyAuthentication ("signedOut", Some "Sign in to connect to Logseq Sync."));
    flush application;
    check ~msg:"failed refresh presents the login prompt" (App.model application).sync_details_open;
    let runtime = Lui_app.runtime application in
    let root = Lui_app.root_node application in
    let prompt = descendant_with_identifier runtime root "sync.authentication-error" in
    check_eq ~msg:"the prompt explains how to restore sync"
      (property_string runtime prompt Lui_protocol.TextValue) "Sign in to connect to Logseq Sync.";
    let sign_in = descendant_with_identifier runtime root "button.sync-sign-in" in
    check ~msg:"the prompt has a login action" (sign_in <> -1);
    check_eq ~msg:"refresh failure waits for the user" (App.model application).pending_effects [];
    dispatch application (Lui_protocol.Press sign_in);
    flush application;
    check_eq (App.model application).pending_effects [Model.SignInEffect 1];
    check ~msg:"Hosted UI replaces the prompt" (not (App.model application).sync_details_open))
    [ios_backend (); kotlin_backend ()]

let signed_in_indicator_still_opens_sync_details () =
  let application = local_application (ios_backend ()) in
  send application (Model.ApplyAuthentication ("signedIn", None));
  send application Model.OpenSyncDetails;
  flush application;
  check (App.model application).sync_details_open;
  send application Model.SyncNow;
  flush application;
  check_eq (App.model application).pending_effects [Model.SyncNowEffect 1]

let cases = [
  case "signed-out indicator opens sign-in" signed_out_indicator_opens_sign_in;
  case "Sync now requires authentication" sync_now_requires_authentication;
  case "failed refresh prompts for sign-in" failed_refresh_prompts_for_sign_in;
  case "signed-in indicator still opens sync details" signed_in_indicator_still_opens_sync_details;
]
