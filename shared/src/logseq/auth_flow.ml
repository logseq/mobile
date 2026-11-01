(* Shared Cognito forms and challenge handling. Tokens stay in native secure storage. *)
type stage = Login | Register | ConfirmRegistration | ForgotPassword | ResetPassword
  | Challenge of string | NewPassword | SelectMfa | SetupMfa | VerifyMfa

type t = {
  opened : bool;
  stage : stage;
  email : string;
  password : string;
  confirmation : string;
  code : string;
  username : string;
  session : string;
  attributes : (string * string) list;
  mfa_choices : string list;
  setup_secret : string;
  destination : string;
  pending : string option;
  error : string option;
  notice : string option;
}

type action = Open | Cancel | Dismiss | Edit of string * string | Navigate of stage
  | Submit | Resend | ChooseMfa of string

let initial = {
  opened = false; stage = Login; email = ""; password = ""; confirmation = "";
  code = ""; username = ""; session = ""; attributes = []; mfa_choices = [];
  setup_secret = ""; destination = ""; pending = None; error = None; notice = None;
}

let busy t = t.pending <> None
let str value = `String value
let field key = function `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields) | _ -> `Null
let string = function `String value -> value | _ -> ""
let get key json = string (field key json)
let strings = function
  | `List values -> List.filter_map (function `String value -> Some value | _ -> None) values
  | _ -> []
let encoded_strings value = try strings (Yojson.Basic.from_string value) with _ -> []

let email_valid t =
  let email = String.trim t.email in
  match String.split_on_char '@' email with
  | [local; domain] -> local <> "" && String.contains domain '.'
      && not (String.exists (fun c -> c = ' ' || c = '\n' || c = '\r') email)
  | _ -> false

let passwords_match t = t.password <> "" && t.password = t.confirmation
let can_submit t = t.opened && not (busy t) && match t.stage with
  | Login -> String.trim t.email <> "" && t.password <> ""
  | Register -> email_valid t && String.trim t.username <> "" && passwords_match t
  | ForgotPassword -> String.trim t.email <> ""
  | ResetPassword -> String.trim t.code <> "" && passwords_match t
  | NewPassword -> passwords_match t && List.for_all (fun (_, value) -> String.trim value <> "") t.attributes
  | ConfirmRegistration | Challenge _ | VerifyMfa -> String.trim t.code <> ""
  | SetupMfa -> true
  | SelectMfa -> false

let title t = match t.stage with
  | Login -> "Login"
  | Register -> "Sign Up"
  | ConfirmRegistration -> "Verify your email"
  | ForgotPassword -> "Reset Password"
  | ResetPassword | NewPassword -> "Choose a new password"
  | Challenge _ -> "Verification code"
  | SelectMfa -> "Choose a verification method"
  | SetupMfa | VerifyMfa -> "Set up your authenticator"

let submit_label t = if busy t then "Please wait…" else match t.stage with
  | Login -> "Sign in"
  | Register -> "Create account"
  | ForgotPassword -> "Send reset code"
  | ResetPassword | NewPassword -> "Save new password"
  | SetupMfa -> "Set up authenticator"
  | _ -> "Verify"

let description t = match t.stage with
  | Login -> "Sign in to sync your Logseq graphs."
  | Register -> "Create a Logseq account with your email address."
  | ForgotPassword -> "Enter your email to receive a password reset code."
  | ResetPassword -> "Enter the reset code and your new password."
  | NewPassword -> "Choose a permanent password to finish signing in."
  | ConfirmRegistration -> "Enter the verification code sent to your email."
  | Challenge "SOFTWARE_TOKEN_MFA" -> "Enter the code from your authenticator app."
  | Challenge _ -> "Enter the verification code sent to you."
  | SelectMfa -> "Choose how you want to verify your identity."
  | SetupMfa -> "Use an authenticator app to protect your account."
  | VerifyMfa -> "Add this setup key to your authenticator app, then enter its code."

let request t operation body =
  let payload = Yojson.Basic.to_string (`Assoc ["operation", str operation; "body", `Assoc body]) in
  {t with pending = Some operation; error = None; notice = None}, Some payload

let user t = ["Username", str (if t.username <> "" then String.trim t.username else String.trim t.email)]
let challenge t name answers = request t "RespondToAuthChallenge"
  ["ChallengeName", str name; "Session", str t.session;
   "ChallengeResponses", `Assoc (("USERNAME", str t.username) :: answers)]

let code_key = function
  | "SMS_MFA" -> "SMS_MFA_CODE" | "EMAIL_MFA" -> "EMAIL_MFA_CODE"
  | "EMAIL_OTP" -> "EMAIL_OTP_CODE" | "SMS_OTP" -> "SMS_OTP_CODE"
  | "SOFTWARE_TOKEN_MFA" -> "SOFTWARE_TOKEN_MFA_CODE" | _ -> "ANSWER"

let submit t = if not (can_submit t) then t, None else
  let cleared = {t with password = ""; confirmation = ""; code = ""} in
  match t.stage with
  | Login -> request {cleared with username = String.trim t.email} "InitiateAuth"
      ["AuthFlow", str "USER_PASSWORD_AUTH"; "AuthParameters", `Assoc
        ["USERNAME", str (String.trim t.email); "PASSWORD", str t.password]]
  | Register -> request {cleared with username = String.trim t.username} "SignUp" (user t @ ["Password", str t.password;
      "UserAttributes", `List [`Assoc ["Name", str "email"; "Value", str (String.trim t.email)]]])
  | ConfirmRegistration -> request cleared "ConfirmSignUp" (user t @ ["ConfirmationCode", str (String.trim t.code)])
  | ForgotPassword -> request cleared "ForgotPassword" (user t)
  | ResetPassword -> request cleared "ConfirmForgotPassword"
      (user t @ ["ConfirmationCode", str (String.trim t.code); "Password", str t.password])
  | Challenge name -> challenge cleared name [code_key name, str (String.trim t.code)]
  | NewPassword -> challenge cleared "NEW_PASSWORD_REQUIRED"
      (("NEW_PASSWORD", str t.password) :: List.map (fun (key, value) -> "userAttributes." ^ key, str value) t.attributes)
  | SetupMfa -> request cleared "AssociateSoftwareToken" ["Session", str t.session]
  | VerifyMfa -> request cleared "VerifySoftwareToken" ["Session", str t.session; "UserCode", str (String.trim t.code)]
  | SelectMfa -> t, None

let update t action = match action with
  | Open when not t.opened -> {initial with opened = true}, None
  | Dismiss -> initial, None
  | Cancel when not (busy t) -> initial, None
  | _ when busy t -> t, None
  | Edit (key, value) ->
    let t = {t with error = None} in
    (match key with
     | "email" -> {t with email = value}
     | "username" -> {t with username = value}
     | "password" -> {t with password = value}
     | "password-confirmation" -> {t with confirmation = value}
     | "code" -> {t with code = value}
     | key when String.starts_with ~prefix:"attribute." key ->
       let attribute = String.sub key 10 (String.length key - 10) in
       {t with attributes = List.map (fun (key, previous) -> key, if key = attribute then value else previous) t.attributes}
     | _ -> t), None
  | Navigate stage -> {initial with opened = true; stage; email = t.email}, None
  | Submit -> submit t
  | Resend when t.stage = ConfirmRegistration -> request t "ResendConfirmationCode" (user t)
  | ChooseMfa choice when t.stage = SelectMfa && List.mem choice t.mfa_choices ->
    challenge t "SELECT_MFA_TYPE" ["ANSWER", str choice]
  | _ -> t, None

let error_message = function
  | "NotAuthorizedException" | "UserNotFoundException" -> "Incorrect email or password."
  | "CodeMismatchException" -> "Incorrect verification code. Please try again."
  | "ExpiredCodeException" -> "This code has expired. Request a new code."
  | "InvalidPasswordException" | "PasswordHistoryPolicyViolationException" -> "Choose a stronger password that meets your account's password policy."
  | "UsernameExistsException" | "AliasExistsException" -> "An account with this email already exists. Sign in instead."
  | "TooManyRequestsException" | "LimitExceededException" | "TooManyFailedAttemptsException" -> "Too many attempts. Please wait and try again."
  | "InvalidParameterException" -> "Check your details and try again."
  | "CodeDeliveryFailureException" -> "The verification code could not be sent. Please try again."
  | _ -> "Unable to complete this request. Please try again."

let failed t message = {t with pending = None; error = Some message}, None, false
let return_to_login t notice = {initial with opened = true; email = t.email; notice = Some notice}, None, false

let complete t encoded =
  if not t.opened then
    let signed_in = try field "signedIn" (Yojson.Basic.from_string encoded) = `Bool true with _ -> false in
    initial, None, signed_in
  else if t.pending = None then t, None, false else
  try
    let response = Yojson.Basic.from_string encoded in
    let operation = Option.get t.pending in
    let t = {t with pending = None; password = ""; confirmation = ""; code = ""} in
    let code = get "__type" response |> String.split_on_char '#' |> List.rev |> List.hd in
    if code = "UserNotConfirmedException" then
      {t with stage = ConfirmRegistration; notice = Some "Verify your email to finish creating your account. You can request a new code below."}, None, false
    else if code = "PasswordResetRequiredException" then
      {t with stage = ForgotPassword; notice = Some "Reset your password to continue."}, None, false
    else if code <> "" then failed t (error_message code)
    else if field "signedIn" response = `Bool true then initial, None, true
    else match operation with
    | "ForgotPassword" -> {t with stage = ResetPassword; destination = get "Destination" (field "CodeDeliveryDetails" response)}, None, false
    | "ConfirmForgotPassword" -> return_to_login t "Password updated. Sign in with your new password."
    | "SignUp" ->
      if field "UserConfirmed" response = `Bool true then return_to_login t "Account created. You can now sign in."
      else {t with stage = ConfirmRegistration; destination = get "Destination" (field "CodeDeliveryDetails" response)}, None, false
    | "ConfirmSignUp" -> return_to_login t "Email verified. You can now sign in."
    | "ResendConfirmationCode" -> {t with notice = Some "A new verification code has been sent."}, None, false
    | "AssociateSoftwareToken" when get "SecretCode" response <> "" && get "Session" response <> "" ->
      {t with stage = VerifyMfa; setup_secret = get "SecretCode" response; session = get "Session" response}, None, false
    | "VerifySoftwareToken" when get "Status" response = "SUCCESS" && get "Session" response <> "" ->
      let t, next = challenge {t with session = get "Session" response; setup_secret = ""} "MFA_SETUP" [] in t, next, false
    | "InitiateAuth" | "RespondToAuthChallenge" ->
      let name = get "ChallengeName" response and session = get "Session" response in
      if session = "" then failed t "Sign-in could not be completed. Please try again." else
      let parameters = field "ChallengeParameters" response in
      let username = match get "USERNAME" parameters, get "USER_ID_FOR_SRP" parameters with
        | "", "" -> t.username | "", user -> user | user, _ -> user in
      let t = {t with session; username; destination = get "CODE_DELIVERY_DESTINATION" parameters} in
      (match name with
       | "SMS_MFA" | "EMAIL_MFA" | "SOFTWARE_TOKEN_MFA" | "EMAIL_OTP" | "SMS_OTP" | "CUSTOM_CHALLENGE" ->
         {t with stage = Challenge name}, None, false
       | "NEW_PASSWORD_REQUIRED" ->
         let attributes = encoded_strings (get "requiredAttributes" parameters) |> List.map (fun key ->
           let key = if String.starts_with ~prefix:"userAttributes." key then String.sub key 15 (String.length key - 15) else key in key, "") in
         {t with stage = NewPassword; attributes}, None, false
       | "SELECT_MFA_TYPE" ->
         let choices = encoded_strings (get "MFAS_CAN_CHOOSE" parameters)
           |> List.filter (fun value -> List.mem value ["SMS_MFA"; "EMAIL_MFA"; "SOFTWARE_TOKEN_MFA"]) in
         if choices = [] then failed t "No supported verification method is available."
         else {t with stage = SelectMfa; mfa_choices = choices}, None, false
       | "MFA_SETUP" when List.mem "SOFTWARE_TOKEN_MFA" (encoded_strings (get "MFAS_CAN_SETUP" parameters)) ->
         {t with stage = SetupMfa}, None, false
       | _ -> failed {t with stage = Login; session = ""} "This account requires a sign-in method that is not supported here.")
    | _ -> failed t "Sign-in could not be completed. Please try again."
  with _ -> failed t "Sign-in could not be completed. Please try again."
