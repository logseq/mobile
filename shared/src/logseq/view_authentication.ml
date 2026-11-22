open Lui_protocol
open Lui_elements

let form (current : Model.logseq_model) = current.authentication_form
let send_action send action = Model.AuthenticationForm action |> send |> ignore
let action send value = fun _ -> send_action send value
let tr source value = View_base.tr (Signal.sample source) value

let mobile_input kind control : t = custom (fun context parent ->
  let scope = Lui_ui.extension context "native-auth-input" in
  Lui_ui.extension_property context scope "kind" (StringValue kind);
  ignore (mount context ~parent:scope control);
  attach context parent scope;
  scope)

let field source send key label kind =
  let value (current : Model.logseq_model) =
    let t = form current in
    match key with
    | "email" -> t.email | "username" -> t.username | "password" -> t.password
    | "password-confirmation" -> t.confirmation | "code" -> t.code
    | key -> Option.value ~default:"" (List.assoc_opt
        (String.sub key 10 (String.length key - 10)) t.attributes) in
  let input = if kind = "password" || kind = "new-password" then secure_field else text_field in
  custom (fun context parent ->
    let android = Lui_ui.host context = KotlinHost in
    let field_style value = if android then None else Some value in
    let control =
      input ~accessibility_identifier:("field.auth." ^ key)
        ~label:(tr source label) ~placeholder:""
        ?border_width:(field_style 1) ?border_color:(field_style "auth-border")
        ?corner_radius:(field_style 13)
        ~text_signal:(Signal.map value source)
        ~disabled_signal:(Signal.map (fun current -> Auth_flow.busy (form current)) source)
        ~on_input:(on_input send (fun value -> Model.AuthenticationForm (Auth_flow.Edit (key, value))))
        ~on_submit:(action send Auth_flow.Submit) [] in
    (* Compose's outlined control fills its parent in a form and supplies its own border. *)
    let control = if android then column ~style_class:"form" [control] else control in
    mount context ?parent
      (column ~key:("auth." ^ key) ~gap:6 ~cross:`stretch [
        text ~padding_horizontal:(if android then 0 else 14)
          ~value:(tr source label) ~foreground:"muted-foreground" ~style_class:"subheadline" [];
        mobile_input kind control;
      ]))

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
      ~value:(reactive (fun current -> (form current).setup_secret) source) []; code]

let theme_tokens =
  let open Lui_ui in
  [
    "muted-foreground", Adaptive { light = "#686E6B"; dark = "#FFFFFFB3" };
    "input", Adaptive { light = "#FFFFFF"; dark = "#00000000" };
    "auth-border", Adaptive { light = "#858E88"; dark = "#FFFFFF66" };
    "auth-action", Adaptive { light = "#101312"; dark = View_base.dark_accent };
    "auth-action-text", Adaptive { light = "#FFFFFF"; dark = "#002D38" };
    "auth-disabled", Adaptive { light = "#E2E6E2"; dark = "#FFFFFF14" };
    "auth-disabled-text", Adaptive { light = "#5D655F"; dark = "#FFFFFF8C" };
  ]

let sheet source send : t =
  let busy = Signal.map (fun current -> Auth_flow.busy (form current)) source in
  let link id label event = button ~variant:`ghost ~text:(tr source label) ~min_height:44
      ~text_alignment:`center ~accessibility_identifier:id ~disabled_signal:busy ~on_press:(action send event) [] in
  let can_submit = Signal.map (fun current -> Auth_flow.can_submit (form current)) source in
  custom (fun context parent ->
  let android = Lui_ui.host context = KotlinHost in
  let title = Signal.map (fun current -> tr source (Auth_flow.title (form current))) source in
  (* SwiftUI renders the sheet outside the node tree. Scope these tokens to its content. *)
  let content = themed ~tokens:theme_tokens (
      scroll ~accessibility_identifier:"scroll.authentication" [
        column ~gap:16 ~padding_horizontal:20 ~padding_vertical:20 ~max_width:480 ~cross:`stretch [
          if_ ~test:(Signal.map (fun current -> match (form current).stage with
            | Auth_flow.Login | Register | ForgotPassword -> false | _ -> true) source)
            (text ~foreground:"muted-foreground" ~style_class:"footnote"
              ~value:(reactive (fun current -> tr source (Auth_flow.description (form current))) source) []);
          reactive (fun (stage, attributes, choices) ->
            column ~gap:16 ~cross:`stretch (fields source send stage attributes choices))
            (Signal.map (fun current -> let t = form current in
              t.stage, List.map fst t.attributes, t.mfa_choices) source);
          if_ ~test:(Signal.map (fun current -> (form current).error <> None) source)
            (text ~accessibility_identifier:"auth.error" ~foreground:"destructive" ~style_class:"footnote"
              ~value:(reactive (fun current -> tr source (Option.value ~default:"" (form current).error)) source) []);
          if_ ~test:(Signal.map (fun current -> (form current).notice <> None) source)
            (text ~accessibility_identifier:"auth.notice" ~foreground:"muted-foreground" ~style_class:"footnote"
              ~value:(reactive (fun current -> tr source (Option.value ~default:"" (form current).notice)) source) []);
          if_ ~test:busy (spinner ~accessibility_identifier:"auth.loading" []);
          if_ ~test:(Signal.map (fun current -> (form current).stage <> Auth_flow.SelectMfa) source)
            (row ~cross:`center ~corner_radius:28
              ~background_signal:(Signal.map (fun enabled -> if enabled then "auth-action" else "auth-disabled") can_submit)
              [button ~variant:`ghost ~min_height:54 ~size:`lg ~grow:1.0
                ~accessibility_identifier:"button.auth.submit"
                ?text_alignment:(if android then None else Some `center)
                ~disabled_signal:(Signal.map not can_submit)
                ~text:(reactive (fun current -> tr source (Auth_flow.submit_label (form current))) source)
                ~on_press:(action send Auth_flow.Submit) [
                  text ~grow:1.0 ~text_alignment:`center ~style_class:"headline"
                    ~foreground_signal:(Signal.map (fun enabled -> if enabled then "auth-action-text" else "auth-disabled-text") can_submit)
                    ~value:(reactive (fun current -> tr source (Auth_flow.submit_label (form current))) source) [];
                ]]);
          reactive (fun stage -> row ~main:`center ~cross:`center ~gap:8 (match stage with
            | Auth_flow.Login -> [link "button.auth.create-account" "Sign up" (Auth_flow.Navigate Register);
                text ~value:"·" ~foreground:"muted-foreground" [];
                link "button.auth.forgot-password" "Forgot password?" (Auth_flow.Navigate ForgotPassword)]
            | ConfirmRegistration -> [link "button.auth.resend-code" "Resend code" Auth_flow.Resend;
                link "button.auth.back" "Back to login" (Auth_flow.Navigate Login)]
            | _ -> [link "button.auth.back" "Back to login" (Auth_flow.Navigate Login)]))
            (Signal.map (fun current -> (form current).stage) source);
        ];
      ]) in
  let close = tr source "Close" in
  let header = row ~cross:`center ~gap:12 ~padding_horizontal:20 [
    heading ~level:`h2 ~value:(reactive title) ~grow:1.0 [];
    icon_button ~icon:(`app "close") ~label:close ~variant:`ghost ~min_height:48
      ~accessibility_identifier:"button.auth.cancel" ~disabled_signal:busy
      ~on_press:(action send Auth_flow.Cancel) [];
  ] in
  let navigation_toolbar = toolbar ~orientation:`horizontal ~label:(tr source "Authentication") [
    toolbar_button ~text:close ~variant:`ghost ~style_class:"confirmation-action" ~foreground:"foreground"
      ~accessibility_identifier:"button.auth.cancel" ~disabled_signal:busy
      ~on_press:(action send Auth_flow.Cancel) [];
  ] in
  let sheet_title = if android then Signal.constant context.ui_scheduler "" else title in
  mount context ?parent
    (View_base.sheet ~model_source:source ~title:(reactive sheet_title)
      ~height:680 ~style_class:"navigation-content navigation-inline-title"
      ~detents_signal:(Signal.map (fun current -> match (form current).stage with
        | Auth_flow.Register | NewPassword -> "0.82,large"
        | ForgotPassword -> "0.48,large"
        | Login -> "0.54,large"
        | _ -> "0.62,large") source)
      ~accessibility_identifier:"sheet.authentication"
      ~on_dismiss:(action send Auth_flow.Dismiss)
      (if android then [header; content] else [content; navigation_toolbar])))
