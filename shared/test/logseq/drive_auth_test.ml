(* Sign-in and sign-out. Scripts live in logseq/drive/auth/. *)

let message value = Yojson.Basic.to_string value

let signed_in (host : Drive_host.host) id =
  [ Model.DequeueEffect id
  ; Model.ApplyLocalGraphIds (Drive_host.graph_ids host)
  ; Model.ApplyCoreSnapshot (Drive_host.catalog_projection host.graphs)
  ; Model.ResolveEffect (id, true, "{\"signedIn\":true}") ]

let challenge name parameters =
  `Assoc
    [
      ("ChallengeName", `String name);
      ("Session", `String "session-1");
      ("ChallengeParameters", `Assoc parameters);
    ]

let username body =
  Drive_host.json_string (Drive_host.json_assoc body "AuthParameters") "USERNAME"
  |> Option.value ~default:""

let reply id value =
  [ Model.DequeueEffect id; Model.ResolveEffect (id, true, message value) ]

let handle (host : Drive_host.host) _model = function
  | Model.SignInEffect (id, payload) ->
    let fields = Drive_host.json_fields payload in
    let operation = Drive_host.json_string fields "operation" in
    let body = Drive_host.json_assoc fields "body" in
    Some
      (if host.Drive_host.fail_sign_in then
         [ Model.DequeueEffect id
         ; Model.ResolveEffect (id, true, "{\"__type\":\"NotAuthorizedException\"}") ]
       else
         match operation with
         | Some "InitiateAuth" ->
           (match username body with
           | "mfa@example.com" ->
             reply id
               (challenge "SOFTWARE_TOKEN_MFA"
                  [ ("USERNAME", `String "mfa@example.com") ])
           | "select@example.com" ->
             reply id
               (challenge "SELECT_MFA_TYPE"
                  [
                    ("USERNAME", `String "select@example.com");
                    ( "MFAS_CAN_CHOOSE"
                    , `String "[\"SMS_MFA\",\"SOFTWARE_TOKEN_MFA\"]" );
                  ])
           | "setup@example.com" ->
             reply id
               (challenge "MFA_SETUP"
                  [
                    ("USERNAME", `String "setup@example.com");
                    ("MFAS_CAN_SETUP", `String "[\"SOFTWARE_TOKEN_MFA\"]");
                  ])
           | _ -> signed_in host id)
         | Some "SignUp" ->
           reply id
             (`Assoc
                [
                  ("UserConfirmed", `Bool false);
                  ( "CodeDeliveryDetails"
                  , `Assoc [ ("Destination", `String "n***@example.com") ] );
                ])
         | Some "ConfirmSignUp" | Some "ConfirmForgotPassword" -> reply id (`Assoc [])
         | Some "ForgotPassword" ->
           reply id
             (`Assoc
                [
                  ( "CodeDeliveryDetails"
                  , `Assoc [ ("Destination", `String "n***@example.com") ] );
                ])
         | Some "AssociateSoftwareToken" ->
           reply id
             (`Assoc
                [
                  ("SecretCode", `String "ABCD1234");
                  ("Session", `String "session-2");
                ])
         | Some "VerifySoftwareToken" ->
           reply id
             (`Assoc
                [ ("Status", `String "SUCCESS"); ("Session", `String "session-3") ])
         | Some "RespondToAuthChallenge" -> signed_in host id
         | _ -> signed_in host id)
  | Model.SignOutEffect id ->
    Some (Model.DequeueEffect id :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/auth"
