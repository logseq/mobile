open Test_util
open App_test
open Yojson.Basic.Util

let find app identifier =
  descendant_with_identifier (Lui_app.runtime app) (Lui_app.root_node app) identifier

let press app identifier =
  let target = find app identifier in
  check ~msg:("control exists: " ^ identifier) (target <> -1);
  dispatch app (Lui_protocol.Press target);
  flush app

let input app identifier value =
  let target = find app identifier in
  check ~msg:("field exists: " ^ identifier) (target <> -1);
  dispatch app (Lui_protocol.TextChanged (target, value));
  flush app

let mount backend =
  let app = App.create_with_authentication backend "signedOut" in
  start app;
  (* The existing entry action must open a shared form, without a host request. *)
  send app Model.SignIn;
  flush app;
  app

let request app =
  match List.filter_map (fun eff ->
    let json = Yojson.Basic.from_string (Native_bridge.encode_effect eff) in
    if json |> member "kind" = `String "sign-in" then Some json else None)
    (App.model app).pending_effects with
  | [json] -> json |> member "id" |> to_int,
    json |> member "text" |> to_string |> Yojson.Basic.from_string
  | _ -> failwith "Expected one Cognito request"

let resolve app json =
  let id, _ = request app in
  send app (Model.DequeueEffect id);
  send app (Model.ResolveEffect (id, true, json));
  flush app

let login app =
  input app "field.auth.email" "  test@example.com  ";
  input app "field.auth.password" " secret with spaces ";
  press app "button.auth.submit"

let with_hosts test () = List.iter (fun backend -> test (mount backend))
  [ios_backend (); kotlin_backend ()]

let shared_form app =
  check ~msg:"sign-in opens a LUI sheet" (find app "sheet.authentication" <> -1);
  check ~msg:"form scrolls above the keyboard" (find app "scroll.authentication" <> -1);
  check_eq ~msg:"opening the form never invokes a browser" (App.model app).pending_effects [];
  check_eq (descendant_enabled (Lui_app.runtime app) (Lui_app.root_node app) "button.auth.submit") (Some false);
  login app;
  let _, json = request app in
  check_eq (json |> member "operation") (`String "InitiateAuth");
  check_eq (json |> member "body" |> member "AuthFlow") (`String "USER_PASSWORD_AUTH");
  check_eq (json |> member "body" |> member "AuthParameters" |> member "USERNAME") (`String "test@example.com");
  check_eq ~msg:"password whitespace is significant"
    (json |> member "body" |> member "AuthParameters" |> member "PASSWORD") (`String " secret with spaces ");
  let before = (App.model app).pending_effects in
  press app "button.auth.submit";
  check_eq ~msg:"busy submit is idempotent" (App.model app).pending_effects before;
  resolve app {|{"signedIn":true}|};
  check_eq (App.model app).authentication_state "signedIn";
  check_eq (find app "sheet.authentication") (-1)

let challenge app =
  login app;
  resolve app {|{"ChallengeName":"SOFTWARE_TOKEN_MFA","Session":"first","ChallengeParameters":{"USERNAME":"canonical-user"}}|};
  check_eq ~msg:"a challenge is not a successful login" (App.model app).authentication_state "signedOut";
  check_eq ~msg:"password field is removed after submitting credentials" (find app "field.auth.password") (-1);
  input app "field.auth.code" "123456";
  press app "button.auth.submit";
  let _, json = request app in
  check_eq (json |> member "operation") (`String "RespondToAuthChallenge");
  check_eq (json |> member "body" |> member "Session") (`String "first");
  check_eq (json |> member "body" |> member "ChallengeResponses" |> member "USERNAME") (`String "canonical-user");
  check_eq (json |> member "body" |> member "ChallengeResponses" |> member "SOFTWARE_TOKEN_MFA_CODE") (`String "123456");
  resolve app {|{"__type":"CodeMismatchException","message":"do not display raw service details"}|};
  check ~msg:"incorrect code is actionable in the form" (find app "auth.error" <> -1);
  check_eq (find app "sheet.authentication" <> -1) true;
  input app "field.auth.code" "654321";
  press app "button.auth.submit";
  resolve app {|{"signedIn":true}|};
  check_eq (App.model app).authentication_state "signedIn"

let recovery app =
  input app "field.auth.email" "test@example.com";
  press app "button.auth.forgot-password";
  press app "button.auth.submit";
  let _, json = request app in
  check_eq (json |> member "operation") (`String "ForgotPassword");
  resolve app {|{"CodeDeliveryDetails":{"Destination":"t***@example.com"}}|};
  input app "field.auth.code" "123456";
  input app "field.auth.password" "new-password";
  input app "field.auth.password-confirmation" "wrong";
  check_eq ~msg:"password confirmation prevents accidental resets"
    (descendant_enabled (Lui_app.runtime app) (Lui_app.root_node app) "button.auth.submit") (Some false);
  input app "field.auth.password-confirmation" "new-password";
  press app "button.auth.submit";
  let _, json = request app in
  check_eq (json |> member "operation") (`String "ConfirmForgotPassword");
  check_eq (json |> member "body" |> member "ConfirmationCode") (`String "123456");
  resolve app "{}";
  check_eq ~msg:"reset returns to login without authenticating" (App.model app).authentication_state "signedOut";
  check ~msg:"reset success is shown" (find app "auth.notice" <> -1);
  check ~msg:"the user can sign in with the new password" (find app "field.auth.password" <> -1)

let signup app =
  press app "button.auth.create-account";
  input app "field.auth.email" "test@example.com";
  input app "field.auth.username" "test-person";
  input app "field.auth.password" "password";
  input app "field.auth.password-confirmation" "password";
  press app "button.auth.submit";
  let _, json = request app in
  check_eq (json |> member "operation") (`String "SignUp");
  check_eq (json |> member "body" |> member "Username") (`String "test-person");
  resolve app {|{"UserConfirmed":false,"CodeDeliveryDetails":{"Destination":"t***@example.com"}}|};
  press app "button.auth.resend-code";
  let _, json = request app in
  check_eq (json |> member "operation") (`String "ResendConfirmationCode");
  resolve app "{}";
  input app "field.auth.code" "123456";
  press app "button.auth.submit";
  let _, json = request app in
  check_eq (json |> member "operation") (`String "ConfirmSignUp");
  resolve app "{}";
  check_eq (App.model app).authentication_state "signedOut";
  check ~msg:"confirmation returns to login" (find app "field.auth.password" <> -1)

let failures_and_cancellation app =
  login app;
  resolve app {|{"__type":"com.amazonaws.cognito#NotAuthorizedException","message":"secret with spaces"}|};
  check ~msg:"login failures appear beside the form" (find app "auth.error" <> -1);
  check_eq ~msg:"credentials never enter diagnostics" (reported_errors (App.model app)) [];
  login app;
  let id, _ = request app in
  resolve app {|{"ChallengeName":"SMS_MFA","Session":"current"}|};
  press app "button.auth.cancel";
  send app (Model.ResolveEffect (id, true, {|{"ChallengeName":"SMS_MFA","Session":"late"}|}));
  flush app;
  check_eq ~msg:"late callbacks do not reopen a dismissed form" (find app "sheet.authentication") (-1);
  send app Model.SignIn;
  flush app;
  check_eq ~msg:"cancel clears the password" (property_string (Lui_app.runtime app)
    (find app "field.auth.password") Lui_protocol.TextValue) ""

let password_change app =
  login app;
  resolve app {|{"ChallengeName":"NEW_PASSWORD_REQUIRED","Session":"change","ChallengeParameters":{"requiredAttributes":"[\"userAttributes.name\"]"}}|};
  input app "field.auth.password" "replacement";
  input app "field.auth.password-confirmation" "replacement";
  input app "field.auth.attribute.name" "Test Person";
  press app "button.auth.submit";
  let _, json = request app in
  check_eq (json |> member "body" |> member "ChallengeResponses" |> member "NEW_PASSWORD") (`String "replacement");
  check_eq (json |> member "body" |> member "ChallengeResponses" |> member "userAttributes.name") (`String "Test Person");
  resolve app {|{"signedIn":true}|}

let mfa_setup app =
  login app;
  resolve app {|{"ChallengeName":"MFA_SETUP","Session":"setup","ChallengeParameters":{"MFAS_CAN_SETUP":"[\"SOFTWARE_TOKEN_MFA\"]"}}|};
  press app "button.auth.submit";
  let _, json = request app in
  check_eq (json |> member "operation") (`String "AssociateSoftwareToken");
  check_eq (json |> member "body" |> member "Session") (`String "setup");
  resolve app {|{"SecretCode":"EXAMPLESECRET","Session":"associated"}|};
  check ~msg:"authenticator key is presented for manual setup" (find app "auth.setup-secret" <> -1);
  input app "field.auth.code" "123456";
  press app "button.auth.submit";
  let _, json = request app in
  check_eq (json |> member "operation") (`String "VerifySoftwareToken");
  resolve app {|{"Status":"SUCCESS","Session":"verified"}|};
  let _, json = request app in
  check_eq (json |> member "operation") (`String "RespondToAuthChallenge");
  check_eq (json |> member "body" |> member "Session") (`String "verified");
  check_eq (json |> member "body" |> member "ChallengeName") (`String "MFA_SETUP");
  resolve app {|{"signedIn":true}|}

let malformed_and_unsupported app =
  login app;
  resolve app "not-json";
  check_eq (App.model app).authentication_state "signedOut";
  check ~msg:"malformed responses permit retry" (find app "auth.error" <> -1);
  login app;
  resolve app {|{"ChallengeName":"UNKNOWN_CHALLENGE","Session":"unknown"}|};
  check_eq (App.model app).authentication_state "signedOut";
  check ~msg:"unknown challenge never silently authenticates" (find app "auth.error" <> -1)

let dismiss_during_request app =
  login app;
  let id, _ = request app in
  dispatch app (Lui_protocol.Dismiss (find app "sheet.authentication"));
  flush app;
  check_eq ~msg:"swipe dismissal clears the form even during a request" (find app "sheet.authentication") (-1);
  send app Model.SignIn;
  flush app;
  check_eq ~msg:"an outstanding request cannot attach to a new form" (find app "sheet.authentication") (-1);
  send app (Model.DequeueEffect id);
  send app (Model.ResolveEffect (id, true, {|{"ChallengeName":"SMS_MFA","Session":"late"}|}));
  flush app;
  check_eq ~msg:"a dismissed request never reopens on a late challenge" (find app "sheet.authentication") (-1);
  send app Model.SignIn;
  flush app;
  check ~msg:"login is available again after the request completes" (find app "field.auth.email" <> -1)

let cases = [
  case "shared mobile login submits credentials without a browser" (with_hosts shared_form);
  case "MFA remains in the form and retries incorrect codes" (with_hosts challenge);
  case "password recovery requires code and matching new passwords" (with_hosts recovery);
  case "registration confirms and resends email verification" (with_hosts signup);
  case "login errors are safe and dismissal ignores late challenges" (with_hosts failures_and_cancellation);
  case "temporary passwords collect required attributes" (with_hosts password_change);
  case "TOTP enrollment uses each returned session" (with_hosts mfa_setup);
  case "malformed and unsupported responses never authenticate" (with_hosts malformed_and_unsupported);
  case "swipe dismissal during a request cannot leave a hidden modal" (with_hosts dismiss_during_request);
]
