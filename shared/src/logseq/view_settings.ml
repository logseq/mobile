open Lui_protocol
open Lui_elements

let with_native_control_tint role (control : t) : t =
 fun context parent ->
   match Lui_ui.profile context with
   | { profile_os = IOS; profile_host = SwiftUIHost } ->
     let tweak = Lui_ui.platform_tweak context "native-control-tint" in
     Lui_ui.extension_property context tweak "role" (StringValue role);
     ignore (control context (Some tweak));
     attach context parent tweak;
     tweak
   | _ -> control context parent

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
    ~text:(View_base.settings_language_choice_title choice) []

let settings_language_choice_menu_item choice_source send : t =
  let choice = Signal.sample choice_source in
  menu_item
    ~text_signal:
      (Signal.map View_base.settings_language_choice_title choice_source)
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
          ~label:"Language"
          ~accessibility_identifier:"picker.settings.language"
          ~on_press:(press send Model.OpenSettingsLanguageMenu)
          [];
        if_
          ~test:
            (Signal.map View_base.model_settings_language_menu_open_
               model_source)
          (dropdown_menu ~anchor:`below ~anchor_alignment:`end_
             ~min_width:220
             ~on_dismiss:(press send Model.CloseSettingsLanguageMenu)
             [
               keyed
                 ~source:
                   (Signal.map View_base.model_language_choices
                      model_source)
                 ~key:View_base.settings_language_choice_identifier
                 ~cmp:compare
                 ~mount:(fun choice_source ->
                   let choice = Signal.sample choice_source in
                   menu_item
                     ~text_signal:
                       (Signal.map
                          View_base.settings_language_choice_title
                          choice_source)
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
             ]);
      ]
  else
    radio_group ~label:"Language" ~style_class:"menu"
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

let settings_appearance_control (context : Lui_ui.ui_context) model_source
    send : t =
  if Lui_ui.host context = KotlinHost then
    let appearance_item id title : t =
      menu_item ~text:title
        ~selected_signal:
          (Signal.map
             (fun (model : Model.logseq_model) -> model.appearance = id)
             model_source)
        ~accessibility_identifier:
          ("picker.settings.appearance.option." ^ id)
        ~on_press:(fun _ ->
          ignore (send (Model.ChangeAppearance id)))
        []
    in
    stack
      ~accessibility_identifier:"layout.settings.appearance-control"
      [
        select
          ~text_signal:
            (Signal.map View_base.settings_appearance_title model_source)
          ~label:"Theme"
          ~accessibility_identifier:"picker.settings.appearance"
          ~on_press:(press send Model.OpenSettingsAppearanceMenu)
          [];
        if_
          ~test:
            (Signal.map View_base.model_settings_appearance_menu_open_
               model_source)
          (dropdown_menu ~anchor:`below ~anchor_alignment:`end_
             ~min_width:160
             ~on_dismiss:(press send Model.CloseSettingsAppearanceMenu)
             [
               appearance_item "system" "System";
               appearance_item "light" "Light";
               appearance_item "dark" "Dark";
             ]);
      ]
  else
    (* Menu-style radio group renders as the native inline picker:
       label on the left, current value + dropdown on the right. *)
    radio_group ~label:"Theme" ~style_class:"menu"
      ~accessibility_identifier:"picker.settings.appearance"
      [
        radio ~text:"System"
          ~checked_signal:
            (Signal.map
               (fun (model : Model.logseq_model) ->
                 model.appearance = "system")
               model_source)
          ~accessibility_identifier:
            "picker.settings.appearance.option.system"
          ~on_change:(fun _ ->
            ignore (send (Model.ChangeAppearance "system")))
          [];
        radio ~text:"Light"
          ~checked_signal:
            (Signal.map
               (fun (model : Model.logseq_model) ->
                 model.appearance = "light")
               model_source)
          ~accessibility_identifier:
            "picker.settings.appearance.option.light"
          ~on_change:(fun _ ->
            ignore (send (Model.ChangeAppearance "light")))
          [];
        radio ~text:"Dark"
          ~checked_signal:
            (Signal.map
               (fun (model : Model.logseq_model) ->
                 model.appearance = "dark")
               model_source)
          ~accessibility_identifier:
            "picker.settings.appearance.option.dark"
          ~on_change:(fun _ ->
            ignore (send (Model.ChangeAppearance "dark")))
          [];
      ]
    |> with_native_control_tint "picker"

let settings_community_link_row (context : Lui_ui.ui_context) model_source
    link_source send : t =
  let link = Signal.sample link_source in
  if Lui_ui.host context = KotlinHost then
    column ~gap:12
      [
        list_item
          ~text_signal:
            (Signal.map View_base.settings_community_link_title
               link_source)
          ~icon:(`app "open-external") ~padding:0
          ~accessibility_identifier:
            (View_base.settings_community_link_identifier link)
          ~on_press:(fun _ ->
            ignore
              (send
                 (Model.OpenExternalURL
                    (Signal.sample link_source
                       : Model.settings_community_link).url)))
          [];
        if_
          ~test:
            (Signal.map2
               View_base.settings_community_link_needs_separator_
               model_source link_source)
          (separator []);
      ]
  else
    column ~gap:12
      [
        list_item
          ~text_signal:
            (Signal.map View_base.settings_community_link_title
               link_source)
          ~padding:0
          ~accessibility_identifier:
            (View_base.settings_community_link_identifier link)
          ~on_press:(fun _ ->
            ignore
              (send
                 (Model.OpenExternalURL
                    (Signal.sample link_source
                       : Model.settings_community_link).url)))
          [];
        if_
          ~test:
            (Signal.map2
               View_base.settings_community_link_needs_separator_
               model_source link_source)
          (separator []);
      ]

let runtime_log_row record_source : t =
  column ~gap:3
    [
      row ~gap:6
        [
          if_
            ~test:(Signal.map View_base.runtime_log_error_ record_source)
            (text
               ~value_signal:
                 (Signal.map View_base.runtime_log_level record_source)
               ~style_class:"caption semibold" ~foreground:"red" []);
          if_
            ~test:
              (Signal.map
                 (fun (record : Model.runtime_log_record) ->
                   not (View_base.runtime_log_error_ record))
                 record_source)
            (text
               ~value_signal:
                 (Signal.map View_base.runtime_log_level record_source)
               ~style_class:"caption semibold" ~foreground:"secondary" []);
          text
            ~value_signal:
              (Signal.map View_base.runtime_log_timestamp record_source)
            ~style_class:"caption" ~foreground:"secondary" [];
        ];
      text
        ~value_signal:
          (Signal.map View_base.runtime_log_message record_source)
        ~style_class:"caption" [];
      separator [];
    ]

let settings_tab_row (context : Lui_ui.ui_context) model_source tab title
    send : t =
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
            spacer [];
            if_ ~test:movement_visible_source
              (button ~icon:(`app "arrow-up") ~size:`icon
                 ~disabled_signal:up_disabled_source ~variant:`ghost
                 ~label:"Move tab up"
                 ~accessibility_identifier:(View_base.tab_up_identifier tab)
                 ~on_press:(fun _ ->
                   ignore (send (Model.MoveSidebarTab (tab, -1))))
                 []);
            if_ ~test:movement_visible_source
              (button ~icon:(`app "arrow-down") ~size:`icon
                 ~disabled_signal:down_disabled_source ~variant:`ghost
                 ~label:"Move tab down"
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
            text ~value_signal:selection_glyph_source
              ~foreground:"accent" [];
            if_ ~test:movement_visible_source
              (button ~disabled_signal:up_disabled_source ~variant:`ghost
                 ~label:"Move tab up"
                 ~accessibility_identifier:(View_base.tab_up_identifier tab)
                 ~on_press:(fun _ ->
                   ignore (send (Model.MoveSidebarTab (tab, -1))))
                 ~text:"\xE2\x86\x91" []);
            if_ ~test:movement_visible_source
              (button ~disabled_signal:down_disabled_source
                 ~variant:`ghost ~label:"Move tab down"
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
          ~value:"Visible tabs" [];
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
                "Journals and Graphs are always available. Use the \
                 arrows to reorder tabs."
              [];
            if_
              ~test:
                (Signal.map View_base.settings_available_tabs_present_
                   model_source)
              (text ~style_class:"headline" ~foreground:"muted-foreground"
                 ~accessibility_identifier:"text.settings.tabs.available"
                 ~value:"Available tabs" []);
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
        heading ~level:3 ~value:"Visible tabs" [];
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
            "Journals and Graphs are always available. Use the arrows \
             to reorder tabs."
          [];
        if_
          ~test:
            (Signal.map View_base.settings_available_tabs_present_
               model_source)
          (heading ~level:3
             ~accessibility_identifier:"text.settings.tabs.available"
             ~value:"Available tabs" []);
        if_
          ~test:
            (Signal.map View_base.settings_available_tabs_present_
               model_source)
          (settings_tab_row context model_source "flashcards"
             "Flashcards" send);
      ]

let runtime_log_toolbar (context : Lui_ui.ui_context) model_source send : t
    =
  let log_button text_signal label identifier action : t =
    View_base.with_label label
      (button ~text_signal ~variant:`secondary
         ~accessibility_identifier:identifier
         ~on_press:(press send action)
         [])
  in
  if Lui_ui.host context = KotlinHost then
    column ~gap:8 ~cross:`stretch
      [
        toolbar ~orientation:`horizontal ~toolbar_gap:8
          ~label:"Log filters"
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
          ~label:"Log actions"
          ~accessibility_identifier:"toolbar.log-filters.secondary"
          [
            log_button
              (Signal.map View_base.runtime_log_source_label model_source)
              "Toggle log source" "button.log-source"
              Model.ToggleRuntimeLogSource;
            button ~variant:`secondary
              ~accessibility_identifier:"button.log-copy"
              ~on_press:(press send Model.CopyRuntimeLog)
              ~text:"Copy" [];
          ];
      ]
  else
    toolbar ~orientation:`horizontal ~style_class:"scroll" ~toolbar_gap:8
      ~label:"Log filters"
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
        button ~variant:`secondary
          ~accessibility_identifier:"button.log-copy"
          ~on_press:(press send Model.CopyRuntimeLog)
          ~text:"Copy" [];
      ]

let runtime_log_screen (context : Lui_ui.ui_context) model_source send : t =
  column ~gap:12 ~padding:16 ~grow:1.0
    ~accessibility_identifier:"screen.runtime-log" ~background:"background"
    [
      runtime_log_toolbar context model_source send;
      scroll ~grow:1.0
        [
          column ~gap:10
            [
              if_
                ~test:(Signal.map View_base.runtime_log_empty_
                         model_source)
                (text ~foreground:"secondary" ~value:"No log entries" []);
              keyed
                ~source:(Signal.map View_base.runtime_log_records
                           model_source)
                ~key:View_base.runtime_log_record_identifier
                ~cmp:compare ~mount:runtime_log_row;
            ];
        ];
    ]

let settings_toggle_spell_check send input_event =
  match input_event with
  | ToggleChanged (_node, enabled) ->
    ignore (send (Model.ToggleSpellCheck enabled))
  | _ -> ()

let settings_toggle_auto_correction send input_event =
  match input_event with
  | ToggleChanged (_node, enabled) ->
    ignore (send (Model.ToggleAutoCorrection enabled))
  | _ -> ()

let settings_general_card (context : Lui_ui.ui_context) model_source send :
    t =
  if Lui_ui.host context = KotlinHost then
    column ~gap:0 ~cross:`stretch
      ~accessibility_identifier:"layout.settings.general-card"
      [
        settings_appearance_control context model_source send;
        settings_language_control context model_source send;
        list_item ~padding:0
          ~accessibility_identifier:"link.settings.tabs"
          ~on_press:(press send Model.OpenSettingsTabs)
          [
            row ~grow:1.0 ~cross:`center ~gap:12
              [
                column ~grow:1.0 ~gap:2
                  ~accessibility_identifier:"layout.settings.tabs-copy"
                  [
                    text ~value:"Tabs" [];
                    text
                      ~value_signal:
                        (Signal.map View_base.settings_tabs_summary
                           model_source)
                      ~style_class:"footnote"
                      ~foreground:"muted-foreground"
                      ~accessibility_identifier:
                        "text.settings.tabs.selection" [];
                  ];
                icon ~name:(`app "chevron-right") ~width:20 ~height:20
                  ~foreground:"muted-foreground"
                  ~accessibility_identifier:"icon.settings.tabs" [];
              ];
          ];
      ]
  else
    column ~gap:12 ~padding:16 ~background:"surface" ~corner_radius:14
      ~accessibility_identifier:"layout.settings.general-card"
      [
        row ~cross:`center
          [
            text ~value:"Theme" [];
            spacer [];
            settings_appearance_control context model_source send;
          ];
        separator [];
        row ~cross:`center
          [
            text ~value:"Language" [];
            spacer [];
            settings_language_control context model_source send;
          ];
        separator [];
        list_item ~padding:0
          ~accessibility_identifier:"link.settings.tabs"
          ~on_press:(press send Model.OpenSettingsTabs)
          [
            row ~grow:1.0 ~cross:`center
              [
                text ~value:"Tabs" [];
                spacer [];
                text
                  ~value_signal:
                    (Signal.map View_base.settings_tabs_summary
                       model_source)
                  ~style_class:"single-line" ~foreground:"secondary"
                  ~accessibility_identifier:"text.settings.tabs.selection"
                  [];
              ];
          ];
      ]

let settings_editor_card (context : Lui_ui.ui_context) spell_check_source
    auto_correction_source send : t =
  if Lui_ui.host context = KotlinHost then
    column ~gap:0 ~cross:`stretch ~padding_horizontal:16
      [
        switch_ ~min_height:56 ~checked_signal:spell_check_source
          ~accessibility_identifier:"switch.settings.spell-check"
          ~on_toggle:(settings_toggle_spell_check send)
          ~text:"Spell check" [];
        switch_ ~min_height:56 ~checked_signal:auto_correction_source
          ~accessibility_identifier:"switch.settings.auto-correction"
          ~on_toggle:(settings_toggle_auto_correction send)
          ~text:"Auto-correction" [];
      ]
  else
    column ~gap:12 ~padding:16 ~background:"surface" ~corner_radius:14
      [
        toggle ~checked_signal:spell_check_source
          ~on_toggle:(settings_toggle_spell_check send)
          ~text:"Spell check" [];
        separator [];
        toggle ~checked_signal:auto_correction_source
          ~on_toggle:(settings_toggle_auto_correction send)
          ~text:"Auto-correction" [];
      ]

let settings_export_row (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    list_item ~icon:(`app "download") ~padding:0
      ~accessibility_identifier:"button.export-graph-database"
      ~on_press:(press send Model.ExportGraphDatabase)
      ~text:"Export Graph SQLite DB" []
  else
    list_item ~padding:0
      ~accessibility_identifier:"button.export-graph-database"
      ~on_press:(press send Model.ExportGraphDatabase)
      ~text:"Export Graph SQLite DB" []

let settings_runtime_log_row (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    list_item ~icon:(`app "terminal") ~padding:0
      ~accessibility_identifier:"button.runtime-log"
      ~on_press:(press send Model.OpenRuntimeLog)
      ~text:"Check log" []
  else
    list_item ~padding:0 ~accessibility_identifier:"button.runtime-log"
      ~on_press:(press send Model.OpenRuntimeLog)
      ~text:"Check log" []

let settings_sign_out_row (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    list_item ~icon:(`app "sign-out") ~padding:0
      ~accessibility_identifier:"button.sign-out"
      ~on_press:(press send Model.RequestSignOut)
      ~text:"Sign Out" []
  else
    list_item ~padding:0 ~accessibility_identifier:"button.sign-out"
      ~on_press:(press send Model.RequestSignOut)
      ~text:"Sign Out" []

let sign_in_label model_source : t =
  row ~gap:8 ~cross:`center [
    if_ ~test:(Signal.map View_base.authentication_signing_in_ model_source)
      (spinner ~width:16 ~height:16 ~accessibility_identifier:"sign-in.loading" []);
    text ~value_signal:(Signal.map (fun current ->
      if View_base.authentication_signing_in_ current then "Signing in…" else "Sign in") model_source) [];
  ]

let settings_account_row context model_source send : t =
  let signed_out = Signal.map View_base.authentication_required_ model_source in
  column ~gap:8 [
    if_ ~test:signed_out
      (list_item ~accessibility_identifier:"button.hosted-sign-in"
         ~disabled_signal:(Signal.map View_base.authentication_signing_in_ model_source)
         ~on_press:(press send Model.SignIn) [sign_in_label model_source]);
    if_ ~test:(Signal.map not signed_out) (settings_sign_out_row context send);
    if_ ~test:(Signal.map (fun current ->
        View_base.authentication_required_ current
        && View_base.authentication_error_present_ current) model_source)
      (text ~foreground:"destructive"
         ~value_signal:(Signal.map View_base.authentication_error_message model_source)
         ~accessibility_identifier:"text.authentication-error" []);
  ]

let sign_out_dialog (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    dialog ~text:"Sign out?" ~height:280
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
                  ~label:"Sign out actions"
                  ~accessibility_identifier:"toolbar.sign-out"
                  [
                    button ~variant:`ghost
                      ~accessibility_identifier:
                        "button.sign-out.cancel"
                      ~on_press:(press send Model.CancelSignOut)
                      ~text:"Cancel" [];
                    button ~variant:`destructive
                      ~accessibility_identifier:
                        "button.sign-out.confirm"
                      ~on_press:(press send Model.SignOut)
                      ~text:"Sign Out" [];
                  ];
              ];
          ];
      ]
  else
    (* Text-and-buttons-only children keep the dialog on the native alert
       path (rich children fall back to a custom sheet). *)
    dialog ~text:"Sign out?" ~style_class:"alert"
      ~accessibility_identifier:"dialog.sign-out"
      ~on_dismiss:(press send Model.CancelSignOut)
      [
        text
          ~value:
            "Sync will pause. Downloaded graphs remain available on this device."
          [];
        button ~accessibility_identifier:"button.sign-out.cancel"
          ~on_press:(press send Model.CancelSignOut)
          ~text:"Cancel" [];
        button ~variant:`destructive
          ~accessibility_identifier:"button.sign-out.confirm"
          ~on_press:(press send Model.SignOut)
          ~text:"Sign Out" [];
      ]

let settings_kotlin_screen (context : Lui_ui.ui_context) model_source
    send : t =
  let card_bg = "background" in
  column ~gap:24 ~padding_horizontal:8 ~padding_vertical:16 ~cross:`stretch
    ~accessibility_identifier:"screen.settings"
    [
      column ~gap:8 ~cross:`stretch
        [
          text ~style_class:"subheadline semibold" ~padding_horizontal:16 ~foreground:"primary"
            ~accessibility_identifier:"label.settings.general"
            ~value:"General" [];
          settings_general_card context model_source send;
        ];
      column ~gap:8 ~cross:`stretch
        [
          text ~style_class:"subheadline semibold" ~padding_horizontal:16 ~foreground:"primary"
            ~accessibility_identifier:"label.settings.editor"
            ~value:"Editor" [];
          settings_editor_card context
            (Signal.map View_base.settings_spell_check model_source)
            (Signal.map View_base.settings_auto_correction model_source)
            send;
        ];
      column ~gap:8 ~cross:`stretch
        [
          text ~style_class:"subheadline semibold" ~padding_horizontal:16 ~foreground:"primary"
            ~accessibility_identifier:"label.settings.sync-server"
            ~value:"Sync server" [];
          column ~gap:8 ~padding:16 ~cross:`stretch ~style_class:"form" ~background:card_bg
            [
              text_field
                ~text_signal:
                  (Signal.map View_base.settings_base_url model_source)
                ~placeholder:"Server URL" ~label:"Server URL"
                ~accessibility_identifier:"field.base-url"
                ~on_input:
                  (on_input send (fun text -> Model.ChangeBaseURL text))
                [];
              if_
                ~test:
                  (Signal.map View_base.settings_base_url_invalid_
                     model_source)
                (text ~foreground:"destructive"
                   ~value:"Enter a valid HTTP or HTTPS URL." []);
            ];
        ];
      if_
        ~test:(Signal.map View_base.selected_graph_local_ model_source)
        (column ~gap:8 ~cross:`stretch
           [
             text ~style_class:"subheadline semibold" ~padding_horizontal:16 ~foreground:"primary"
               ~accessibility_identifier:"label.settings.advanced"
               ~value:"Advanced" [];
             column ~padding:16 ~background:card_bg
               [ settings_export_row context send ];
           ]);
      column ~gap:8 ~cross:`stretch
        [
          text ~style_class:"subheadline semibold" ~padding_horizontal:16 ~foreground:"primary"
            ~accessibility_identifier:"label.settings.about"
            ~value:"About" [];
          column ~gap:12 ~padding:16 ~background:card_bg
            [
              row
                [
                  text ~value:"Version" [];
                  spacer [];
                  text
                    ~value_signal:
                      (Signal.map View_base.settings_version model_source)
                    ~foreground:"secondary" [];
                ];
              row
                [
                  text ~value:"Revision" [];
                  spacer [];
                  text
                    ~value_signal:
                      (Signal.map View_base.settings_revision model_source)
                    ~foreground:"secondary" [];
                ];
              settings_runtime_log_row context send;
            ];
        ];
      column ~gap:8 ~cross:`stretch
        [
          text ~style_class:"subheadline semibold" ~padding_horizontal:16 ~foreground:"primary"
            ~accessibility_identifier:"label.settings.community"
            ~value:"Community" [];
          column ~gap:12 ~padding:16 ~background:card_bg
            [
              keyed
                ~source:
                  (Signal.map View_base.model_community_links
                     model_source)
                ~key:View_base.settings_community_link_identifier
                ~cmp:compare
                ~mount:(fun link_source ->
                  settings_community_link_row context model_source
                    link_source send);
            ];
        ];
      column ~padding:16 ~background:card_bg
        [ settings_account_row context model_source send ];
    ]

(* Native grouped-settings form: a `form`-styled content column whose
   children are `heading` section delimiters and row nodes — the Apple
   backend renders it as a grouped Form (white section cards, system
   separators, Logseq accent toggles). *)
let settings_form_screen (context : Lui_ui.ui_context) model_source send
    : t =
  let version_row label value_signal identifier : t =
    row ~cross:`center ~accessibility_identifier:identifier
      [
        text ~value:label [];
        spacer [];
        text ~value_signal ~foreground:"secondary" [];
      ]
  in
  column ~style_class:"form"
    ~accessibility_identifier:"screen.settings"
    [
      heading ~value:"General" ~foreground:"muted-foreground"
        ~accessibility_identifier:"label.settings.general" [];
      settings_appearance_control context model_source send;
      settings_language_control context model_source send;
      list_item ~accessibility_identifier:"link.settings.tabs"
        ~on_press:(press send Model.OpenSettingsTabs)
        [
          row ~grow:1.0 ~cross:`center
            [
              text ~value:"Tabs" [];
              spacer [];
              text
                ~value_signal:
                  (Signal.map View_base.settings_tabs_summary
                     model_source)
                ~style_class:"single-line" ~foreground:"secondary"
                ~accessibility_identifier:
                  "text.settings.tabs.selection" [];
            ];
        ];
      heading ~value:"Editor" ~foreground:"muted-foreground"
        ~accessibility_identifier:"label.settings.editor" [];
      with_native_control_tint "switch" (toggle
        ~checked_signal:
          (Signal.map View_base.settings_spell_check model_source)
        ~accessibility_identifier:"switch.settings.spell-check"
        ~on_toggle:(settings_toggle_spell_check send)
        ~text:"Spell check" []);
      with_native_control_tint "switch" (toggle
        ~checked_signal:
          (Signal.map View_base.settings_auto_correction model_source)
        ~accessibility_identifier:"switch.settings.auto-correction"
        ~on_toggle:(settings_toggle_auto_correction send)
        ~text:"Auto-correction" []);
      heading ~value:"Sync server" ~foreground:"muted-foreground"
        ~accessibility_identifier:"label.settings.sync-server" [];
      text_field
        ~text_signal:(Signal.map View_base.settings_base_url model_source)
        ~placeholder:"Server URL" ~label:"Server URL"
        ~accessibility_identifier:"field.base-url"
        ~on_input:(on_input send (fun text -> Model.ChangeBaseURL text))
        [];
      if_
        ~test:
          (Signal.map View_base.settings_base_url_invalid_ model_source)
        (text ~foreground:"destructive"
           ~value:"Enter a valid HTTP or HTTPS URL." []);
      if_
        ~test:(Signal.map View_base.selected_graph_local_ model_source)
        (heading ~value:"Advanced" ~foreground:"muted-foreground"
           ~accessibility_identifier:"label.settings.advanced" []);
      if_
        ~test:(Signal.map View_base.selected_graph_local_ model_source)
        (list_item ~padding:0
           ~accessibility_identifier:"button.export-graph-database"
           ~on_press:(press send Model.ExportGraphDatabase)
           ~text:"Export Graph SQLite DB" []);
      heading ~value:"About" ~foreground:"muted-foreground"
        ~accessibility_identifier:"label.settings.about" [];
      version_row "Version"
        (Signal.map View_base.settings_version model_source)
        "row.settings.version";
      version_row "Revision"
        (Signal.map View_base.settings_revision model_source)
        "row.settings.revision";
      list_item ~accessibility_identifier:"button.runtime-log"
        ~on_press:(press send Model.OpenRuntimeLog)
        ~text:"Check log" [];
      heading ~value:"Community" ~foreground:"muted-foreground"
        ~accessibility_identifier:"label.settings.community" [];
      keyed
        ~source:(Signal.map View_base.model_community_links model_source)
        ~key:View_base.settings_community_link_identifier
        ~cmp:compare
        ~mount:(fun link_source ->
          list_item
            ~text_signal:
              (Signal.map View_base.settings_community_link_title
                 link_source)
            ~accessibility_identifier:
              (View_base.settings_community_link_identifier
                 (Signal.sample link_source))
            ~on_press:(fun _ ->
              ignore
                (send
                   (Model.OpenExternalURL
                      (Signal.sample link_source
                         : Model.settings_community_link)
                        .url)))
            []);
      heading ~value:"Account"
        ~accessibility_identifier:"label.settings.account" [];
      settings_account_row context model_source send;
    ]

let settings_screen (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    settings_kotlin_screen context model_source send
  else settings_form_screen context model_source send

let settings_tabs_sheet (context : Lui_ui.ui_context) model_source send :
    t =
  if Lui_ui.host context = KotlinHost then
    sheet ~text:"Tabs" ~style_class:"navigation-content"
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
                  ~text:"Back to Settings" [];
              ];
          ];
      ]
  else
    sheet ~text:"Tabs" ~style_class:"navigation-list"
      ~accessibility_identifier:"sheet.settings.tabs"
      ~on_dismiss:(press send Model.BackSettings)
      [
        settings_tabs_screen context model_source send;
        toolbar ~orientation:`horizontal ~label:"Tabs actions"
          ~style_class:"navigation-actions"
          ~accessibility_identifier:"toolbar.settings.actions"
          [
            button ~style_class:"cancellation-action navigation-back-action"
              ~accessibility_identifier:"button.connection.cancel"
              ~on_press:(press send Model.BackSettings)
              ~text:"Settings" [];
          ];
      ]

let runtime_log_actions (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    row ~gap:12 ~padding_horizontal:16 ~padding_vertical:12
      ~background:"surface-container-low"
      ~accessibility_identifier:"toolbar.settings.actions"
      [
        button ~variant:`secondary ~grow:1.0
          ~accessibility_identifier:"button.log-refresh"
          ~on_press:(press send Model.RefreshRuntimeLog)
          ~text:"Refresh" [];
        button ~variant:`primary ~grow:1.0
          ~accessibility_identifier:"button.connection.apply"
          ~on_press:(press send Model.DismissRuntimeLog)
          ~text:"Done" [];
      ]
  else
    toolbar ~orientation:`horizontal ~label:"Log actions"
      ~style_class:"navigation-actions"
      ~accessibility_identifier:"toolbar.settings.actions"
      [
        button ~style_class:"cancellation-action"
          ~accessibility_identifier:"button.log-refresh"
          ~on_press:(press send Model.RefreshRuntimeLog)
          ~text:"Refresh" [];
        button ~style_class:"confirmation-action"
          ~accessibility_identifier:"button.connection.apply"
          ~on_press:(press send Model.DismissRuntimeLog)
          ~text:"Done" [];
      ]

let runtime_log_sheet (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    sheet ~text:"Log" ~style_class:"navigation-content"
      ~accessibility_identifier:"sheet.settings"
      ~on_dismiss:(press send Model.DismissRuntimeLog)
      [
        column ~grow:1.0 ~gap:12
          ~accessibility_identifier:"layout.runtime-log.sheet"
          [
            runtime_log_screen context model_source send;
            runtime_log_actions context send;
          ];
      ]
  else
    sheet ~text:"Log" ~style_class:"navigation-content"
      ~accessibility_identifier:"sheet.settings.log"
      ~on_dismiss:(press send Model.DismissRuntimeLog)
      [
        runtime_log_screen context model_source send;
        runtime_log_actions context send;
      ]

let settings_main_sheet (context : Lui_ui.ui_context) model_source send :
    t =
  if Lui_ui.host context = KotlinHost then
    sheet ~text:"Settings" ~height:640
      ~accessibility_identifier:"sheet.settings"
      ~on_dismiss:(press send Model.DismissSettings)
      [
        column ~grow:1.0 ~gap:12
          ~accessibility_identifier:"layout.settings.sheet"
          [
            scroll ~grow:1.0 [ settings_screen context model_source send ];
            row ~gap:12 ~main:`end_ ~padding_horizontal:24 ~padding_vertical:16
              ~background:"surface-container-low"
              ~accessibility_identifier:"toolbar.settings.actions"
              [
                spacer ~grow:1.0 [];
                button ~variant:`ghost
                  ~accessibility_identifier:"button.connection.cancel"
                  ~on_press:(press send Model.DismissSettings)
                  ~text:"Cancel" [];
                button ~variant:`primary
                  ~accessibility_identifier:"button.connection.apply"
                  ~disabled_signal:
                    (Signal.map View_base.settings_apply_disabled_
                       model_source)
                  ~on_press:(press send Model.ApplySettings)
                  ~text:"Apply" [];
              ];
          ];
      ]
  else
    sheet ~text:"Settings" ~style_class:"navigation-form navigation-inline-title"
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
        toolbar ~orientation:`horizontal ~label:"Settings actions"
          ~style_class:"navigation-actions"
          ~accessibility_identifier:"toolbar.settings.actions"
          [
            button ~style_class:"cancellation-action"
              ~accessibility_identifier:"button.connection.cancel"
              ~on_press:(press send Model.DismissSettings)
              ~text:"Cancel" [];
            button ~style_class:"confirmation-action"
              ~accessibility_identifier:"button.connection.apply"
              ~disabled_signal:
                (Signal.map View_base.settings_apply_disabled_
                   model_source)
              ~on_press:(press send Model.ApplySettings)
              ~text:"Apply" [];
          ];
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

let page_delete_dialog (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    dialog ~text:"Delete page?" ~height:280
      ~accessibility_identifier:"dialog.page-delete"
      ~on_dismiss:(press send Model.CancelDeleteActivePage)
      [
        column ~gap:16 ~cross:`stretch
          [
            text ~value:"The page will be moved to Recycle." ~grow:1.0 [];
            spacer ~grow:1.0 [];
            row ~main:`end_
              [
                toolbar ~orientation:`horizontal ~toolbar_gap:12
                  ~label:"Page deletion actions"
                  ~accessibility_identifier:"toolbar.page-delete"
                  [
                    button ~variant:`ghost
                      ~accessibility_identifier:
                        "button.page-delete.cancel"
                      ~on_press:(press send Model.CancelDeleteActivePage)
                      ~text:"Cancel" [];
                    button ~variant:`destructive
                      ~accessibility_identifier:
                        "button.page-delete.confirm"
                      ~on_press:(press send Model.ConfirmDeleteActivePage)
                      ~text:"Delete" [];
                  ];
              ];
          ];
      ]
  else
    (* Text-and-buttons-only children keep the dialog on the native alert
       path (rich children fall back to a custom sheet). *)
    dialog ~text:"Delete page?" ~style_class:"alert"
      ~accessibility_identifier:"dialog.page-delete"
      ~on_dismiss:(press send Model.CancelDeleteActivePage)
      [
        text ~value:"The page will be moved to Recycle." [];
        button ~accessibility_identifier:"button.page-delete.cancel"
          ~on_press:(press send Model.CancelDeleteActivePage)
          ~text:"Cancel" [];
        button ~variant:`destructive
          ~accessibility_identifier:"button.page-delete.confirm"
          ~on_press:(press send Model.ConfirmDeleteActivePage)
          ~text:"Delete" [];
      ]

let sync_status_sheet (context : Lui_ui.ui_context) model_source send : t =
  let sync_row identifier label value_signal : t =
    list_item ~accessibility_identifier:identifier
      [
        row ~grow:1.0 ~cross:`center ~main:`space_between
          [
            text ~value:label [];
            text ~value_signal ~foreground:"secondary"
              ~text_alignment:`end_ [];
          ];
      ]
  in
  if Lui_ui.host context = KotlinHost then
    sheet ~text:"Sync status" ~height:480
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
                            text ~value:"Local changes" [];
                            text
                              ~value_signal:
                                (Signal.map View_base.sync_pending_label
                                   model_source)
                              ~foreground:"secondary" ~text_alignment:`end_
                              ~accessibility_identifier:"sync.pending" [];
                  ];
              ];
            list_item ~accessibility_identifier:"row.sync.cursor"
              [
                row ~grow:1.0 ~cross:`center ~main:`space_between
                  [
                    text ~value:"Remote tx" [];
                    text
                      ~value_signal:
                        (Signal.map View_base.sync_cursor_label
                           model_source)
                      ~foreground:"secondary" ~text_alignment:`end_
                      ~accessibility_identifier:"sync.cursor" [];
                  ];
              ];
            if_
              ~test:(Signal.map View_base.sync_error_present_ model_source)
              (text ~style_class:"footnote" ~foreground:"muted-foreground"
                 ~value:"Last error" []);
            if_
              ~test:(Signal.map View_base.sync_error_present_ model_source)
              (text
                 ~value_signal:
                   (Signal.map View_base.sync_error_message model_source)
                 ~foreground:"destructive"
                 ~accessibility_identifier:"sync.error" []);
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
                  ~text:"Done" [];
                button ~variant:`primary
                  ~accessibility_identifier:"button.sync-now"
                  ~on_press:(press send Model.SyncNow)
                  ~text:"Sync now" [];
              ];
          ];
      ]
  else
    View_base.with_string_prop_signal Lui_protocol.Detents
      (Signal.map (fun current -> if View_base.sync_error_present_ current then "medium,large" else "medium") model_source)
    (sheet ~text:"Sync status" ~style_class:"navigation-form navigation-inline-title" ~detents:"medium"
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
                  text ~value:"Local changes" [];
                  text
                    ~value_signal:
                      (Signal.map View_base.sync_pending_label
                         model_source)
                    ~foreground:"secondary" ~text_alignment:`end_
                    ~accessibility_identifier:"sync.pending" [];
                ];
            ];
          list_item ~accessibility_identifier:"row.sync.cursor"
            [
              row ~grow:1.0 ~cross:`center ~main:`space_between
                [
                  text ~value:"Remote tx" [];
                  text
                    ~value_signal:
                      (Signal.map View_base.sync_cursor_label model_source)
                    ~foreground:"secondary" ~text_alignment:`end_
                    ~accessibility_identifier:"sync.cursor" [];
                ];
            ];
          if_
            ~test:(Signal.map View_base.sync_error_present_ model_source)
            (heading ~level:5 ~value:"Last error" []);
          if_
            ~test:(Signal.map View_base.sync_error_present_ model_source)
            (list_item
               [
                 text
                   ~value_signal:
                     (Signal.map View_base.sync_error_message
                        model_source)
                   ~foreground:"red" ~accessibility_identifier:"sync.error"
                   [];
               ]);
          button ~accessibility_identifier:"button.sync-now"
            ~on_press:(press send Model.SyncNow)
            ~text:"Sync now" [];
        ];
      toolbar ~orientation:`horizontal ~label:"Sync status actions"
        ~style_class:"navigation-actions"
        ~accessibility_identifier:"toolbar.sync.actions"
        [
          button ~style_class:"confirmation-action"
            ~accessibility_identifier:"button.sync.done"
            ~on_press:(press send Model.CloseSyncDetails)
            ~text:"Done" [];
        ];
    ])
