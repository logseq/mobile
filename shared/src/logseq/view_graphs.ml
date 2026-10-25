open Lui_protocol
open Lui_elements

let graph_row (_context : Lui_ui.ui_context) model_source graph_source
    _local send : t =
  let graph = (Signal.sample graph_source : Model.graph) in
  let graph_id = graph.id in
  list_item
    ~accessibility_identifier:(View_base.graph_identifier graph)
    ~padding_horizontal:12 ~padding_vertical:10 ~min_height:44
    ~disabled_signal:
      (Signal.map2 View_base.graph_row_disabled_ model_source
         graph_source)
    ~on_press:(fun _ ->
      ignore
        (send
           (Model.RequestOpenGraph
              graph.id)))
    [
      column ~gap:4 ~grow:1.0
        [
          text ~style_class:"semibold"
            ~value_signal:(Signal.map View_base.graph_title graph_source)
            [];
          if_
            ~test:(Signal.map View_base.graph_status_visible_ graph_source)
            (text
               ~value_signal:
                 (Signal.map View_base.graph_status_title graph_source)
               ~style_class:"caption" ~foreground:"muted-foreground"
               ~accessibility_identifier:
                 (View_base.graph_status_identifier graph)
               []);
        ];
      context_menu
        ~accessibility_identifier:(View_base.graph_delete_identifier graph)
        [
          if_
            ~test:
              (Signal.map2 View_base.graph_row_local_ model_source
                 graph_source)
            (View_base.with_string_prop VariantValue "destructive"
              (menu_item ~icon:(`app "trash")
               ~disabled_signal:
                 (Signal.map2 View_base.graph_delete_active_ model_source
                    graph_source)
               ~text:(View_base.tr (Signal.sample model_source) "Delete local graph")
               ~on_press:(fun _ ->
                 ignore (send (Model.RequestDeleteGraph graph_id)))
               []));
        ];
    ]

let graph_list_row (context : Lui_ui.ui_context) model_source graph_source
    local send : t =
  let graph = (Signal.sample graph_source : Model.graph) in
  let graph_id = graph.id in
  View_base.with_string_prop_signal InlineIconName
    (Signal.map
       (fun (current_graph : Model.graph) ->
         if
           Lui_ui.host context <> KotlinHost
           && (not local) && current_graph.is_encrypted
         then "app:graph-locked"
         else View_base.graph_icon_name local current_graph)
       graph_source)
    (list_item
       ~min_height:(if Lui_ui.host context = KotlinHost then 56 else 44)
       ~style_class:"context-menu-only"
       ~accessibility_identifier:(View_base.graph_identifier graph)
       ~disabled_signal:
         (if local then
            Signal.map2 View_base.graph_delete_active_ model_source
              graph_source
          else
            Signal.map2 View_base.graph_row_disabled_ model_source
              graph_source)
       ~on_press:(fun _ ->
         ignore
           (send
              (Model.RequestOpenGraph
                 graph.id)))
       [
         column ~gap:4
           [
             text
               ~value_signal:
                 (Signal.map View_base.graph_title graph_source)
               [];
             if_ ~test:(reactive View_base.graph_delete_active_ model_source graph_source)
               (row ~gap:8 ~cross:`center
                 [ spinner ~accessibility_identifier:"graph-delete.loading" [];
                   text ~value:(View_base.tr (Signal.sample model_source) "Deleting graph…") ~style_class:"caption"
                     ~foreground:"muted-foreground" [] ]);
             if_
               ~test:
                 (Signal.map View_base.graph_not_ready_ graph_source)
               (text ~style_class:"caption" ~foreground:"muted-foreground"
                  ~accessibility_identifier:
                    (View_base.graph_status_identifier graph)
                  ~value:(View_base.tr (Signal.sample model_source) "Preparing") []);
             if_
               ~test:
                 (Signal.map
                    (fun (current_graph : Model.graph) ->
                      Lui_ui.host context = KotlinHost
                      && current_graph.is_encrypted)
                    graph_source)
               (text ~style_class:"caption"
                  ~foreground:"muted-foreground" ~value:(View_base.tr (Signal.sample model_source) "Encrypted") []);
           ];
         context_menu
           ~accessibility_identifier:
             (View_base.graph_delete_identifier graph)
           [
             if_
               ~test:
                 (Signal.map2 View_base.graph_row_local_ model_source
                    graph_source)
               (View_base.with_string_prop VariantValue "destructive"
              (menu_item
                  ~disabled_signal:
                    (Signal.map2 View_base.graph_delete_active_
                       model_source graph_source)
                  ~text:(View_base.tr (Signal.sample model_source) "Delete local graph")
                  ~on_press:(fun _ ->
                    ignore (send (Model.RequestDeleteGraph graph_id)))
                  []));
           ];
       ])

let graph_encryption_setup_fields model_source send =
  if_ ~test:(Signal.map (fun (current : Model.logseq_model) ->
    current.new_graph_encrypted && current.new_graph_password_required) model_source)
    (column ~gap:12 [
      text ~style_class:"footnote" ~foreground:"muted-foreground"
        ~value:(View_base.tr (Signal.sample model_source) "Choose an E2EE password for your encrypted graphs. Keep it safe; you will need it on other devices.") [];
      secure_field ~label:(View_base.tr (Signal.sample model_source) "E2EE password") ~placeholder:(View_base.tr (Signal.sample model_source) "E2EE password")
        ~text_signal:(Signal.map (fun (current : Model.logseq_model) -> current.new_graph_password) model_source)
        ~accessibility_identifier:"field.graph-create.password"
        ~on_input:(on_input send (fun value -> Model.ChangeNewGraphPassword value)) [];
      secure_field ~label:(View_base.tr (Signal.sample model_source) "Confirm E2EE password") ~placeholder:(View_base.tr (Signal.sample model_source) "Confirm E2EE password")
        ~text_signal:(Signal.map (fun (current : Model.logseq_model) -> current.new_graph_password_confirmation) model_source)
        ~accessibility_identifier:"field.graph-create.password-confirmation"
        ~on_input:(on_input send (fun value -> Model.ChangeNewGraphPasswordConfirmation value)) [];
    ])

let graph_creation_progress model_source : t =
  if_ ~test:(reactive Model.graph_create_active_ model_source)
    (row ~gap:8 ~cross:`center
      [ spinner ~accessibility_identifier:"graph-create.loading" [];
        text ~value:(View_base.tr (Signal.sample model_source) "Creating graph…") ~foreground:"muted-foreground" [] ])

let graph_create_sheet (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    View_base.with_int_prop_signal HeightValue
      (Signal.map (fun (current : Model.logseq_model) ->
        if current.new_graph_encrypted && current.new_graph_password_required then 640 else 480) model_source)
    (sheet ~text:(View_base.tr (Signal.sample model_source) "Add sync graph") ~height:480
      ~accessibility_identifier:"sheet.graph-create"
      ~on_dismiss:(press send Model.DismissCreateGraph)
      [
        column ~grow:1.0 ~gap:0 ~cross:`stretch
          ~accessibility_identifier:"layout.graph-create.sheet"
          [
            scroll ~grow:1.0 [
            column ~gap:20 ~padding:24 ~cross:`stretch ~style_class:"form"
              ~accessibility_identifier:"form.graph-create"
              [
                text_field
                  ~text_signal:
                    (Signal.map View_base.model_new_graph_name
                       model_source)
                  ~placeholder:(View_base.tr (Signal.sample model_source) "Graph name") ~label:(View_base.tr (Signal.sample model_source) "Graph name")
                  ~accessibility_identifier:"field.graph-name"
                  ~on_input:
                    (on_input send (fun text ->
                         Model.ChangeNewGraphName text))
                  [];
                graph_encryption_setup_fields model_source send;
                graph_creation_progress model_source;
                switch_
                  ~checked_signal:
                    (Signal.map View_base.model_new_graph_encrypted_
                       model_source)
                  ~label:(View_base.tr (Signal.sample model_source) "End-to-end encryption")
                  ~accessibility_identifier:"toggle.graph-encryption"
                  ~on_toggle:(fun event ->
                    match event with
                    | ToggleChanged (_node, enabled) ->
                      ignore
                        (send (Model.ToggleNewGraphEncrypted enabled))
                    | _ -> ())
                  ~text:(View_base.tr (Signal.sample model_source) "End-to-end encryption") [];
                text ~style_class:"footnote" ~foreground:"muted-foreground"
                  ~value:
                    "Encryption cannot be changed after the sync graph \
                     is created."
                  [];
                if_
                  ~test:
                    (Signal.map View_base.effect_error_present_
                       model_source)
                  (text
                     ~value_signal:
                       (Signal.map View_base.effect_error_message
                          model_source)
                     ~style_class:"footnote" ~foreground:"destructive"
                     ~accessibility_identifier:"text.graph-create.error"
                     []);
              ] ];
            row ~main:`end_ ~cross:`center ~padding_horizontal:24 ~padding_vertical:16
              [
                toolbar ~orientation:`horizontal ~toolbar_gap:12
                  ~label:(View_base.tr (Signal.sample model_source) "Graph creation actions")
                  ~accessibility_identifier:"toolbar.graph-create"
                  [
                    button ~variant:`ghost
                      ~accessibility_identifier:"button.graph-add.cancel"
                      ~disabled:(reactive Model.graph_create_active_ model_source)
                      ~on_press:(press send Model.DismissCreateGraph)
                      ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
                    button ~variant:`primary
                      ~accessibility_identifier:"button.graph-add.confirm"
                      ~disabled_signal:
                        (Signal.map View_base.graph_create_disabled_
                           model_source)
                      ~on_press:(press send Model.SubmitCreateGraph)
                      ~text:(View_base.tr (Signal.sample model_source) "Add") [];
                  ];
              ];
          ];
      ])
  else
    sheet ~text:(View_base.tr (Signal.sample model_source) "Add sync graph") ~style_class:"navigation-form"
      ~accessibility_identifier:"sheet.graph-create"
      ~on_dismiss:(press send Model.DismissCreateGraph)
      [
        column ~style_class:"form"
          ~accessibility_identifier:"form.graph-create"
          [
            text_field
              ~text_signal:
                (Signal.map View_base.model_new_graph_name model_source)
              ~placeholder:(View_base.tr (Signal.sample model_source) "Graph name") ~label:(View_base.tr (Signal.sample model_source) "Graph name")
              ~accessibility_identifier:"field.graph-name"
              ~on_input:
                (on_input send (fun text -> Model.ChangeNewGraphName text))
              [];
            graph_encryption_setup_fields model_source send;
            list_item ~padding:0
              ~accessibility_identifier:"row.graph-encryption"
              ~on_press:(fun _ ->
                ignore
                  (send
                     (Model.ToggleNewGraphEncrypted
                        (not
                           (Signal.sample
                              (Signal.map
                                 View_base.model_new_graph_encrypted_
                                 model_source))))))
              [
                toggle
                  ~checked_signal:
                    (Signal.map View_base.model_new_graph_encrypted_
                       model_source)
                  ~label:(View_base.tr (Signal.sample model_source) "End-to-end encryption")
                  ~accessibility_identifier:"toggle.graph-encryption"
                  ~on_toggle:(fun event ->
                    match event with
                    | ToggleChanged (_node, enabled) ->
                      ignore
                        (send (Model.ToggleNewGraphEncrypted enabled))
                    | _ -> ())
                  ~text:(View_base.tr (Signal.sample model_source) "End-to-end encryption") [];
              ];
            text ~style_class:"footnote" ~foreground:"muted-foreground"
              ~value:
                "Encryption cannot be changed after the sync graph is \
                 created."
              [];
            if_
              ~test:(Signal.map View_base.effect_error_present_
                       model_source)
              (text
                 ~value_signal:
                   (Signal.map View_base.effect_error_message
                      model_source)
                 ~style_class:"footnote" ~foreground:"destructive"
                 ~accessibility_identifier:"text.graph-create.error" []);
            graph_creation_progress model_source;
          ];
        toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Graph creation actions")
          ~style_class:"navigation-actions"
          ~accessibility_identifier:"toolbar.graph-create"
          [
            button ~style_class:"cancellation-action"
              ~accessibility_identifier:"button.graph-add.cancel"
              ~disabled:(reactive Model.graph_create_active_ model_source)
              ~on_press:(press send Model.DismissCreateGraph)
              ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
            button ~style_class:"confirmation-action"
              ~accessibility_identifier:"button.graph-add.confirm"
              ~disabled_signal:
                (Signal.map View_base.graph_create_disabled_ model_source)
              ~on_press:(press send Model.SubmitCreateGraph)
              ~text:(View_base.tr (Signal.sample model_source) "Add") [];
          ];
      ]

let graph_delete_dialog (context : Lui_ui.ui_context) model_source send : t
    =
  if Lui_ui.host context = KotlinHost then
    dialog ~text:(View_base.tr (Signal.sample model_source) "Delete local graph") ~height:320
      ~accessibility_identifier:"dialog.graph-delete"
      ~on_dismiss:(press send Model.CancelDeleteGraph)
      [
        column ~gap:16 ~cross:`stretch
          [
            row ~gap:12 ~cross:`center
              [
                icon ~name:(`app "warning") ~width:28 ~height:28
                  ~foreground:"destructive"
                  ~accessibility_identifier:"icon.graph-delete-warning" [];
                text
                  ~value_signal:
                    (Signal.map View_base.graph_deletion_message
                       model_source)
                  ~grow:1.0
                  ~accessibility_identifier:"text.graph-delete-warning"
                  [];
              ];
            text ~foreground:"muted-foreground"
              ~value:
                "This graph cannot be recovered after deletion. Make \
                 sure you have a backup."
              [];
            spacer ~grow:1.0 [];
            row ~main:`end_
              [
                toolbar ~orientation:`horizontal ~toolbar_gap:12
                  ~label:(View_base.tr (Signal.sample model_source) "Graph deletion actions")
                  ~accessibility_identifier:"toolbar.graph-delete"
                  [
                    button ~variant:`ghost ~style_class:"cancellation-action"
                      ~accessibility_identifier:
                        "button.graph-delete.cancel"
                      ~on_press:(press send Model.CancelDeleteGraph)
                      ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
                    button ~variant:`destructive
                      ~accessibility_identifier:
                        "button.graph-delete.confirm"
                      ~on_press:(press send Model.ConfirmDeleteGraph)
                      ~text:(View_base.tr (Signal.sample model_source) "Delete") [];
                  ];
              ];
          ];
      ]
  else
    (* Text-and-buttons-only children keep the dialog on the native alert
       path (rich children fall back to a custom sheet). *)
    dialog ~text:(View_base.tr (Signal.sample model_source) "Delete local graph") ~style_class:"alert"
      ~accessibility_identifier:"dialog.graph-delete"
      ~on_dismiss:(press send Model.CancelDeleteGraph)
      [
        text
          ~value_signal:
            (Signal.map View_base.graph_deletion_message model_source)
          ~accessibility_identifier:"text.graph-delete-warning" [];
        text
          ~value:
            "Notice that we can't recover this graph after being \
             deleted. Make sure you have backups before deleting it."
          [];
        button ~style_class:"cancellation-action"
          ~accessibility_identifier:"button.graph-delete.cancel"
          ~on_press:(press send Model.CancelDeleteGraph)
          ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
        button ~variant:`destructive
          ~accessibility_identifier:"button.graph-delete.confirm"
          ~on_press:(press send Model.ConfirmDeleteGraph)
          ~text:(View_base.tr (Signal.sample model_source) "Delete") [];
      ]

let graph_picker_overflow_menu model_source send : t =
 fun context parent ->
   let kotlin_host = Lui_ui.host context = KotlinHost in
   let entries =
     [ menu_item ~text:(View_base.tr (Signal.sample model_source) "Settings")
         ?icon:(if kotlin_host then Some (`app "settings") else None)
         ~on_press:(press send Model.OpenSettings)
         []
     ]
   in
   if kotlin_host then
     menu ~icon:(`app "more-vert") ~label:(View_base.tr (Signal.sample model_source) "More")
       ~accessibility_identifier:"button.overflow-menu" entries context parent
   else
     stack ~width:44 ~height:44
       [ box ~width:24 ~height:24 ~corner_radius:12 ~border_width:2
           ~border_color:"foreground" [];
         menu ~icon:(`app "more-horiz") ~style_class:"capsule" ~label:(View_base.tr (Signal.sample model_source) "More")
           ~accessibility_identifier:"button.connection" entries ]
       context parent

let graph_picker_error_banner model_source : t =
  alert ~variant:`destructive ~accessibility_identifier:"error.banner"
    ~padding:14 ~corner_radius:16 ~border_width:0
    [
      column ~gap:4
        [
          heading ~level:5
            ~value_signal:
              (Signal.map View_base.graph_picker_error_title model_source)
            ~accessibility_identifier:"error.banner.code" [];
          text
            ~value_signal:
              (Signal.map View_base.graph_picker_error_message
                 model_source)
            ~accessibility_identifier:"error.banner.message" [];
        ];
    ]

let graph_password_sheet (context : Lui_ui.ui_context) model_source send
    : t =
  if Lui_ui.host context = KotlinHost then
    sheet ~text:(View_base.tr (Signal.sample model_source) "Unlock encrypted graphs") ~height:360
      ~accessibility_identifier:"sheet.graph-unlock"
      ~on_dismiss:(press send Model.CancelGraphUnlock)
      [
        column ~gap:20 ~cross:`stretch ~grow:1.0
          ~accessibility_identifier:"form.graph-unlock"
          [
            secure_field
              ~text_signal:
                (Signal.map View_base.model_graph_password model_source)
              ~placeholder:(View_base.tr (Signal.sample model_source) "E2EE password") ~label:(View_base.tr (Signal.sample model_source) "E2EE password")
              ~accessibility_identifier:"field.graph-password"
              ~on_input:
                (on_input send (fun text ->
                     Model.ChangeGraphPassword text))
              [];
            text ~style_class:"footnote" ~foreground:"muted-foreground"
              ~value:(View_base.tr (Signal.sample model_source) "Enter your E2EE password to unlock this graph.") [];
            if_
              ~test:
                (Signal.map View_base.graph_unlock_error_present_
                   model_source)
              (text
                 ~value_signal:
                   (Signal.map View_base.graph_unlock_error_message
                      model_source)
                 ~style_class:"footnote" ~foreground:"destructive"
                 ~accessibility_identifier:"text.graph-unlock-error" []);
            spacer ~grow:1.0 [];
            toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Graph unlock actions")
              ~accessibility_identifier:"toolbar.graph-unlock"
              [
                spacer ~grow:1.0 [];
                button ~variant:`ghost
                  ~accessibility_identifier:"button.graph-unlock.cancel"
                  ~on_press:(press send Model.CancelGraphUnlock)
                  ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
                button ~variant:`primary
                  ~accessibility_identifier:"button.graph-unlock"
                  ~disabled_signal:
                    (Signal.map View_base.graph_unlock_disabled_
                       model_source)
                  ~on_press:(press send Model.SubmitGraphPassword)
                  ~text:(View_base.tr (Signal.sample model_source) "Unlock") [];
              ];
          ];
      ]
  else
    sheet ~text:(View_base.tr (Signal.sample model_source) "Unlock encrypted graphs") ~style_class:"navigation-form"
      ~accessibility_identifier:"sheet.graph-unlock"
      ~on_dismiss:(press send Model.CancelGraphUnlock)
      [
      column ~style_class:"form"
        ~accessibility_identifier:"form.graph-unlock"
        [
          secure_field
            ~text_signal:
              (Signal.map View_base.model_graph_password model_source)
            ~placeholder:(View_base.tr (Signal.sample model_source) "E2EE password") ~label:(View_base.tr (Signal.sample model_source) "E2EE password")
            ~accessibility_identifier:"field.graph-password"
            ~on_input:
              (on_input send (fun text -> Model.ChangeGraphPassword text))
            [];
          text ~style_class:"footnote" ~foreground:"muted-foreground"
            ~value:(View_base.tr (Signal.sample model_source) "Enter your E2EE password to unlock this graph.") [];
          if_
            ~test:
              (Signal.map View_base.graph_unlock_error_present_
                 model_source)
            (text
               ~value_signal:
                 (Signal.map View_base.graph_unlock_error_message
                    model_source)
               ~style_class:"footnote" ~foreground:"destructive"
               ~accessibility_identifier:"text.graph-unlock-error" []);
        ];
      toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Graph unlock actions")
        ~style_class:"navigation-actions"
        ~accessibility_identifier:"toolbar.graph-unlock"
        [
          button ~style_class:"cancellation-action"
            ~accessibility_identifier:"button.graph-unlock.cancel"
            ~on_press:(press send Model.CancelGraphUnlock)
            ~text:(View_base.tr (Signal.sample model_source) "Cancel") [];
          button ~style_class:"confirmation-action"
            ~accessibility_identifier:"button.graph-unlock"
            ~disabled_signal:
              (Signal.map View_base.graph_unlock_disabled_ model_source)
            ~on_press:(press send Model.SubmitGraphPassword)
            ~text:(View_base.tr (Signal.sample model_source) "Unlock") [];
        ];
    ]

let graphs_screen (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    list ~accessibility_identifier:"screen.graphs" ~gap:0
      [
        row ~gap:12 ~padding:16
          ~accessibility_identifier:"row.graphs.actions"
          [
            button ~icon:(`app "sync-status") ~variant:`secondary ~grow:1.0
              ~accessibility_identifier:"button.graphs.refresh"
              ~disabled_signal:
                (Signal.map Model.graph_refresh_active_ model_source)
              ~on_press:(press send Model.RefreshGraphs)
              ~text:(View_base.tr (Signal.sample model_source) "Refresh") [];
            button ~icon:(`app "add") ~variant:`primary ~grow:1.0
              ~accessibility_identifier:"button.graph-add"
              ~on_press:(press send Model.OpenCreateGraph)
              ~text:(View_base.tr (Signal.sample model_source) "Add graph") [];
          ];
        if_
          ~test:
            (Signal.map View_base.graphs_screen_error_visible_
               model_source)
          (box ~padding:16
             [ graph_picker_error_banner model_source ]);
        if_
          ~test:(Signal.map Model.graph_refresh_active_ model_source)
          (box ~padding:16
             [ spinner ~accessibility_identifier:"graphs.loading" [] ]);
        box ~padding:16
          [ heading ~level:5 ~value:(View_base.tr (Signal.sample model_source) "Local graphs") [] ];
        if_
          ~test:(Signal.map View_base.local_graphs_empty_ model_source)
          (box ~padding:16
             [
               text ~foreground:"muted-foreground"
                 ~value:(View_base.tr (Signal.sample model_source) "No local graphs") [];
             ]);
        keyed
          ~source:(Signal.map View_base.local_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source true send);
        if_
          ~test:(Signal.map View_base.remote_graphs_present_ model_source)
          (box ~padding:16
             [ heading ~level:5 ~value:(View_base.tr (Signal.sample model_source) "Remote graphs") [] ]);
        keyed
          ~source:(Signal.map View_base.remote_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source false send);
        if_
          ~test:(Signal.map View_base.shared_graphs_present_ model_source)
          (box ~padding:16
             [ heading ~level:5 ~value:(View_base.tr (Signal.sample model_source) "Shared by others") [] ]);
        keyed
          ~source:(Signal.map View_base.shared_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source false send);
      ]
  else
    list ~accessibility_identifier:"screen.graphs" ~gap:4
      [
        list_item ~icon:(`app "refresh") ~min_height:44
          ~accessibility_identifier:"button.graphs.refresh"
          ~disabled_signal:
            (Signal.map Model.graph_refresh_active_ model_source)
          ~on_press:(press send Model.RefreshGraphs)
          ~text:(View_base.tr (Signal.sample model_source) "Refresh") [];
        if_
          ~test:(Signal.map Model.graph_refresh_active_ model_source)
          (spinner ~accessibility_identifier:"graphs.loading" []);
        list_item ~min_height:44
          ~accessibility_identifier:"button.graph-add"
          ~on_press:(press send Model.OpenCreateGraph)
          ~text:(View_base.tr (Signal.sample model_source) "Add sync graph") [];
        if_
          ~test:
            (Signal.map View_base.graphs_screen_error_visible_
               model_source)
          (graph_picker_error_banner model_source);
        heading ~level:5
          ~accessibility_identifier:"heading.graphs.local"
          ~value:(View_base.tr (Signal.sample model_source) "Local graphs") [];
        if_
          ~test:(Signal.map View_base.local_graphs_empty_ model_source)
          (text ~foreground:"secondary" ~value:(View_base.tr (Signal.sample model_source) "No local graphs") []);
        keyed
          ~source:(Signal.map View_base.local_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source true send);
        if_
          ~test:(Signal.map View_base.remote_graphs_present_ model_source)
          (heading ~level:5
             ~accessibility_identifier:"heading.graphs.remote"
             ~value:(View_base.tr (Signal.sample model_source) "Remote graphs") []);
        keyed
          ~source:(Signal.map View_base.remote_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source false send);
        if_
          ~test:(Signal.map View_base.shared_graphs_present_ model_source)
          (heading ~level:5
             ~accessibility_identifier:"heading.graphs.shared"
             ~value:(View_base.tr (Signal.sample model_source) "Shared by others") []);
        keyed
          ~source:(Signal.map View_base.shared_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source false send);
      ]

let kotlin_graph_picker_loading_state model_source () : t =
  column ~grow:1.0 ~main:`center ~cross:`center ~gap:12
    ~accessibility_identifier:"loading.graph-picker"
    [
      spinner ~accessibility_identifier:"graphs.loading" [];
      text ~foreground:"muted-foreground"
        ~value:"Loading sync graphs\xE2\x80\xA6" [];
    ]

let kotlin_graph_picker_empty_state model_source send : t =
  column ~grow:1.0 ~main:`center ~cross:`stretch
    [
      column ~cross:`center ~gap:16
        ~accessibility_identifier:"empty.graph-picker"
        [
          icon ~name:(`app "graph-remote") ~width:48 ~height:48
            ~foreground:"primary" [];
          heading ~level:3 ~value:(View_base.tr (Signal.sample model_source) "No sync graphs yet") [];
          text ~foreground:"muted-foreground" ~text_alignment:`center
            ~value:
              "Create a graph to start capturing and syncing notes on \
               this device."
            [];
          button ~icon:(`app "add") ~variant:`primary
            ~accessibility_identifier:"button.graph-add"
            ~on_press:(press send Model.OpenCreateGraph)
            ~text:(View_base.tr (Signal.sample model_source) "Add sync graph") [];
          button ~icon:(`app "sync-status") ~variant:`ghost
            ~foreground:"foreground"
            ~accessibility_identifier:"button.graphs.refresh"
            ~on_press:(press send Model.RefreshGraphs)
            ~text:(View_base.tr (Signal.sample model_source) "Refresh") [];
        ];
    ]

let kotlin_graph_picker_catalog (context : Lui_ui.ui_context) model_source
    send : t =
  column ~grow:1.0 ~gap:16
    [
      button ~icon:(`app "add") ~variant:`primary
        ~accessibility_identifier:"button.graph-add"
        ~on_press:(press send Model.OpenCreateGraph)
        ~text:(View_base.tr (Signal.sample model_source) "Add sync graph") [];
      scroll ~grow:1.0
        [
          column ~gap:12
            [
              keyed
                ~source:(reactive View_base.model_graphs model_source)
                ~key:View_base.graph_identifier ~cmp:compare
                ~mount:(fun graph_source ->
                  graph_row context model_source graph_source false send);
            ];
        ];
    ]

let graph_picker_screen (context : Lui_ui.ui_context) model_source send : t
    =
  if Lui_ui.host context = KotlinHost then
    column ~accessibility_identifier:"screen.graph-picker" ~main:`start
      ~cross:`stretch ~grow:1.0 ~gap:16 ~padding:24
      [
        row ~main:`space_between ~cross:`center
          [
            heading ~level:3 ~value:(View_base.tr (Signal.sample model_source) "Choose a graph")
              ~accessibility_identifier:"title.graph-picker" [];
            graph_picker_overflow_menu model_source send;
          ];
        text ~foreground:"muted-foreground"
          ~value:
            "Select a Logseq graph to download and sync on this device."
          [];
        if_
          ~test:
            (Signal.map View_base.graph_picker_error_present_ model_source)
          (graph_picker_error_banner model_source);
        if_
          ~test:(Signal.map View_base.empty_graphs_loading_ model_source)
          (kotlin_graph_picker_loading_state model_source ());
        if_
          ~test:
            (Signal.map View_base.empty_graphs_refreshable_ model_source)
          (kotlin_graph_picker_empty_state model_source send);
        if_
          ~test:(Signal.map View_base.graphs_present_ model_source)
          (kotlin_graph_picker_catalog context model_source send);
      ]
  else
    column ~accessibility_identifier:"screen.graph-picker" ~main:`start
      ~grow:1.0 ~max_width:560 ~container_relative_frame:`vertical ~gap:20 ~padding:24
      [
        row ~main:`space_between ~cross:`center
          [
            heading ~level:3 ~value:(View_base.tr (Signal.sample model_source) "Choose a graph") [];
            graph_picker_overflow_menu model_source send;
          ];
        text ~foreground:"muted-foreground"
          ~value:
            "Select a Logseq graph to download and sync on this device."
          [];
        button ~variant:`ghost ~foreground:"foreground"
          ~accessibility_identifier:"button.graph-add"
          ~on_press:(press send Model.OpenCreateGraph)
          ~text:(View_base.tr (Signal.sample model_source) "Add sync graph") [];
        if_
          ~test:
            (Signal.map View_base.graph_picker_error_present_ model_source)
          (graph_picker_error_banner model_source);
        if_
          ~test:(Signal.map View_base.empty_graphs_loading_ model_source)
          (spinner ~accessibility_identifier:"graphs.loading" []);
        if_
          ~test:
            (Signal.map View_base.empty_graphs_refreshable_ model_source)
          (button ~variant:`ghost ~foreground:"foreground"
             ~accessibility_identifier:"button.graphs.refresh"
             ~on_press:(press send Model.RefreshGraphs)
             ~text:(View_base.tr (Signal.sample model_source) "Refresh graphs") []);
        scroll ~grow:1.0
          [
            column ~gap:12
              [
                keyed
                  ~source:(reactive View_base.model_graphs model_source)
                  ~key:View_base.graph_identifier ~cmp:compare
                  ~mount:(fun graph_source ->
                    graph_row context model_source graph_source false
                      send);
              ];
          ];
      ]
