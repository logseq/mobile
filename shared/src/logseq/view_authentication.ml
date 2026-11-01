open Lui_protocol
open Lui_elements

let form (current : Model.logseq_model) = current.authentication_form
let send_action send action = Model.AuthenticationForm action |> send |> ignore
let action send value = fun _ -> send_action send value
let tr source value = View_base.tr (Signal.sample source) value

let mobile_input kind control : t = fun context parent ->
  let scope = Lui_ui.extension context "native-auth-input" in
  Lui_ui.extension_property context scope "kind" (StringValue kind);
  ignore (control context (Some scope));
  attach context parent scope;
  scope

let field source send key label kind =
  let value (current : Model.logseq_model) =
    let t = form current in
    match key with
    | "email" -> t.email | "username" -> t.username | "password" -> t.password
    | "password-confirmation" -> t.confirmation | "code" -> t.code
    | key -> Option.value ~default:"" (List.assoc_opt
        (String.sub key 10 (String.length key - 10)) t.attributes) in
  let input = if kind = "password" || kind = "new-password" then secure_field else text_field in
  column ~key:("auth." ^ key) ~gap:8 ~cross:`stretch [
    row ~padding_horizontal:16 [text ~value:(tr source label) ~foreground:"muted-foreground" ~style_class:"subheadline" []];
    mobile_input kind
      (input ~accessibility_identifier:("field.auth." ^ key)
        ~label:(tr source label) ~placeholder:"" ~min_height:54
        ~style_class:"plain-input" ~padding_horizontal:18 ~padding_vertical:14
        ~border_width:1 ~border_color:"auth-border" ~corner_radius:28
        ~text_signal:(Signal.map value source)
        ~disabled_signal:(Signal.map (fun current -> Auth_flow.busy (form current)) source)
        ~on_input:(on_input send (fun value -> Model.AuthenticationForm (Auth_flow.Edit (key, value))))
        ~on_submit:(action send Auth_flow.Submit) []);
  ]

let fields source send stage attributes choices =
  let email = field source send "email" "Email" "email" in
  let code = field source send "code" "Verification code" "code" in
  let passwords = [field source send "password" "Password" "new-password";
    field source send "password-confirmation" "Confirm Password" "new-password"] in
  match stage with
  | Auth_flow.Login -> [email; field source send "password" "Password" "password"]
  | Register -> email :: field source send "username" "Username" "username" :: passwords
  | ForgotPassword -> [email]
  | ConfirmRegistration | Challenge _ -> [code]
  | ResetPassword -> code :: passwords
  | NewPassword -> passwords @ List.map (fun key -> field source send ("attribute." ^ key) key "text") attributes
  | SelectMfa -> List.map (fun choice ->
      let label = match choice with "SMS_MFA" -> "Text message" | "EMAIL_MFA" -> "Email" | _ -> "Authenticator app" in
      button ~text:(tr source label) ~min_height:48 ~variant:`secondary
        ~accessibility_identifier:("button.auth.mfa." ^ choice)
        ~disabled_signal:(Signal.map (fun current -> Auth_flow.busy (form current)) source)
        ~on_press:(action send (Auth_flow.ChooseMfa choice)) []) choices
  | SetupMfa -> []
  | VerifyMfa -> [text ~accessibility_identifier:"auth.setup-secret"
      ~value_signal:(Signal.map (fun current -> (form current).setup_secret) source) []; code]

let sheet source send : t =
  let busy = Signal.map (fun current -> Auth_flow.busy (form current)) source in
  let link id label event = button ~variant:`ghost ~text:(tr source label) ~min_height:44
      ~text_alignment:`center ~accessibility_identifier:id ~disabled_signal:busy ~on_press:(action send event) [] in
  let can_submit = Signal.map (fun current -> Auth_flow.can_submit (form current)) source in
  themed ~tokens:Lui_ui.[
    "background", Adaptive { light = "#F4F6F3"; dark = "#002D38" };
    "surface", Adaptive { light = "#F4F6F3"; dark = "#002D38" };
    "muted-foreground", Adaptive { light = "#686E6B"; dark = "#ADBDBD" };
    "auth-border", Adaptive { light = "#CCD2CE"; dark = "#4D686D" };
    "auth-action", Adaptive { light = "#101312"; dark = "#EDF2EF" };
    "auth-action-text", Adaptive { light = "#FFFFFF"; dark = "#102E33" };
    "auth-disabled", Adaptive { light = "#E2E6E2"; dark = "#24434A" };
    "auth-disabled-text", Adaptive { light = "#5D655F"; dark = "#AABBB9" };
  ] (
  sheet ~text_signal:(Signal.map (fun current -> tr source (Auth_flow.title (form current))) source)
    ~height:680 ~style_class:"navigation-content navigation-inline-title"
    ~detents_signal:(Signal.map (fun current -> match (form current).stage with
      | Auth_flow.Register | NewPassword -> "0.82,large"
      | ForgotPassword -> "0.48,large"
      | _ -> "0.62,large") source)
    ~accessibility_identifier:"sheet.authentication"
    ~on_dismiss:(action send Auth_flow.Dismiss)
    [
      scroll ~grow:1.0 ~accessibility_identifier:"scroll.authentication" [
        column ~gap:28 ~padding_horizontal:20 ~padding_vertical:28 ~max_width:480 ~cross:`stretch [
          if_ ~test:(Signal.map (fun current -> match (form current).stage with
            | Auth_flow.Login | Register | ForgotPassword -> false | _ -> true) source)
            (text ~foreground:"muted-foreground" ~style_class:"footnote"
              ~value_signal:(Signal.map (fun current -> tr source (Auth_flow.description (form current))) source) []);
          dyn (fun (stage, attributes, choices) ->
            column ~gap:24 ~cross:`stretch (fields source send stage attributes choices))
            (Signal.map (fun current -> let t = form current in
              t.stage, List.map fst t.attributes, t.mfa_choices) source);
          if_ ~test:(Signal.map (fun current -> (form current).error <> None) source)
            (text ~accessibility_identifier:"auth.error" ~foreground:"destructive" ~style_class:"footnote"
              ~value_signal:(Signal.map (fun current -> tr source (Option.value ~default:"" (form current).error)) source) []);
          if_ ~test:(Signal.map (fun current -> (form current).notice <> None) source)
            (text ~accessibility_identifier:"auth.notice" ~foreground:"muted-foreground" ~style_class:"footnote"
              ~value_signal:(Signal.map (fun current -> tr source (Option.value ~default:"" (form current).notice)) source) []);
          if_ ~test:busy (spinner ~accessibility_identifier:"auth.loading" []);
          if_ ~test:(Signal.map (fun current -> (form current).stage <> Auth_flow.SelectMfa) source)
            (row ~cross:`center ~corner_radius:28
              ~background_signal:(Signal.map (fun enabled -> if enabled then "auth-action" else "auth-disabled") can_submit)
              [button ~variant:`ghost ~min_height:54 ~size:`lg ~grow:1.0
                ~accessibility_identifier:"button.auth.submit" ~text_alignment:`center
                ~disabled_signal:(Signal.map not can_submit)
                ~text_signal:(Signal.map (fun current -> tr source (Auth_flow.submit_label (form current))) source)
                ~on_press:(action send Auth_flow.Submit) [
                  text ~grow:1.0 ~text_alignment:`center ~style_class:"headline"
                    ~foreground_signal:(Signal.map (fun enabled -> if enabled then "auth-action-text" else "auth-disabled-text") can_submit)
                    ~value_signal:(Signal.map (fun current -> tr source (Auth_flow.submit_label (form current))) source) [];
                ]]);
          dyn (fun stage -> row ~main:`center ~cross:`center ~gap:8 (match stage with
            | Auth_flow.Login -> [link "button.auth.create-account" "Sign up" (Auth_flow.Navigate Register);
                text ~value:"·" ~foreground:"muted-foreground" [];
                link "button.auth.forgot-password" "Forgot password?" (Auth_flow.Navigate ForgotPassword)]
            | ConfirmRegistration -> [link "button.auth.resend-code" "Resend code" Auth_flow.Resend;
                link "button.auth.back" "Back to login" (Auth_flow.Navigate Login)]
            | _ -> [link "button.auth.back" "Back to login" (Auth_flow.Navigate Login)]))
            (Signal.map (fun current -> (form current).stage) source);
        ];
      ];
      toolbar ~orientation:`horizontal ~label:(tr source "Authentication") [
        spacer ~grow:1.0 [];
        button ~icon:(`app "close") ~label:(tr source "Close") ~variant:`ghost
          ~style_class:"confirmation-action plain-action" ~min_width:44 ~min_height:44
          ~accessibility_identifier:"button.auth.cancel" ~disabled_signal:busy
          ~on_press:(action send Auth_flow.Cancel) [];
      ];
    ])
