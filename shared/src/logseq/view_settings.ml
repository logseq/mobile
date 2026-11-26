open Lui_protocol
open Lui_elements

let with_native_control_tint role (control : t) : t =
 custom (fun context parent ->
   match Lui_ui.profile context with
   | { profile_os = IOS; profile_host = SwiftUIHost } ->
     let tweak = Lui_ui.platform_tweak context "native-control-tint" in
     Lui_ui.extension_property context tweak "role" (StringValue role);
     ignore (mount context ~parent:tweak control);
     attach context parent tweak;
     tweak
   | _ -> mount context ?parent control)

let settings_language_choice_radio model_source
    (choice_source : Model.settings_language_choice Signal.signal) send :
    radio_el =
  let choice = Signal.sample choice_source in
  radio
    ~checked_signal:
      (Signal.map
         (fun (model : Model.logseq_model) ->
           Model.settings_language_choice_selected_ model choice)
         model_source)
    ~accessibility_identifier:
      (View_base.settings_language_choice_identifier choice)
    ~on_change:(fun _ ->
      ignore (send (Model.ChooseSettingsLanguage choice.id)))
    ~text:(View_base.settings_language_choice_title
             (Signal.sample model_source) choice) []

let settings_language_choice_menu_item model_source choice_source send : t =
  let choice = Signal.sample choice_source in
  menu_item
    ~text_signal:
      (Signal.map2 View_base.settings_language_choice_title model_source
         choice_source)
    ~accessibility_identifier:
      (View_base.settings_language_choice_identifier choice)
    ~on_press:(fun _ ->
      ignore (send (Model.ChooseSettingsLanguage choice.id)))
    []

let settings_language_control (context : Lui_ui.ui_context) model_source
    send : t =
  if Lui_ui.host context = KotlinHost then
    stack
      ~accessibility_identifier:"layout.settings.language-control"
      [
        select
          ~text_signal:
            (Signal.map View_base.settings_language_title model_source)
          ~label:(View_base.tr (Signal.sample model_source) "Language")
          ~accessibility_identifier:"picker.settings.language"
          ~on_press:(press send Model.OpenSettingsLanguageMenu)
          [];
        if_
          ~test:
            (Signal.map View_base.model_settings_language_menu_open_
               model_source)
          (dropdown_menu_view (dropdown_menu
             ~target:(Menu_anchor { side = `below; align = `end_; offset = 0. })
             ~min_width:220
             ~on_dismiss:(press send Model.CloseSettingsLanguageMenu)
             [
               keyed_dropdown_menu_item
                 ~source:
                   (Signal.map View_base.model_language_choices
                      model_source)
                 ~key:View_base.settings_language_choice_identifier
                 ~cmp:compare
                 ~mount:(fun choice_source ->
                   let choice = Signal.sample choice_source in
                   dropdown_menu_item
                     ~text_signal:
                       (Signal.map2
                          View_base.settings_language_choice_title
                          model_source choice_source)
                     ~selected_signal:
                       (Signal.map
                          (fun (model : Model.logseq_model) ->
                            Model.settings_language_choice_selected_
                              model choice)
                          model_source)
                     ~accessibility_identifier:
                       (View_base.settings_language_choice_identifier
                          choice)
                     ~on_press:(fun _ ->
                       ignore
                         (send (Model.ChooseSettingsLanguage choice.id)))
                     []);
             ]));
      ]
  else
    radio_group ~label:(View_base.tr (Signal.sample model_source) "Language") ~style_class:"menu"
      ~accessibility_identifier:"picker.settings.language"
      [
        keyed_radio
          ~source:(Signal.map View_base.model_language_choices model_source)
          ~key:View_base.settings_language_choice_identifier
          ~cmp:compare
          ~mount:(fun choice_source ->
            settings_language_choice_radio model_source choice_source send);
      ]
    |> with_native_control_tint "picker"

let settings_theme_picker ~id ~label ~choices ~selected ~menu_open
    ~open_menu ~close_menu ~choose context model_source send : t =
  let current = Signal.sample model_source in
  let label = View_base.tr current label in
  let picker_id = "picker.settings." ^ id in
  let option_id choice = picker_id ^ ".option." ^ choice in
  let selected_signal choice =
    Signal.map (fun model -> selected model = choice) model_source in
  if Lui_ui.host context = KotlinHost then
    stack ~accessibility_identifier:("layout.settings." ^ id ^ "-control")
      [
        select
          ~text_signal:(Signal.map (fun current ->
            match List.assoc_opt (selected current) choices with
            | Some title -> View_base.tr current title
            | None -> "") model_source)
          ~label ~accessibility_identifier:picker_id
          ~on_press:(press send open_menu) [];
        if_ ~test:(Signal.map menu_open model_source)
          (dropdown_menu_view (dropdown_menu
             ~target:(Menu_anchor { side = `below; align = `end_; offset = 0. })
             ~min_width:160 ~on_dismiss:(press send close_menu)
             (List.map (fun (choice, title) ->
               dropdown_menu_item ~text:(View_base.tr current title)
                 ~selected_signal:(selected_signal choice)
                 ~accessibility_identifier:(option_id choice)
                 ~on_press:(press send (choose choice)) []) choices)));
      ]
  else
    radio_group ~label ~style_class:"menu" ~accessibility_identifier:picker_id
      (List.map (fun (choice, title) ->
        radio ~text:(View_base.tr current title)
          ~checked_signal:(selected_signal choice)
          ~accessibility_identifier:(option_id choice)
          ~on_change:(fun _ -> ignore (send (choose choice))) []) choices)
    |> with_native_control_tint "picker"

let settings_appearance_control context model_source send =
  settings_theme_picker ~id:"appearance" ~label:"Theme"
    ~choices:[ "system", "System"; "light", "Light"; "dark", "Dark" ]
    ~selected:(fun (model : Model.logseq_model) ->
      match model.appearance with "light" | "dark" -> model.appearance | _ -> "system")
    ~menu_open:View_base.model_settings_appearance_menu_open_
    ~open_menu:Model.OpenSettingsAppearanceMenu
    ~close_menu:Model.CloseSettingsAppearanceMenu ~choose:(fun mode -> Model.ChangeAppearance mode)
    context model_source send

let settings_dark_theme_control context model_source send =
  settings_theme_picker ~id:"dark-theme" ~label:"Dark theme"
    ~choices:[ "black", "Black"; "solarized", "Solarized" ]
    ~selected:(fun (model : Model.logseq_model) -> model.dark_theme)
    ~menu_open:(fun model -> model.Model.settings_dark_theme_menu_open)
    ~open_menu:Model.OpenSettingsDarkThemeMenu
    ~close_menu:Model.CloseSettingsDarkThemeMenu ~choose:(fun theme -> Model.ChangeDarkTheme theme)
    context model_source send

let runtime_log_row record_source : t =
  column ~gap:3
    [
      row ~gap:6
        [
          if_
            ~test:(Signal.map View_base.runtime_log_error_ record_source)
            (text
               ~value:
                 (reactive View_base.runtime_log_level record_source)
               ~style_class:"caption semibold" ~foreground:"red" []);
          if_
            ~test:
              (Signal.map
                 (fun (record : Model.runtime_log_record) ->
                   not (View_base.runtime_log_error_ record))
                 record_source)
            (text
               ~value:
                 (reactive View_base.runtime_log_level record_source)
               ~style_class:"caption semibold" ~foreground:"secondary" []);
          text
            ~value:
              (reactive View_base.runtime_log_timestamp record_source)
            ~style_class:"caption" ~foreground:"secondary" [];
        ];
      text
        ~value:
          (reactive View_base.runtime_log_message record_source)
        ~style_class:"caption" [];
      separator [];
    ]

let settings_tab_row (context : Lui_ui.ui_context) model_source tab title
    send : t =
  let title = View_base.tr (Signal.sample model_source) title in
  let label_source =
    Signal.map (fun (current : Model.logseq_model) ->
        View_base.tab_toggle_label current tab)
      model_source
  in
  let toggle_disabled_source =
    Signal.map (fun (_ : Model.logseq_model) ->
        Model.required_sidebar_tab_ tab)
      model_source
  in
  let movement_visible_source =
    Signal.map (fun (current : Model.logseq_model) ->
        View_base.tab_movement_visible_ current tab)
      model_source
  in
  let up_disabled_source =
    Signal.map (fun (current : Model.logseq_model) ->
        View_base.tab_move_up_disabled_ current tab)
      model_source
  in
  let down_disabled_source =
    Signal.map (fun (current : Model.logseq_model) ->
        View_base.tab_move_down_disabled_ current tab)
      model_source
  in
  let selection_glyph_source =
    Signal.map (fun (current : Model.logseq_model) ->
        View_base.tab_selection_glyph current tab)
      model_source
  in
  let selection_icon_source =
    Signal.map (fun (current : Model.logseq_model) ->
        View_base.tab_selection_icon_name current tab)
      model_source
  in
  if Lui_ui.host context = KotlinHost then
    row ~cross:`center ~padding:8 ~background:"surface-container-low"
      ~corner_radius:12
      ~accessibility_identifier:("row.settings.tab." ^ tab)
      [
        row ~grow:1.0 ~cross:`center ~gap:8
          [
            View_base.with_label_signal label_source
              (View_base.with_string_prop_signal InlineIconName
                 selection_icon_source
                 (button ~icon_placement:`trailing ~variant:`ghost
                    ~disabled_signal:toggle_disabled_source
                    ~accessibility_identifier:
                      (View_base.tab_toggle_identifier tab)
                    ~on_press:(fun _ ->
                      ignore (send (Model.ToggleSidebarTab tab)))
                    ~text:title []));
            spacer ~grow:1.0 [];
            if_ ~test:movement_visible_source
              (icon_button ~icon:(`app "arrow-up") ~size:`icon
                 ~disabled_signal:up_disabled_source ~variant:`ghost
                 ~label:(View_base.tr (Signal.sample model_source) "Move tab up")
                 ~accessibility_identifier:(View_base.tab_up_identifier tab)
                 ~on_press:(fun _ ->
                   ignore (send (Model.MoveSidebarTab (tab, -1))))
                 []);
            if_ ~test:movement_visible_source
              (icon_button ~icon:(`app "arrow-down") ~size:`icon
                 ~disabled_signal:down_disabled_source ~variant:`ghost
                 ~label:(View_base.tr (Signal.sample model_source) "Move tab down")
                 ~accessibility_identifier:
                   (View_base.tab_down_identifier tab)
                 ~on_press:(fun _ ->
                   ignore (send (Model.MoveSidebarTab (tab, 1))))
                 []);
          ];
      ]
  else
    list_item
      ~accessibility_identifier:("row.settings.tab." ^ tab)
      [
        row ~grow:1.0 ~cross:`center ~gap:8
          [
            View_base.with_label_signal label_source
              (button ~grow:1.0 ~variant:`ghost
                 ~disabled_signal:toggle_disabled_source
                 ~accessibility_identifier:
                   (View_base.tab_toggle_identifier tab)
                 ~on_press:(fun _ ->
                   ignore (send (Model.ToggleSidebarTab tab)))
                 ~text:title []);
            text ~value:(reactive selection_glyph_source)
              ~foreground:"accent" [];
            if_ ~test:movement_visible_source
              (button ~disabled_signal:up_disabled_source ~variant:`ghost
                 ~label:(View_base.tr (Signal.sample model_source) "Move tab up")
                 ~accessibility_identifier:(View_base.tab_up_identifier tab)
                 ~on_press:(fun _ ->
                   ignore (send (Model.MoveSidebarTab (tab, -1))))
                 ~text:"\xE2\x86\x91" []);
            if_ ~test:movement_visible_source
              (button ~disabled_signal:down_disabled_source
                 ~variant:`ghost ~label:(View_base.tr (Signal.sample model_source) "Move tab down")
                 ~accessibility_identifier:
                   (View_base.tab_down_identifier tab)
                 ~on_press:(fun _ ->
                   ignore (send (Model.MoveSidebarTab (tab, 1))))
                 ~text:"\xE2\x86\x93" []);
          ];
      ]

let settings_tabs_screen (context : Lui_ui.ui_context) model_source send :
    t =
  if Lui_ui.host context = KotlinHost then
    column ~grow:1.0 ~cross:`stretch ~gap:10 ~padding:16
      ~accessibility_identifier:"screen.settings.tabs"
      [
        text ~style_class:"headline" ~foreground:"muted-foreground"
          ~value:(View_base.tr (Signal.sample model_source) "Visible tabs") [];
        list ~grow:1.0 ~gap:8
          ~accessibility_identifier:"list.settings.tabs"
          [
            settings_tab_row context model_source "journals" "Journals"
              send;
            if_
              ~test:
                (Signal.map View_base.settings_flashcards_before_graphs_
                   model_source)
              (settings_tab_row context model_source "flashcards"
                 "Flashcards" send);
            settings_tab_row context model_source "graphs" "Graphs" send;
            if_
              ~test:
                (Signal.map View_base.settings_flashcards_after_graphs_
                   model_source)
              (settings_tab_row context model_source "flashcards"
                 "Flashcards" send);
            text ~style_class:"footnote" ~foreground:"muted-foreground"
              ~value:
                (View_base.tr (Signal.sample model_source)
                   "Journals and Graphs are always available. Use the arrows to reorder tabs.")
              [];
            if_
              ~test:
                (Signal.map View_base.settings_available_tabs_present_
                   model_source)
              (text ~style_class:"headline" ~foreground:"muted-foreground"
                 ~accessibility_identifier:"text.settings.tabs.available"
                 ~value:(View_base.tr (Signal.sample model_source) "Available tabs") []);
            if_
              ~test:
                (Signal.map View_base.settings_available_tabs_present_
                   model_source)
              (settings_tab_row context model_source "flashcards"
                 "Flashcards" send);
          ];
      ]
  else
    list ~accessibility_identifier:"screen.settings.tabs"
      [
        heading ~level:`h3 ~value:(View_base.tr (Signal.sample model_source) "Visible tabs") [];
        settings_tab_row context model_source "journals" "Journals" send;
        if_
          ~test:
            (Signal.map View_base.settings_flashcards_before_graphs_
               model_source)
          (settings_tab_row context model_source "flashcards"
             "Flashcards" send);
        settings_tab_row context model_source "graphs" "Graphs" send;
        if_
          ~test:
            (Signal.map View_base.settings_flashcards_after_graphs_
               model_source)
          (settings_tab_row context model_source "flashcards"
             "Flashcards" send);
        text ~style_class:"footnote" ~foreground:"muted-foreground"
          ~value:
            (View_base.tr (Signal.sample model_source)
               "Journals and Graphs are always available. Use the arrows to reorder tabs.")
          [];
        if_
          ~test:
            (Signal.map View_base.settings_available_tabs_present_
               model_source)
          (heading ~level:`h3
             ~accessibility_identifier:"text.settings.tabs.available"
             ~value:(View_base.tr (Signal.sample model_source) "Available tabs") []);
        if_
          ~test:
            (Signal.map View_base.settings_available_tabs_present_
               model_source)
          (settings_tab_row context model_source "flashcards"
             "Flashcards" send);
      ]

let runtime_log_toolbar (context : Lui_ui.ui_context) model_source send : t
    =
  let log_button text_signal label identifier action : toolbar_el =
      Lui_elements.toolbar_button ~label ~text:(reactive text_signal) ~variant:`secondary
         ~accessibility_identifier:identifier
         ~on_press:(press send action)
         []
  in
  if Lui_ui.host context = KotlinHost then
    column ~gap:8 ~cross:`stretch
      [
        toolbar ~orientation:`horizontal ~toolbar_gap:8
          ~label:(View_base.tr (Signal.sample model_source) "Log filters")
          ~accessibility_identifier:"toolbar.log-filters.primary"
          [
            log_button
              (Signal.map View_base.runtime_log_errors_label model_source)
              "Toggle error filtering" "button.log-errors"
              Model.ToggleRuntimeLogErrors;
            log_button
              (Signal.map View_base.runtime_log_order_label model_source)
              "Toggle log ordering" "button.log-order"
              Model.ToggleRuntimeLogOrder;
          ];
        toolbar ~orientation:`horizontal ~toolbar_gap:8
          ~label:(View_base.tr (Signal.sample model_source) "Log actions")
          ~accessibility_identifier:"toolbar.log-filters.secondary"
          [
            log_button
              (Signal.map View_base.runtime_log_source_label model_source)
              "Toggle log source" "button.log-source"
              Model.ToggleRuntimeLogSource;
            Lui_elements.toolbar_button ~variant:`secondary
              ~accessibility_identifier:"button.log-copy"
              ~on_press:(press send Model.CopyRuntimeLog)
              ~text:(View_base.tr (Signal.sample model_source) "Copy") [];
          ];
      ]
  else
    toolbar ~orientation:`horizontal ~style_class:"scroll" ~toolbar_gap:8
      ~label:(View_base.tr (Signal.sample model_source) "Log filters")
      [
        log_button
          (Signal.map View_base.runtime_log_errors_label model_source)
          "Toggle error filtering" "button.log-errors"
          Model.ToggleRuntimeLogErrors;
        log_button
          (Signal.map View_base.runtime_log_order_label model_source)
          "Toggle log ordering" "button.log-order"
          Model.ToggleRuntimeLogOrder;
        log_button
          (Signal.map View_base.runtime_log_source_label model_source)
          "Toggle log source" "button.log-source"
          Model.ToggleRuntimeLogSource;
        Lui_elements.toolbar_button ~variant:`secondary
          ~accessibility_identifier:"button.log-copy"
          ~on_press:(press send Model.CopyRuntimeLog)
          ~text:(View_base.tr (Signal.sample model_source) "Copy") [];
      ]

let runtime_last_error model_source : t =
  keyed ~source:(Signal.map (fun (model : Model.logseq_model) ->
      Option.to_list model.runtime_log_last_error) model_source)
    ~key:View_base.runtime_log_record_identifier ~cmp:compare
    ~mount:(fun record ->
      column ~gap:6 ~accessibility_identifier:"log.last-error"
        [ heading ~level:`h5 ~value:(View_base.tr (Signal.sample model_source) "Last error") [];
          text ~style_class:"caption" ~foreground:"muted-foreground"
            ~value:(reactive (fun (value : Model.runtime_log_record) ->
              value.timestamp ^ " · " ^ String.uppercase_ascii value.source) record) [];
          text ~style_class:"caption" ~accessibility_identifier:"log.last-error.message"
            ~value:(reactive (Signal.map View_base.runtime_log_message record)) [];
          separator [] ])

let runtime_log_screen (context : Lui_ui.ui_context) model_source send : t =
  column ~gap:12 ~padding:16 ~grow:1.0
    ~accessibility_identifier:"screen.runtime-log" ~background:"background"
    [
      runtime_log_toolbar context model_source send;
      scroll ~grow:1.0
        [
          column ~gap:10
            [
              runtime_last_error model_source;
              if_
                ~test:(Signal.map View_base.runtime_log_empty_
                         model_source)
                (text ~foreground:"secondary" ~value:(View_base.tr (Signal.sample model_source) "No log entries") []);
              keyed
                ~source:(Signal.map View_base.runtime_log_records
                           model_source)
                ~key:View_base.runtime_log_record_identifier
                ~cmp:compare ~mount:runtime_log_row;
            ];
        ];
    ]

let settings_toggle_spell_check send enabled =
  ignore (send (Model.ToggleSpellCheck enabled))

let settings_toggle_auto_correction send enabled =
  ignore (send (Model.ToggleAutoCorrection enabled))

let settings_push_controls context model_source send =
  let current = Signal.sample model_source in
  let disabled_signal = Signal.map Model.saving_push_preferences model_source in
  let setting id label value update =
    let checked_signal = Signal.map (fun model -> value model.Model.push_preferences) model_source in
    let on_toggle enabled =
      let current = (Signal.sample model_source).Model.push_preferences in
      ignore (send (Model.SetPushPreference (update current enabled))) in
    let accessibility_identifier = "switch.settings.push." ^ id in
    let text = View_base.tr current label in
    if Lui_ui.host context = KotlinHost then
      switch_ ~min_height:56 ~padding_horizontal:16 ~checked_signal ~disabled_signal ~accessibility_identifier
        ~on_toggle ~text []
    else
      with_native_control_tint "switch" (toggle ~checked_signal ~disabled_signal ~accessibility_identifier
        ~on_toggle ~text []) in
  [
    setting "enabled" "Enable system notifications" (fun p -> p.Model.enabled) (fun p enabled -> {p with Model.enabled});
    setting "comments" "Comments" (fun p -> p.Model.comments) (fun p comments -> {p with Model.comments});
    setting "reactions" "Reactions" (fun p -> p.Model.reactions) (fun p reactions -> {p with Model.reactions});
    if_ ~test:(Signal.map (fun model -> model.Model.push_error <> None) model_source)
      (text ~value:(reactive (Signal.map (fun model ->
        Option.fold ~none:"" ~some:(View_base.tr current) model.Model.push_error) model_source))
        ~foreground:"error-foreground" ~style_class:"caption" []);
  ]

let settings_export_row model_source (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    list_item ~icon:(`app "download") ~padding:0
      ~accessibility_identifier:"button.export-graph-database"
      ~on_press:(press send Model.ExportGraphDatabase)
      ~text:(View_base.tr (Signal.sample model_source) "Export Graph SQLite DB") []
  else
    list_item ~padding:0
      ~accessibility_identifier:"button.export-graph-database"
      ~on_press:(press send Model.ExportGraphDatabase)
      ~text:(View_base.tr (Signal.sample model_source) "Export Graph SQLite DB") []

let settings_runtime_log_row model_source (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    list_item ~icon:(`app "terminal") ~padding:0
      ~accessibility_identifier:"button.runtime-log"
      ~on_press:(press send Model.OpenRuntimeLog)
      ~text:(View_base.tr (Signal.sample model_source) "Check log") []
  else
    list_item ~padding:0 ~accessibility_identifier:"button.runtime-log"
      ~on_press:(press send Model.OpenRuntimeLog)
      ~text:(View_base.tr (Signal.sample model_source) "Check log") []

let settings_sign_out_row model_source (context : Lui_ui.ui_context) send : t =
  let label = View_base.tr (Signal.sample model_source) "Sign Out" in
  let id = "button.sign-out" in
  let on_press = press send Model.RequestSignOut in
  if Lui_ui.host context = KotlinHost then
    list_item ~padding:0 ~accessibility_identifier:id ~on_press
      [icon ~name:(`app "sign-out") ~width:24 ~height:24 ~foreground:"error-foreground" [];
       text ~value:label ~foreground:"error-foreground" []]
  else
    list_item ~foreground:"red" ~accessibility_identifier:id ~on_press ~text:label []

let sign_in_label ?(centered = false) model_source : t =
  row ~main:(if centered then `center else `start) ~gap:8 ~cross:`center [
    if_ ~test:(Signal.map View_base.authentication_signing_in_ model_source)
      (spinner ~width:16 ~height:16 ~accessibility_identifier:"sign-in.loading" []);
    text ~value:(reactive (Signal.map (fun current ->
      if View_base.authentication_signing_in_ current then "Signing in…" else "Sign in") model_source)) [];
  ]

let settings_account_row model_source send : t =
  let signed_out = Signal.map View_base.authentication_required_ model_source in
  column ~gap:8 [
    if_ ~test:signed_out
      (list_item ~accessibility_identifier:"button.sign-in"
         ~disabled_signal:(Signal.map View_base.authentication_signing_in_ model_source)
         ~on_press:(press send Model.SignIn) [sign_in_label model_source]);
    if_ ~test:(Signal.map not signed_out)
      (list_item ~padding:0 ~accessibility_identifier:"button.settings.account-profile"
        ~on_press:(press send Model.OpenAccountProfile)
        ~text:(View_base.tr (Signal.sample model_source) "Edit Profile") []);
  ]

let sign_out_dialog model_source (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    dialog ~text:(View_base.tr (Signal.sample model_source) "Sign out?") ~height:280
      ~accessibility_identifier:"dialog.sign-out"
      ~on_dismiss:(press send Model.CancelSignOut)
      [
        column ~gap:16 ~cross:`stretch
          [
            text
              ~value:
                "Sync will pause. Downloaded graphs remain available on this device."
              ~grow:1.0 [];
            spacer ~grow:1.0 [];
            row ~main:`end_
              [
                toolbar ~orientation:`horizontal ~toolbar_gap:12
                  ~label:(View_base.tr (Signal.sample model_source) "Sign out actions")
                  ~accessibility_identifier:"toolbar.sign-out"
                  [
                    Lui_elements.toolbar_button ~variant:`ghost ~style_class:"cancellation-action"
                      ~accessibility_identifier:
                        "button.sign-out.cancel"
                      ~on_press:(press send Model.CancelSignOut)
                      ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
                    Lui_elements.toolbar_button ~variant:`destructive
                      ~accessibility_identifier:
                        "button.sign-out.confirm"
                      ~on_press:(press send Model.SignOut)
                      ~text:(View_base.tr (Signal.sample model_source) "Sign Out") [];
                  ];
              ];
          ];
      ]
  else
    (* Text-and-buttons-only children keep the dialog on the native alert
       path (rich children fall back to a custom sheet). *)
    dialog ~text:(View_base.tr (Signal.sample model_source) "Sign out?") ~style_class:"alert"
      ~accessibility_identifier:"dialog.sign-out"
      ~on_dismiss:(press send Model.CancelSignOut)
      [
        text
          ~value:
            "Sync will pause. Downloaded graphs remain available on this device."
          [];
        button ~style_class:"cancellation-action"
          ~accessibility_identifier:"button.sign-out.cancel"
          ~on_press:(press send Model.CancelSignOut)
          ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
        button ~variant:`destructive
          ~accessibility_identifier:"button.sign-out.confirm"
          ~on_press:(press send Model.SignOut)
          ~text:(View_base.tr (Signal.sample model_source) "Sign Out") [];
      ]

let settings_section_slug = function
  | Model.SettingsHome -> "home"
  | Model.SettingsAccount -> "account"
  | Model.SettingsGeneral -> "general"
  | Model.SettingsEditor -> "editor"
  | Model.SettingsNotifications -> "notifications"
  | Model.SettingsSyncServer -> "sync-server"
  | Model.SettingsAdvanced -> "advanced"
  | Model.SettingsAbout -> "about"
  | Model.SettingsCommunity -> "community"

let settings_section_title = function
  | Model.SettingsHome -> "Settings"
  | Model.SettingsAccount -> "Account"
  | Model.SettingsGeneral -> "General"
  | Model.SettingsEditor -> "Editor"
  | Model.SettingsNotifications -> "Notifications"
  | Model.SettingsSyncServer -> "Sync server"
  | Model.SettingsAdvanced -> "Advanced"
  | Model.SettingsAbout -> "About"
  | Model.SettingsCommunity -> "Community"

let settings_section_icon = function
  | Model.SettingsAccount -> "account"
  | Model.SettingsGeneral -> "settings"
  | Model.SettingsEditor -> "edit"
  | Model.SettingsNotifications -> "tab-notifications"
  | Model.SettingsSyncServer -> "graph-remote"
  | Model.SettingsAdvanced -> "terminal"
  | Model.SettingsAbout -> "info"
  | Model.SettingsCommunity -> "open-external"
  | Model.SettingsHome -> "settings"

let settings_sheet_title (current : Model.logseq_model) =
  View_base.tr current (settings_section_title current.settings_section)

let settings_can_sign_out model_source =
  Signal.map (fun current -> not (View_base.authentication_required_ current)) model_source

let settings_blank_section () : t = heading ~value:"" []

let settings_category_row model_source section send : t =
  let current = Signal.sample model_source in
  let title = View_base.tr current (settings_section_title section) in
  let slug = settings_section_slug section in
  list_item ~min_height:52
    ~accessibility_identifier:("link.settings." ^ slug)
    ~on_press:(press send (Model.OpenSettingsSection section))
    [
      row ~grow:1.0 ~cross:`center ~gap:12
        [
          icon ~name:(`app (settings_section_icon section)) ~width:20 ~height:20
            ~foreground:"foreground"
            ~accessibility_identifier:("icon.settings." ^ slug) [];
          text ~value:title [];
          spacer ~grow:1.0 [];
          icon ~name:(`app "chevron-right") ~width:18 ~height:18
            ~foreground:"muted-foreground" [];
        ];
    ]

let settings_android_card rows : t =
  column ~gap:0 ~cross:`stretch ~background:"card" ~corner_radius:20 rows

let settings_tabs_link_row (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    list_item ~min_height:56
      ~accessibility_identifier:"link.settings.tabs"
      ~on_press:(press send Model.OpenSettingsTabs)
      [
        row ~grow:1.0 ~cross:`center ~gap:12
          [
            column ~grow:1.0 ~gap:2
              ~accessibility_identifier:"layout.settings.tabs-copy"
              [
                text ~value:(View_base.tr (Signal.sample model_source) "Tabs") [];
                text
                  ~value:(reactive (Signal.map View_base.settings_tabs_summary model_source))
                  ~style_class:"footnote" ~foreground:"muted-foreground"
                  ~accessibility_identifier:"text.settings.tabs.selection" [];
              ];
            icon ~name:(`app "chevron-right") ~width:20 ~height:20
              ~foreground:"muted-foreground"
              ~accessibility_identifier:"icon.settings.tabs" [];
          ];
      ]
  else
    list_item ~accessibility_identifier:"link.settings.tabs"
      ~on_press:(press send Model.OpenSettingsTabs)
      [
        row ~grow:1.0 ~cross:`center
          [
            text ~value:(View_base.tr (Signal.sample model_source) "Tabs") [];
            spacer ~grow:1.0 [];
            text
              ~value:(reactive (Signal.map View_base.settings_tabs_summary model_source))
              ~style_class:"single-line" ~foreground:"secondary"
              ~accessibility_identifier:"text.settings.tabs.selection" [];
            icon ~name:(`app "chevron-right") ~width:16 ~height:16
              ~foreground:"muted-foreground" [];
          ];
      ]

let settings_home_screen (context : Lui_ui.ui_context) model_source send : t =
  let can_sign_out = settings_can_sign_out model_source in
  let category section = settings_category_row model_source section send in
  let advanced_row =
    if_
      ~test:(Signal.map View_base.selected_graph_local_ model_source)
      (category Model.SettingsAdvanced)
  in
  if Lui_ui.host context = KotlinHost then
    column ~gap:20 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
      ~accessibility_identifier:"screen.settings"
      [
        settings_android_card [ category Model.SettingsAccount ];
        settings_android_card
          [
            category Model.SettingsGeneral;
            category Model.SettingsEditor;
            category Model.SettingsNotifications;
            category Model.SettingsSyncServer;
            advanced_row;
            category Model.SettingsAbout;
            category Model.SettingsCommunity;
          ];
        if_ ~test:can_sign_out
          (settings_android_card [ settings_sign_out_row model_source context send ]);
      ]
  else
    column ~style_class:"form"
      ~accessibility_identifier:"screen.settings"
      [
        category Model.SettingsAccount;
        settings_blank_section ();
        category Model.SettingsGeneral;
        category Model.SettingsEditor;
        category Model.SettingsNotifications;
        category Model.SettingsSyncServer;
        advanced_row;
        category Model.SettingsAbout;
        category Model.SettingsCommunity;
        if_ ~test:can_sign_out (settings_blank_section ());
        if_ ~test:can_sign_out (settings_sign_out_row model_source context send);
      ]

let settings_general_detail_screen (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    column ~gap:16 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
      ~accessibility_identifier:"screen.settings"
      [
        settings_android_card
          [
            settings_appearance_control context model_source send;
            settings_dark_theme_control context model_source send;
            settings_language_control context model_source send;
            settings_tabs_link_row context model_source send;
          ];
      ]
  else
    column ~style_class:"form"
      ~accessibility_identifier:"screen.settings"
      [
        settings_appearance_control context model_source send;
        settings_dark_theme_control context model_source send;
        settings_language_control context model_source send;
        settings_tabs_link_row context model_source send;
      ]

let settings_editor_detail_screen (context : Lui_ui.ui_context) model_source send : t =
  let spell_check = Signal.map View_base.settings_spell_check model_source in
  let auto_correction = Signal.map View_base.settings_auto_correction model_source in
  if Lui_ui.host context = KotlinHost then
    column ~gap:16 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
      ~accessibility_identifier:"screen.settings"
      [
        settings_android_card
          [
            switch_ ~min_height:56 ~padding_horizontal:16 ~checked_signal:spell_check
              ~accessibility_identifier:"switch.settings.spell-check"
              ~on_toggle:(settings_toggle_spell_check send)
              ~text:(View_base.tr (Signal.sample model_source) "Spell check") [];
            switch_ ~min_height:56 ~padding_horizontal:16 ~checked_signal:auto_correction
              ~accessibility_identifier:"switch.settings.auto-correction"
              ~on_toggle:(settings_toggle_auto_correction send)
              ~text:(View_base.tr (Signal.sample model_source) "Auto-correction") [];
          ];
      ]
  else
    column ~style_class:"form"
      ~accessibility_identifier:"screen.settings"
      [
        with_native_control_tint "switch"
          (toggle ~checked_signal:spell_check
             ~accessibility_identifier:"switch.settings.spell-check"
             ~on_toggle:(settings_toggle_spell_check send)
             ~text:(View_base.tr (Signal.sample model_source) "Spell check") []);
        with_native_control_tint "switch"
          (toggle ~checked_signal:auto_correction
             ~accessibility_identifier:"switch.settings.auto-correction"
             ~on_toggle:(settings_toggle_auto_correction send)
             ~text:(View_base.tr (Signal.sample model_source) "Auto-correction") []);
      ]

let settings_notifications_detail_screen (context : Lui_ui.ui_context) model_source send : t =
  let controls = settings_push_controls context model_source send in
  if Lui_ui.host context = KotlinHost then
    column ~gap:16 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
      ~accessibility_identifier:"screen.settings"
      [ settings_android_card controls ]
  else
    column ~style_class:"form"
      ~accessibility_identifier:"screen.settings" controls

let settings_sync_detail_screen (context : Lui_ui.ui_context) model_source send : t =
  let field =
    text_field
      ~text_signal:(Signal.map View_base.settings_base_url model_source)
      ~placeholder:(View_base.tr (Signal.sample model_source) "Server URL")
      ~label:(View_base.tr (Signal.sample model_source) "Server URL")
      ~accessibility_identifier:"field.base-url"
      ~on_input:(on_input send (fun text -> Model.ChangeBaseURL text))
      []
  in
  let error =
    if_
      ~test:(Signal.map View_base.settings_base_url_invalid_ model_source)
      (text ~foreground:"error-foreground"
         ~value:(View_base.tr (Signal.sample model_source) "Enter a valid HTTP or HTTPS URL.") [])
  in
  if Lui_ui.host context = KotlinHost then
    column ~gap:16 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
      ~accessibility_identifier:"screen.settings"
      [ settings_android_card [ column ~gap:8 ~padding:16 ~cross:`stretch [ field; error ] ] ]
  else
    column ~style_class:"form"
      ~accessibility_identifier:"screen.settings" [ field; error ]

let settings_advanced_detail_screen (context : Lui_ui.ui_context) model_source send : t =
  let rows = [ settings_export_row model_source context send ] in
  if Lui_ui.host context = KotlinHost then
    column ~gap:16 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
      ~accessibility_identifier:"screen.settings"
      [ settings_android_card rows ]
  else
    column ~style_class:"form"
      ~accessibility_identifier:"screen.settings" rows

let settings_about_detail_screen (context : Lui_ui.ui_context) model_source send : t =
  let version_row label value_signal identifier : t =
    let children =
      [
        text ~value:(View_base.tr (Signal.sample model_source) label) [];
        spacer ~grow:1.0 [];
        text ~value:(reactive value_signal) ~foreground:"secondary" [];
      ]
    in
    if Lui_ui.host context = KotlinHost then
      list_item ~accessibility_identifier:identifier
        [ row ~grow:1.0 ~cross:`center children ]
    else
      row ~cross:`center ~accessibility_identifier:identifier children
  in
  let rows =
    [
      version_row "Version" (Signal.map View_base.settings_version model_source) "row.settings.version";
      version_row "Revision" (Signal.map View_base.settings_revision model_source) "row.settings.revision";
      settings_runtime_log_row model_source context send;
    ]
  in
  if Lui_ui.host context = KotlinHost then
    column ~gap:16 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
      ~accessibility_identifier:"screen.settings"
      [ settings_android_card rows ]
  else
    column ~style_class:"form"
      ~accessibility_identifier:"screen.settings" rows

let settings_community_detail_screen (context : Lui_ui.ui_context) model_source send : t =
  let links =
    keyed
      ~source:(Signal.map View_base.model_community_links model_source)
      ~key:View_base.settings_community_link_identifier
      ~cmp:compare
      ~mount:(fun link_source ->
        list_item
          ~text_signal:(Signal.map2 View_base.settings_community_link_title model_source link_source)
          ~icon:(`app "open-external")
          ~accessibility_identifier:(View_base.settings_community_link_identifier (Signal.sample link_source))
          ~on_press:(fun _ ->
            ignore
              (send
                 (Model.OpenExternalURL
                    (Signal.sample link_source : Model.settings_community_link).url)))
          [])
  in
  if Lui_ui.host context = KotlinHost then
    column ~gap:16 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
      ~accessibility_identifier:"screen.settings"
      [
        settings_android_card
          [
            links;
            list_item ~icon:(`app "open-external")
              ~accessibility_identifier:"link.settings.account-deletion"
              ~on_press:(press send (Model.OpenExternalURL "https://logseq.com/account-deletion"))
              ~text:(View_base.tr (Signal.sample model_source) "Request account deletion") [];
            list_item ~icon:(`app "open-external")
              ~accessibility_identifier:"link.settings.privacy-policy"
              ~on_press:(press send (Model.OpenExternalURL "https://logseq.com/privacy-policy"))
              ~text:(View_base.tr (Signal.sample model_source) "Privacy Policy") [];
          ];
      ]
  else
    column ~style_class:"form"
      ~accessibility_identifier:"screen.settings"
      [
        links;
        list_item
          ~accessibility_identifier:"link.settings.account-deletion"
          ~on_press:(press send (Model.OpenExternalURL "https://logseq.com/account-deletion"))
          ~text:(View_base.tr (Signal.sample model_source) "Request account deletion") [];
        list_item
          ~accessibility_identifier:"link.settings.privacy-policy"
          ~on_press:(press send (Model.OpenExternalURL "https://logseq.com/privacy-policy"))
          ~text:(View_base.tr (Signal.sample model_source) "Privacy Policy") [];
      ]

let settings_detail_screen (context : Lui_ui.ui_context) model_source section send : t =
  match section with
  | Model.SettingsAccount ->
    if Lui_ui.host context = KotlinHost then
      column ~gap:16 ~padding_horizontal:16 ~padding_vertical:16 ~cross:`stretch
        ~accessibility_identifier:"screen.settings"
        [ settings_android_card [ settings_account_row model_source send ] ]
    else
      column ~style_class:"form"
        ~accessibility_identifier:"screen.settings"
        [ settings_account_row model_source send ]
  | Model.SettingsGeneral -> settings_general_detail_screen context model_source send
  | Model.SettingsEditor -> settings_editor_detail_screen context model_source send
  | Model.SettingsNotifications -> settings_notifications_detail_screen context model_source send
  | Model.SettingsSyncServer -> settings_sync_detail_screen context model_source send
  | Model.SettingsAdvanced -> settings_advanced_detail_screen context model_source send
  | Model.SettingsAbout -> settings_about_detail_screen context model_source send
  | Model.SettingsCommunity -> settings_community_detail_screen context model_source send
  | Model.SettingsHome -> settings_home_screen context model_source send

let settings_screen (context : Lui_ui.ui_context) model_source send : t =
  custom (fun context parent ->
    let own source = Signal.own_signal context.Lui_ui.ui_scope source in
    let section =
      own (Signal.map (fun (current : Model.logseq_model) -> current.settings_section) model_source)
    in
    mount context ?parent
      (reactive
         (fun section ->
           match section with
           | Model.SettingsHome -> settings_home_screen context model_source send
           | section -> settings_detail_screen context model_source section send)
         section))

let settings_action_bar (context : Lui_ui.ui_context) model_source send : t =
  custom (fun context parent ->
    let own source = Signal.own_signal context.Lui_ui.ui_scope source in
    let section =
      own (Signal.map (fun (current : Model.logseq_model) -> current.settings_section) model_source)
    in
    mount context ?parent
      (reactive
         (fun section ->
           let home = section = Model.SettingsHome in
           let back_or_cancel_action = if home then Model.DismissSettings else Model.BackSettings in
           let back_or_cancel_text =
             View_base.tr (Signal.sample model_source) (if home then "Cancel" else "Settings")
           in
           let apply =
             View_base.tr (Signal.sample model_source) "Apply"
           in
           if Lui_ui.host context = KotlinHost then
             row ~gap:12 ~main:`end_ ~padding_horizontal:24 ~padding_vertical:16
               ~background:"surface-container-low"
               ~accessibility_identifier:"toolbar.settings.actions"
               (if home then
                  [
                    spacer ~grow:1.0 [];
                    button ~variant:`ghost
                      ~accessibility_identifier:"button.connection.cancel"
                      ~on_press:(press send back_or_cancel_action)
                      ~text:back_or_cancel_text [];
                    button ~variant:`primary
                      ~accessibility_identifier:"button.connection.apply"
                      ~disabled_signal:(Signal.map View_base.settings_apply_disabled_ model_source)
                      ~on_press:(press send Model.ApplySettings)
                      ~text:apply [];
                  ]
                else
                  [
                    button ~variant:`ghost
                      ~accessibility_identifier:"button.connection.cancel"
                      ~on_press:(press send back_or_cancel_action)
                      ~text:back_or_cancel_text [];
                    spacer ~grow:1.0 [];
                    button ~variant:`primary
                      ~accessibility_identifier:"button.connection.apply"
                      ~disabled_signal:(Signal.map View_base.settings_apply_disabled_ model_source)
                      ~on_press:(press send Model.ApplySettings)
                      ~text:apply [];
                  ])
           else
             toolbar ~orientation:`horizontal
               ~label:(View_base.tr (Signal.sample model_source) "Settings actions")
               ~style_class:"navigation-actions"
               ~accessibility_identifier:"toolbar.settings.actions"
               [
                 Lui_elements.toolbar_button
                   ~style_class:(if home then "cancellation-action" else "cancellation-action navigation-back-action")
                   ~foreground:"foreground"
                   ~accessibility_identifier:"button.connection.cancel"
                   ~on_press:(press send back_or_cancel_action)
                   ~text:back_or_cancel_text [];
                 Lui_elements.toolbar_button ~style_class:"confirmation-action" ~foreground:"foreground"
                   ~accessibility_identifier:"button.connection.apply"
                   ~disabled_signal:(Signal.map View_base.settings_apply_disabled_ model_source)
                   ~on_press:(press send Model.ApplySettings)
                   ~text:apply [];
               ])
         section))

let settings_tabs_sheet (context : Lui_ui.ui_context) model_source send :
    t =
  if Lui_ui.host context = KotlinHost then
    View_base.sheet ~model_source ~title:(View_base.tr (Signal.sample model_source) "Tabs") ~style_class:"navigation-content"
      ~accessibility_identifier:"sheet.settings"
      ~on_dismiss:(press send Model.BackSettings)
      [
        column ~grow:1.0
          ~accessibility_identifier:"layout.settings.tabs-sheet"
          [
            settings_tabs_screen context model_source send;
            row ~padding_horizontal:16 ~padding_vertical:12
              ~background:"surface-container-low"
              ~accessibility_identifier:"toolbar.settings.actions"
              [
                button ~variant:`secondary ~grow:1.0
                  ~accessibility_identifier:"button.connection.cancel"
                  ~on_press:(press send Model.BackSettings)
                  ~text:(View_base.tr (Signal.sample model_source) "Back to Settings") [];
              ];
          ];
      ]
  else
    View_base.sheet ~model_source ~title:(View_base.tr (Signal.sample model_source) "Tabs") ~style_class:"navigation-list"
      ~accessibility_identifier:"sheet.settings.tabs"
      ~on_dismiss:(press send Model.BackSettings)
      [
        settings_tabs_screen context model_source send;
        toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Tabs actions")
          ~style_class:"navigation-actions"
          ~accessibility_identifier:"toolbar.settings.actions"
          [
            Lui_elements.toolbar_button ~style_class:"cancellation-action navigation-back-action" ~foreground:"foreground"
              ~accessibility_identifier:"button.connection.cancel"
              ~on_press:(press send Model.BackSettings)
              ~text:(View_base.tr (Signal.sample model_source) "Settings") [];
          ];
      ]

let runtime_log_actions model_source (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    row ~gap:12 ~padding_horizontal:16 ~padding_vertical:12
      ~background:"surface-container-low"
      ~accessibility_identifier:"toolbar.settings.actions"
      [
        button ~variant:`secondary ~grow:1.0
          ~accessibility_identifier:"button.log-refresh"
          ~on_press:(press send Model.RefreshRuntimeLog)
          ~text:(View_base.tr (Signal.sample model_source) "Refresh") [];
        button ~variant:`primary ~grow:1.0
          ~accessibility_identifier:"button.log.done"
          ~on_press:(press send Model.DismissRuntimeLog)
          ~text:(View_base.tr (Signal.sample model_source) "Done") [];
      ]
  else
    toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Log actions")
      ~style_class:"navigation-actions"
      ~accessibility_identifier:"toolbar.settings.actions"
      [
        Lui_elements.toolbar_button ~style_class:"cancellation-action" ~foreground:"foreground"
          ~accessibility_identifier:"button.log-refresh"
          ~on_press:(press send Model.RefreshRuntimeLog)
          ~text:(View_base.tr (Signal.sample model_source) "Refresh") [];
        Lui_elements.toolbar_button ~style_class:"confirmation-action" ~foreground:"foreground"
          ~accessibility_identifier:"button.log.done"
          ~on_press:(press send Model.DismissRuntimeLog)
          ~text:(View_base.tr (Signal.sample model_source) "Done") [];
      ]

let runtime_log_sheet (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    View_base.sheet ~model_source ~title:(View_base.tr (Signal.sample model_source) "Log") ~style_class:"navigation-content"
      ~accessibility_identifier:"sheet.settings"
      ~on_dismiss:(press send Model.DismissRuntimeLog)
      [
        column ~grow:1.0 ~gap:12
          ~accessibility_identifier:"layout.runtime-log.sheet"
          [
            runtime_log_screen context model_source send;
            runtime_log_actions model_source context send;
          ];
      ]
  else
    View_base.sheet ~model_source ~title:(View_base.tr (Signal.sample model_source) "Log") ~style_class:"navigation-content"
      ~accessibility_identifier:"sheet.settings.log"
      ~on_dismiss:(press send Model.DismissRuntimeLog)
      [
        runtime_log_screen context model_source send;
        runtime_log_actions model_source context send;
      ]

let settings_main_sheet (context : Lui_ui.ui_context) model_source send :
    t =
  if Lui_ui.host context = KotlinHost then
    View_base.sheet ~model_source
      ~title:(reactive (fun (current : Model.logseq_model) -> settings_sheet_title current) model_source)
      ~height:640
      ~accessibility_identifier:"sheet.settings"
      ~on_dismiss:(press send Model.BackOrDismissSettings)
      [
        column ~grow:1.0 ~gap:12
          ~accessibility_identifier:"layout.settings.sheet"
          [
            scroll ~grow:1.0 [ settings_screen context model_source send ];
            settings_action_bar context model_source send;
          ];
      ]
  else
    View_base.sheet ~model_source
      ~title:(reactive (fun (current : Model.logseq_model) -> settings_sheet_title current) model_source)
      ~style_class:"navigation-form navigation-inline-title"
      ~accessibility_identifier:"sheet.settings"
      ~on_dismiss:(press send Model.DismissSettings)
      [
        settings_screen context model_source send;
        if_
          ~test:(Signal.map View_base.settings_tabs_visible_ model_source)
          (settings_tabs_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.runtime_log_visible_ model_source)
          (runtime_log_sheet context model_source send);
        settings_action_bar context model_source send;
      ]

let settings_sheet (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    stack
      [
        if_
          ~test:(Signal.map View_base.settings_main_visible_ model_source)
          (settings_main_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.settings_tabs_visible_ model_source)
          (settings_tabs_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.runtime_log_visible_ model_source)
          (runtime_log_sheet context model_source send);
      ]
  else settings_main_sheet context model_source send

let page_delete_dialog model_source (context : Lui_ui.ui_context) send : t =
  let label page block = Signal.map (fun (model : Model.logseq_model) ->
    View_base.tr model (match model.pending_node_deletion with
      | Some (Model.BlockToDelete _) -> block | _ -> page)) model_source in
  let title = label "Delete page?" "Delete block?" in
  let description = label "The page will be moved to Recycle." "The block and its children will be deleted." in
  if Lui_ui.host context = KotlinHost then
    dialog ~text_signal:title ~height:280
      ~accessibility_identifier:"dialog.page-delete"
      ~on_dismiss:(press send Model.CancelDeleteActiveNode)
      [
        column ~gap:16 ~cross:`stretch
          [
            text ~value:(reactive description) ~grow:1.0 [];
            spacer ~grow:1.0 [];
            row ~main:`end_
              [
                toolbar ~orientation:`horizontal ~toolbar_gap:12
                  ~label:(View_base.tr (Signal.sample model_source) "Page deletion actions")
                  ~accessibility_identifier:"toolbar.page-delete"
                  [
                    Lui_elements.toolbar_button ~variant:`ghost ~style_class:"cancellation-action"
                      ~accessibility_identifier:
                        "button.page-delete.cancel"
                      ~on_press:(press send Model.CancelDeleteActiveNode)
                      ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
                    Lui_elements.toolbar_button ~variant:`destructive
                      ~accessibility_identifier:
                        "button.page-delete.confirm"
                      ~on_press:(press send Model.ConfirmDeleteActiveNode)
                      ~text:(View_base.tr (Signal.sample model_source) "Delete") [];
                  ];
              ];
          ];
      ]
  else
    (* Text-and-buttons-only children keep the dialog on the native alert
       path (rich children fall back to a custom sheet). *)
    dialog ~text_signal:title ~style_class:"alert"
      ~accessibility_identifier:"dialog.page-delete"
      ~on_dismiss:(press send Model.CancelDeleteActiveNode)
      [
        text ~value:(reactive description) [];
        button ~style_class:"cancellation-action"
          ~accessibility_identifier:"button.page-delete.cancel"
          ~on_press:(press send Model.CancelDeleteActiveNode)
          ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
        button ~variant:`destructive
          ~accessibility_identifier:"button.page-delete.confirm"
          ~on_press:(press send Model.ConfirmDeleteActiveNode)
          ~text:(View_base.tr (Signal.sample model_source) "Delete") [];
      ]

let sync_status_sheet (context : Lui_ui.ui_context) model_source send : t =
  let sync_now ?variant () =
    if_ ~test:(Signal.map (fun current -> not (View_base.sync_indicator_synced current)) model_source)
      (button ?variant ~accessibility_identifier:"button.sync-now"
         ~on_press:(press send Model.SyncNow)
         ~text:(View_base.tr (Signal.sample model_source) "Sync now") [])
  in
  let sync_row identifier label value_signal : t =
    list_item ~accessibility_identifier:identifier
      [
        row ~grow:1.0 ~cross:`center ~main:`space_between
          [
            text ~value:(View_base.tr (Signal.sample model_source) label) [];
            text ~value:(reactive value_signal) ~foreground:"secondary"
              ~text_alignment:`end_ [];
          ];
      ]
  in
  if Lui_ui.host context = KotlinHost then
    View_base.sheet ~model_source ~title:(View_base.tr (Signal.sample model_source) "Sync status") ~height:480
      ~accessibility_identifier:"sheet.sync-status"
      ~on_dismiss:(press send Model.CloseSyncDetails)
      [
        column ~gap:0 ~cross:`stretch ~grow:1.0
          ~accessibility_identifier:"form.sync-status"
          [
            scroll ~grow:1.0
              [ column ~gap:12 ~cross:`stretch ~padding_horizontal:24 ~padding_vertical:16
                  [
                    sync_row "row.sync.status" "Status"
                      (Signal.map View_base.sync_label model_source);
                    sync_row "row.sync.graph" "Graph"
                      (Signal.map View_base.graph_label model_source);
                    sync_row "row.sync.connection" "Connection"
                      (Signal.map View_base.sync_connection_label model_source);
                    list_item ~accessibility_identifier:"row.sync.pending"
                      [
                        row ~grow:1.0 ~cross:`center ~main:`space_between
                          [
                            text ~value:(View_base.tr (Signal.sample model_source) "Local changes") [];
                            text
                              ~value:
                                (reactive (Signal.map View_base.sync_pending_label
                                   model_source))
                              ~foreground:"secondary" ~text_alignment:`end_
                              ~accessibility_identifier:"sync.pending" [];
                  ];
              ];
            list_item ~accessibility_identifier:"row.sync.cursor"
              [
                row ~grow:1.0 ~cross:`center ~main:`space_between
                  [
                    text ~value:(View_base.tr (Signal.sample model_source) "Remote tx") [];
                    text
                      ~value:
                        (reactive (Signal.map View_base.sync_cursor_label
                           model_source))
                      ~foreground:"secondary" ~text_alignment:`end_
                      ~accessibility_identifier:"sync.cursor" [];
                  ];
              ];


                  ];
              ];
            row ~gap:12 ~main:`end_ ~padding_horizontal:24 ~padding_vertical:16
              ~background:"surface-container-low"
              ~accessibility_identifier:"toolbar.sync.actions"
              [
                spacer ~grow:1.0 [];
                button ~variant:`ghost
                  ~accessibility_identifier:"button.sync.done"
                  ~on_press:(press send Model.CloseSyncDetails)
                  ~text:(View_base.tr (Signal.sample model_source) "Done") [];
                sync_now ~variant:`primary ();
              ];
          ];
      ]
  else
    View_base.sheet ~model_source ~title:(View_base.tr (Signal.sample model_source) "Sync status") ~style_class:"navigation-form navigation-inline-title" ~detents:"medium"
      ~accessibility_identifier:"sheet.sync-status"
      ~on_dismiss:(press send Model.CloseSyncDetails)
      [
        column ~style_class:"form"
          ~accessibility_identifier:"form.sync-status"
          [
            sync_row "row.sync.status" "Status"
              (Signal.map View_base.sync_label model_source);
          sync_row "row.sync.graph" "Graph"
            (Signal.map View_base.graph_label model_source);
          sync_row "row.sync.connection" "Connection"
            (Signal.map View_base.sync_connection_label model_source);
          list_item ~accessibility_identifier:"row.sync.pending"
            [
              row ~grow:1.0 ~cross:`center ~main:`space_between
                [
                  text ~value:(View_base.tr (Signal.sample model_source) "Local changes") [];
                  text
                    ~value:
                      (reactive (Signal.map View_base.sync_pending_label
                         model_source))
                    ~foreground:"secondary" ~text_alignment:`end_
                    ~accessibility_identifier:"sync.pending" [];
                ];
            ];
          list_item ~accessibility_identifier:"row.sync.cursor"
            [
              row ~grow:1.0 ~cross:`center ~main:`space_between
                [
                  text ~value:(View_base.tr (Signal.sample model_source) "Remote tx") [];
                  text
                    ~value:
                      (reactive (Signal.map View_base.sync_cursor_label model_source))
                    ~foreground:"secondary" ~text_alignment:`end_
                    ~accessibility_identifier:"sync.cursor" [];
                ];
            ];


          sync_now ();
        ];
      toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Sync status actions")
        ~style_class:"navigation-actions"
        ~accessibility_identifier:"toolbar.sync.actions"
        [
          Lui_elements.toolbar_button ~style_class:"confirmation-action" ~foreground:"foreground"
            ~accessibility_identifier:"button.sync.done"
            ~on_press:(press send Model.CloseSyncDetails)
            ~text:(View_base.tr (Signal.sample model_source) "Done") [];
        ];
    ]
