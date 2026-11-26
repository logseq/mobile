type retained_outline_row = View_rows.retained_row

(* App theme: the Logseq palette as scoped theme tokens — mode-dependent
   colors ride the wire as adaptive {light,dark} pairs picked by each
   backend's effective color scheme, and `theme-mode` follows the
   appearance setting so every platform hot-switches with one patch. *)
let logseq_theme_tokens ui_context dark_theme : (string * Lui_ui.theme_token_value) list =
  let open Lui_ui in
  let surfaces =
    match Lui_ui.platform ui_context, Lui_ui.host ui_context with
    | Lui_protocol.AndroidOS, Lui_protocol.KotlinHost -> []
    | _ ->
      [
        ("background", View_base.main_background dark_theme);
        ("surface", View_base.grouped_row_background);
        ("code-container", Adaptive { light = "#EFEFF0";
          dark = if dark_theme = "black" then "#242424" else "#19394D" });
        ("card", View_base.grouped_row_background);
      ]
  in
  let text_colors =
    match Lui_ui.platform ui_context, Lui_ui.host ui_context with
    | Lui_protocol.IOS, Lui_protocol.SwiftUIHost ->
      [ ("muted-foreground", Adaptive {
          light = "#6F6F6F";
          dark = if dark_theme = "black" then "#A1A1AA" else "#9BD3D4";
        });
        ("error-foreground", Adaptive { light = "#C52222"; dark = "#FF5550" }) ]
    | Lui_protocol.AndroidOS, Lui_protocol.KotlinHost ->
      [ (* UIColor.secondaryLabel with 40% alpha, including the empty-row marker. *)
        ("outliner-bullet", Adaptive { light = "#3C3C4366"; dark = "#EBEBF566" });
        ("settings-group", Adaptive {
          light = "#FFFFFF";
          dark = if dark_theme = "black" then "#2E2E30" else "#143D48";
        }) ]
    | _ -> []
  in
  let task_colors = Task_status_style.palette |> List.map (fun (name, (light, dark)) ->
    let color = if light = dark then Fixed light else Adaptive { light; dark } in
    "task-" ^ name, color) in
  surfaces @ text_colors @ task_colors @ [
    ("link", Adaptive { light = "#1B6898"; dark = View_base.dark_accent });
    ("bottom-tab-selected", Adaptive { light = "#14243314"; dark = "#00000055" });
    ("task-tab-background", Adaptive { light = "#EFEFF0";
      dark = if dark_theme = "black" then "#202022" else "#19394D" });
    ("task-tab-selected-background", Adaptive { light = "#DFEDF2";
      dark = if dark_theme = "black" then "#163136" else "#254855" });
    ("deadline-overdue", Adaptive { light = "#B42318"; dark = "#FF6961" });
    ( "autocomplete-row-background",
      Adaptive { light = "#6F6F6F1A"; dark = "#9BD3D41A" } );
    ("flashcard-again-background", Fixed "#FF3B301F");
    ("flashcard-again-foreground", Adaptive { light = "#B42318"; dark = "#FFB4AB" });
    ("flashcard-hard-background", Fixed "#FF95001F");
    ("flashcard-hard-foreground", Adaptive { light = "#8A4B00"; dark = "#FFD180" });
    ("flashcard-good-background", Fixed "#007AFF1F");
    ("flashcard-good-foreground", Adaptive { light = "#005BB5"; dark = "#A8C7FA" });
    ("flashcard-easy-background", Fixed "#34C7591F");
    ("flashcard-easy-foreground", Adaptive { light = "#146C2E"; dark = "#A6DAB2" });
  ]

let logseq_theme_mode (model : Model.logseq_model) : Lui_ui.theme_mode =
  match model.appearance with
  | "light" -> `light
  | "dark" -> `dark
  | _ -> `system

let with_ui_state model_source elem =
  Lui_elements.custom (fun context parent ->
    match Lui_ui.profile context with
    | { Lui_protocol.profile_os = IOS; profile_host = SwiftUIHost } ->
      let node = Lui_ui.platform_tweak context "ui-state" in
      let previous = ref None in
      ignore (Signal.own context.ui_scope (Signal.observe model_source (fun (model : Model.logseq_model) ->
        let screen =
          if model.authentication_form.opened || View_base.authentication_screen_visible_ model then "authentication"
          else if model.settings_open || model.settings_tabs_open || model.runtime_log_open then "settings"
          else if View_base.graph_picker_screen_visible_ model then "graphs"
          else if model.pdf_workspace <> None then "pdf"
          else if model.search_open then
            (if model.search_navigation_path = [] then "search" else "page")
          else match model.destination with
            | GraphsDestination -> "graphs"
            | NotificationsDestination -> "notifications"
            | FlashcardsDestination -> "flashcards"
            | TasksDestination -> if model.app_navigation_path = [] then "tasks" else "page"
            | JournalsDestination ->
              if model.app_navigation_path <> [] || model.selected_page <> None then "page" else "journals"
        in
        let editor = model.outliner_editing <> None in
        let presentation = model.authentication_form.opened || model.settings_open || model.settings_tabs_open || model.runtime_log_open
          || model.sync_details_open || model.create_graph_open || model.graph_password_open
          || model.pending_sign_out || model.pending_node_deletion <> None || model.pending_graph_deletion <> None in
        let state = screen, editor, presentation in
        if !previous <> Some state then (
          previous := Some state;
          Lui_ui.extension_property context node "screen" (StringValue screen);
          Lui_ui.extension_property context node "editor-active" (BoolValue editor);
          Lui_ui.extension_property context node "presentation-open" (BoolValue presentation)))));
      let child = Lui_elements.mount context elem in
      Lui_ui.append context node child;
      Lui_elements.attach context parent node;
      node
    | _ -> Lui_elements.mount context ?parent elem)

let logseq_view (context : Lui_ui.ui_context) model_source send =
  let language (model : Model.logseq_model) =
    Localization.resolve model.language model.system_language
  in
  let screen =
    if Lui_ui.host context = KotlinHost then
      (* Sidebar and navigation extensions reference children by node ID.
         Replace the locale branch as a unit so those IDs stay consistent. *)
      Lui_elements.keyed
        ~source:(Signal.map (fun model -> [language model]) model_source)
        ~key:Fun.id ~cmp:String.compare
        ~mount:(fun _ -> View_screens.logseq_view context model_source send)
    else
      reactive ~equal:(fun left right -> language left = language right)
        (fun _ -> View_screens.logseq_view context model_source send) model_source
  in
  let dark_theme (model : Model.logseq_model) = model.dark_theme in
  with_ui_state model_source (Lui_elements.themed
    ~tokens_signal:(Signal.map (logseq_theme_tokens context) (Signal.map dark_theme model_source))
    ~mode:(reactive logseq_theme_mode model_source)
    screen)

let outliner_editor_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "outliner-editor"
    [ profile IOS SwiftUIHost; profile AndroidOS KotlinHost ]
    false []
    [
      Lui_extension.property "block-id" StringScalar true None;
      Lui_extension.property "title" StringScalar true None;
      Lui_extension.property "caret-utf16-offset" IntScalar true None;
      Lui_extension.property "selection-revision" IntScalar true None;
      Lui_extension.property "input-policy" StringScalar true None;
      Lui_extension.property "focus-enabled" BoolScalar true None;
    ]
    [
      Lui_extension.event "text-change"
        [
          Lui_extension.event_field "title" StringScalar true;
          Lui_extension.event_field "caret-utf16-offset" IntScalar true;
        ];
      Lui_extension.event "composing-text-change"
        [
          Lui_extension.event_field "title" StringScalar true;
          Lui_extension.event_field "caret-utf16-offset" IntScalar true;
        ];
      Lui_extension.event "paste"
        [Lui_extension.event_field "title" StringScalar true;
         Lui_extension.event_field "caret-utf16-offset" IntScalar true];
      Lui_extension.event "paste-content" [Lui_extension.event_field "value" StringScalar true];
      Lui_extension.event "return"
        [
          Lui_extension.event_field "title" StringScalar true;
          Lui_extension.event_field "caret-utf16-offset" IntScalar true;
        ];
      Lui_extension.event "backspace"
        [
          Lui_extension.event_field "title" StringScalar true;
          Lui_extension.event_field "selection-length" IntScalar true;
        ];
      Lui_extension.event "caret-change"
        [ Lui_extension.event_field "caret-utf16-offset" IntScalar true ];
      Lui_extension.event "ime-dismissed" [];
    ]

let outliner_block_content_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "outliner-block-content"
    [ profile IOS SwiftUIHost; profile AndroidOS KotlinHost ]
    false []
    [
      Lui_extension.property "title" StringScalar true None;
      Lui_extension.property "block-id" StringScalar true None;
      Lui_extension.property "markup-json" StringScalar true None;
      Lui_extension.property "youtube-target-url" StringScalar true None;
      Lui_extension.property "is-asset" BoolScalar true None;
      Lui_extension.property "is-completed" BoolScalar true None;
      Lui_extension.property "show-code-language" BoolScalar false None;
      Lui_extension.property "asset-type" StringScalar true None;
      Lui_extension.property "local-path" StringScalar true None;
      Lui_extension.property "row-actions" StringScalar false None;
      Lui_extension.property "interaction" StringScalar false None;
    ]
    [
      Lui_extension.event "drag-start"
        [ Lui_extension.event_field "uuid" StringScalar true ];
      Lui_extension.event "toggle-selection"
        [ Lui_extension.event_field "uuid" StringScalar true ];
      Lui_extension.event "menu-action"
        [ Lui_extension.event_field "payload" StringScalar true ];
      Lui_extension.event "set-status"
        [ Lui_extension.event_field "uuid" StringScalar true;
          Lui_extension.event_field "count" IntScalar true ];
      Lui_extension.event "drop"
        [
          Lui_extension.event_field "uuid" StringScalar true;
          Lui_extension.event_field "placement" StringScalar true;
        ];
      Lui_extension.event "edit"
        [ Lui_extension.event_field "uuid" StringScalar true ];
      Lui_extension.event "open-node"
        [ Lui_extension.event_field "uuid" StringScalar true ];
    ]

let node_icon_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "node-icon" [profile IOS SwiftUIHost; profile AndroidOS KotlinHost] false []
    [property "payload" StringScalar true None; property "size" IntScalar true None; property "muted" BoolScalar true None] []

let outliner_block_row_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  let uuid = Lui_extension.event_field "uuid" StringScalar true in
  Lui_extension.component "outliner-block-row" [profile IOS SwiftUIHost] true []
    [Lui_extension.property "payload" StringScalar true None]
    [Lui_extension.event "edit" [uuid; Lui_extension.event_field "caret-utf16-offset" IntScalar false];
     Lui_extension.event "open-node" [uuid];
     Lui_extension.event "remove-tag" [uuid];
     Lui_extension.event "collapse" [uuid]; Lui_extension.event "long-press" [uuid];
     Lui_extension.event "drag-start" [uuid];
     Lui_extension.event "toggle-selection" [uuid];
     Lui_extension.event "menu-action" [Lui_extension.event_field "payload" StringScalar true];
     Lui_extension.event "drop" [uuid; Lui_extension.event_field "placement" StringScalar true];
     Lui_extension.event "set-priority" [Lui_extension.event_field "priority" StringScalar true];
     Lui_extension.event "set-status" [uuid; Lui_extension.event_field "count" IntScalar true]]

let native_navigation_stack_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "native-navigation-stack"
    [ profile IOS SwiftUIHost; profile AndroidOS KotlinHost ]
    true []
    [
      Lui_extension.property "depth" IntScalar true None;
      Lui_extension.property "back-depth" IntScalar true None;
      Lui_extension.property "selection-active" BoolScalar false None;
      Lui_extension.property "bottom-occupies-layout-space" BoolScalar true
        None;
      Lui_extension.property "composer-dismissal-enabled" BoolScalar true
        None;
      Lui_extension.property "title" StringScalar true None;
    ]
    [
      Lui_extension.event "back"
        [ Lui_extension.event_field "count" IntScalar true ];
      Lui_extension.event "dismiss-composer" [];
      Lui_extension.event "viewport-changed"
        [ Lui_extension.event_field "width" IntScalar true ];
    ]

let native_navigation_title_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.tweak "native-navigation-title"
    [ profile IOS SwiftUIHost ]
    [ Lui_extension.property "title" StringScalar true None ]

let native_sidebar_schema () =
  let open Lui_protocol in
  Lui_extension.component "native-sidebar" [profile IOS SwiftUIHost]
    true [] [] []

let sidebar_overlay_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "sidebar-overlay" [profile AndroidOS KotlinHost; profile IOS SwiftUIHost] true []
    [property "open" BoolScalar true None; property "enabled" BoolScalar true None;
     property "width" IntScalar true None; property "main-id" IntScalar true None;
     property "panel-id" IntScalar true None; property "settings-id" IntScalar true None;
     property "dismiss-label" StringScalar true None]
    [event "open" []; event "close" []]

let native_top_notification_schema () =
  let open Lui_protocol in
  Lui_extension.component "native-top-notification" [profile IOS SwiftUIHost]
    true [] [] []

let native_search_presentation_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "native-search-presentation"
    [ profile IOS SwiftUIHost; profile AndroidOS KotlinHost ]
    true []
    [
      Lui_extension.property "back-title" StringScalar false None;
      Lui_extension.property "clear-title" StringScalar false None;
      Lui_extension.property "close-title" StringScalar false None;
      Lui_extension.property "bottom-occupies-layout-space" BoolScalar true None;
      Lui_extension.property "presented" BoolScalar true None;
      Lui_extension.property "depth" IntScalar true None;
      Lui_extension.property "query" StringScalar true None;
      Lui_extension.property "status-title" StringScalar false None;
      Lui_extension.property "title" StringScalar true None;
    ]
    [
      Lui_extension.event "back"
        [ Lui_extension.event_field "count" IntScalar true ];
      Lui_extension.event "dismiss" [];
      Lui_extension.event "present" [];
      Lui_extension.event "query-changed"
        [ Lui_extension.event_field "query" StringScalar true ];
    ]

let liquid_glass_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.tweak "liquid-glass" [ profile IOS SwiftUIHost ]
    [ Lui_extension.property "shape" StringScalar true None ]

let native_control_tint_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  tweak "native-control-tint" [profile IOS SwiftUIHost]
    [property "role" StringScalar true None]

let adaptive_content_insets_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.tweak "native-adaptive-insets"
    [ profile IOS SwiftUIHost; profile AndroidOS KotlinHost ]
    [ property "breakpoint" IntScalar true None;
      property "wide-inset" IntScalar true None ]

let table_viewport_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "native-table-viewport" [profile IOS SwiftUIHost; profile AndroidOS KotlinHost]
    true [] [property "identifier" StringScalar true None]
    [event "viewport-changed" [event_field "offset" IntScalar true; event_field "width" IntScalar true]]

let property_row_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "native-property-row" [profile IOS SwiftUIHost; profile AndroidOS KotlinHost]
    true [] [property "stacked" BoolScalar true None] []

let outliner_continuation_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "outliner-continuation" [profile IOS SwiftUIHost; profile AndroidOS KotlinHost]
    true [] [property "guide-count" IntScalar true None; property "identifier" StringScalar true None;
      property "bullet-depth" IntScalar true None] []

let journal_task_transition_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "journal-task-transition" [profile IOS SwiftUIHost]
    true [] [property "collapsed" StringScalar true None] []

let outliner_bottom_spacer_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "outliner-bottom-spacer" [profile IOS SwiftUIHost]
    false [] [property "height" IntScalar true None] []

let journal_task_chevron_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "journal-task-chevron" [profile IOS SwiftUIHost]
    true [] [property "collapsed" BoolScalar true None] []

let property_date_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "native-property-date" [profile IOS SwiftUIHost; profile AndroidOS KotlinHost]
    false [] [property "kind" StringScalar true None; property "value" StringScalar true None;
      property "identifier" StringScalar true None; property "time-label" StringScalar true None]
    [event "change" [event_field "value" StringScalar true]]

let task_date_sheet_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "native-task-date-sheet" [profile IOS SwiftUIHost; profile AndroidOS KotlinHost]
    false [] [property "payload" StringScalar true None]
    [event "clear" []; event "choose" [event_field "value" StringScalar true];
      event "submit" [event_field "value" StringScalar true]; event "dismiss" []]

let pdf_workspace_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  component "native-pdf-workspace" [profile IOS SwiftUIHost; profile AndroidOS KotlinHost]
    true [] [property "payload" StringScalar true None]
    [event "event" [event_field "payload" StringScalar true]]

let extension_registry () =
  let registry = Lui_extension.registry () in
  Lui_extension.register_tweak registry
    (Lui_extension.tweak "ui-state" [Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost]
       [Lui_extension.property "screen" StringScalar true None;
        Lui_extension.property "editor-active" BoolScalar true None;
        Lui_extension.property "presentation-open" BoolScalar true None]);
  Lui_extension.register_tweak registry
    (Lui_extension.tweak "tasks-menu-material"
       [Lui_protocol.profile Lui_protocol.AndroidOS Lui_protocol.KotlinHost] []);
  Lui_extension.register_tweak registry
    (Lui_extension.tweak "settings-material-surface"
       [Lui_protocol.profile Lui_protocol.AndroidOS Lui_protocol.KotlinHost] []);
  Lui_extension.register_component registry
    (Lui_extension.component "native-auth-input"
       [Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost;
        Lui_protocol.profile Lui_protocol.AndroidOS Lui_protocol.KotlinHost]
       true [] [Lui_extension.property "kind" Lui_extension.StringScalar true None] []);
  Lui_extension.register_component registry (pdf_workspace_schema ());
  Lui_extension.register_component registry (node_icon_schema ());
  Lui_extension.register_component registry (property_row_schema ());
  Lui_extension.register_component registry (table_viewport_schema ());
  Lui_extension.register_component registry (property_date_schema ());
  Lui_extension.register_component registry (task_date_sheet_schema ());
  Lui_extension.register_component registry
    (Lui_extension.component "native-reaction-picker" [Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost]
      true [] [] [Lui_extension.event "dismiss" []]);
  Lui_extension.register_component registry
    (Lui_extension.component "centered-popover" [Lui_protocol.profile Lui_protocol.AndroidOS Lui_protocol.KotlinHost]
      true [] [] [Lui_extension.event "dismiss" []]);
  Lui_extension.register_component registry (let open Lui_protocol in
    let open Lui_extension in
    component "filter-search-field" [profile AndroidOS KotlinHost] false []
      [property "autofocus" BoolScalar true None;
       property "clear-title" StringScalar true None;
       property "disabled" BoolScalar true None;
       property "identifier" StringScalar true None;
       property "label" StringScalar true None;
       property "placeholder" StringScalar true None;
       property "query" StringScalar true None]
      [event "query-changed" [event_field "query" StringScalar true]]);
  Lui_extension.register_component registry
    (Lui_extension.component "reaction-search-input"
      [Lui_protocol.profile Lui_protocol.AndroidOS Lui_protocol.KotlinHost; Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost]
      false [] [Lui_extension.property "clear-title" Lui_extension.StringScalar true None;
        Lui_extension.property "placeholder" Lui_extension.StringScalar true None]
      [Lui_extension.event "query-changed" [Lui_extension.event_field "query" Lui_extension.StringScalar true]]);
  Lui_extension.register_component registry (journal_task_transition_schema ());
  Lui_extension.register_component registry (outliner_bottom_spacer_schema ());
  Lui_extension.register_component registry (journal_task_chevron_schema ());
  Lui_extension.register_component registry (outliner_continuation_schema ());
  Lui_extension.register_component registry (outliner_editor_schema ());
  Lui_extension.register_component registry (outliner_block_row_schema ());
  Lui_extension.register_component registry (let open Lui_protocol in
    let open Lui_extension in
    component "native-outliner-selection-toolbar" [profile IOS SwiftUIHost] true []
      [property "more-actions" StringScalar true None; property "more-label" StringScalar true None;
       property "status-label" StringScalar true None; property "statuses" StringScalar true None]
      [event "perform-action" [event_field "value" StringScalar true];
       event "select-status" [event_field "value" StringScalar true]]);
  Lui_extension.register_component registry
    (outliner_block_content_schema ());
  Lui_extension.register_component registry (let open Lui_protocol in
    let open Lui_extension in
    component "outliner-row-swipe" [profile AndroidOS KotlinHost] true []
      [property "block-id" StringScalar true None; property "enabled" BoolScalar true None;
       property "marker-inset" IntScalar true None]
      [event "toggle-selection" [event_field "uuid" StringScalar true]]);
  Lui_extension.register_component registry
    (native_navigation_stack_schema ());
  Lui_extension.register_component registry (let open Lui_protocol in
    let open Lui_extension in
    component "bottom-chrome-switch" [profile IOS SwiftUIHost] true []
      [property "selection-active" BoolScalar true None] []);
  Lui_extension.register_component registry (let open Lui_protocol in
    let open Lui_extension in
    component "bottom-tab-strip" [profile IOS SwiftUIHost; profile AndroidOS KotlinHost] true []
      [property "inset" IntScalar true None; property "selected-index" IntScalar true None;
       property "items" StringScalar true None; property "cell-width" IntScalar true None]
      [event "select" [event_field "index" IntScalar true]; event "home-double-tap" []]);
  Lui_extension.register_component registry
    (Lui_extension.component "native-flashcards-toolbar"
       [Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost]
       true [] [] []);
  Lui_extension.register_component registry (native_sidebar_schema ());
  Lui_extension.register_component registry (let open Lui_protocol in
    let open Lui_extension in
    component "composer-task-toggle" [profile AndroidOS KotlinHost] false []
      [property "label" StringScalar true None; property "selected" BoolScalar true None]
      [event "press" []]);
  Lui_extension.register_component registry (sidebar_overlay_schema ());
  Lui_extension.register_component registry (native_top_notification_schema ());
  Lui_extension.register_tweak registry
    (native_navigation_title_schema ());
  Lui_extension.register_component registry
    (native_search_presentation_schema ());
  Lui_extension.register_tweak registry (liquid_glass_schema ());
  Lui_extension.register_tweak registry (native_control_tint_schema ());
  Lui_extension.register_tweak registry (adaptive_content_insets_schema ());
  Lui_extension.register_tweak registry
    (Lui_extension.tweak "sidebar-current-item"
      [Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost]
      [Lui_extension.property "current" Lui_extension.BoolScalar true None]);
  registry
