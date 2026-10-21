type retained_outline_row = View_rows.retained_row

(* App theme: the Logseq palette as scoped theme tokens — mode-dependent
   colors ride the wire as adaptive {light,dark} pairs picked by each
   backend's effective color scheme, and `theme-mode` follows the
   appearance setting so every platform hot-switches with one patch. *)
let logseq_theme_tokens : (string * Lui_ui.theme_token_value) list =
  let open Lui_ui in
  [
    ("background", Adaptive { light = "#FCFCFC"; dark = "#002D38" });
    ("surface", Adaptive { light = "#F8F8F8"; dark = "#19394D" });
    ("card", Adaptive { light = "#FFFFFF"; dark = "#1C4556" });
    ( "autocomplete-row-background",
      Adaptive { light = "#6F6F6F1A"; dark = "#9BD3D41A" } );
    (* Match master's Radix status palette in both appearances. *)
    ("task-backlog", Adaptive { light = "#E8E8E8"; dark = "#2E2E2E" });
    ("task-todo", Adaptive { light = "#858585"; dark = "#7E7E7E" });
    ("task-doing", Adaptive { light = "#EBBC00"; dark = "#705E00" });
    ("task-in-review", Fixed "#0090FF");
    ("task-done", Adaptive { light = "#5BB98C"; dark = "#236E4A" });
    ("task-canceled", Adaptive { light = "#EB9091"; dark = "#AA2429" });
    ("flashcard-again-background", Fixed "#FF3B301F");
    ("flashcard-hard-background", Fixed "#FF95001F");
    ("flashcard-good-background", Fixed "#007AFF1F");
    ("flashcard-easy-background", Fixed "#34C7591F");
  ]

let logseq_theme_mode (model : Model.logseq_model) : Lui_ui.theme_mode =
  match model.appearance with
  | "light" -> `light
  | "dark" -> `dark
  | _ -> `system

let logseq_view (context : Lui_ui.ui_context) model_source send =
  Lui_elements.themed ~tokens:logseq_theme_tokens
    ~mode_signal:(Signal.map logseq_theme_mode model_source)
    (View_screens.logseq_view context model_source send)

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
    ]
    [
      Lui_extension.event "text-change"
        [
          Lui_extension.event_field "title" StringScalar true;
          Lui_extension.event_field "caret-utf16-offset" IntScalar true;
        ];
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
      Lui_extension.property "asset-type" StringScalar true None;
      Lui_extension.property "local-path" StringScalar true None;
    ]
    [
      Lui_extension.event "drag-start"
        [ Lui_extension.event_field "uuid" StringScalar true ];
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
    [property "payload" StringScalar true None; property "size" IntScalar true None] []

let outliner_block_row_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  let uuid = Lui_extension.event_field "uuid" StringScalar true in
  Lui_extension.component "outliner-block-row" [profile IOS SwiftUIHost] true []
    [Lui_extension.property "payload" StringScalar true None]
    [Lui_extension.event "edit" [uuid]; Lui_extension.event "open-node" [uuid];
     Lui_extension.event "collapse" [uuid]; Lui_extension.event "long-press" [uuid];
     Lui_extension.event "drag-start" [uuid];
     Lui_extension.event "drop" [uuid; Lui_extension.event_field "placement" StringScalar true];
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
      Lui_extension.property "bottom-occupies-layout-space" BoolScalar true None;
      Lui_extension.property "presented" BoolScalar true None;
      Lui_extension.property "depth" IntScalar true None;
      Lui_extension.property "query" StringScalar true None;
      Lui_extension.property "title" StringScalar true None;
    ]
    [
      Lui_extension.event "back"
        [ Lui_extension.event_field "count" IntScalar true ];
      Lui_extension.event "dismiss" [];
      Lui_extension.event "query-changed"
        [ Lui_extension.event_field "query" StringScalar true ];
    ]

let liquid_glass_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.tweak "liquid-glass" [ profile IOS SwiftUIHost ]
    [ Lui_extension.property "shape" StringScalar true None ]

let adaptive_content_insets_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.tweak "native-adaptive-insets"
    [ profile IOS SwiftUIHost; profile AndroidOS KotlinHost ]
    [ property "breakpoint" IntScalar true None;
      property "wide-inset" IntScalar true None ]

let extension_registry () =
  let registry = Lui_extension.registry () in
  Lui_extension.register_component registry (node_icon_schema ());
  Lui_extension.register_component registry (outliner_editor_schema ());
  Lui_extension.register_component registry (outliner_block_row_schema ());
  Lui_extension.register_component registry
    (outliner_block_content_schema ());
  Lui_extension.register_component registry
    (native_navigation_stack_schema ());
  Lui_extension.register_component registry (native_sidebar_schema ());
  Lui_extension.register_component registry (native_top_notification_schema ());
  Lui_extension.register_tweak registry
    (native_navigation_title_schema ());
  Lui_extension.register_component registry
    (native_search_presentation_schema ());
  Lui_extension.register_tweak registry (liquid_glass_schema ());
  Lui_extension.register_tweak registry (adaptive_content_insets_schema ());
  registry
