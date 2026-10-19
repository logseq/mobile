open Lui_elements

let attachment_picker_menu send : t =
 fun context parent ->
  let items = [
      menu_item ~icon:(`app "toolbar-attachment")
        ~accessibility_identifier:"button.attachment.files"
        ~text:"File"
        ~on_press:(fun _ ->
          ignore (send (Model.ChooseAttachment "files")))
        [];
      menu_item ~icon:(`app "toolbar-camera")
        ~accessibility_identifier:"button.attachment.camera"
        ~text:"Camera"
        ~on_press:(fun _ ->
          ignore (send (Model.ChooseAttachment "camera")))
        [];
      menu_item ~icon:(`app "composer-photo")
        ~accessibility_identifier:"button.attachment.photos"
        ~text:"Photo"
        ~on_press:(fun _ ->
          ignore (send (Model.ChooseAttachment "photos")))
        [];
      menu_item ~icon:(`app "toolbar-audio")
        ~accessibility_identifier:"button.attachment.audio"
        ~text:"Audio recording"
        ~on_press:(fun _ ->
          ignore (send (Model.ChooseAttachment "audio")))
        [];
    ] in
  let items = if Lui_ui.host context = KotlinHost then items else List.rev items in
  dropdown_menu ~anchor:`above ~anchor_alignment:`start ~min_width:220
    ~style_class:"anchored-popover" ~gap:0
    ~on_dismiss:(press send Model.CloseAttachmentPicker) items context parent

let composer_attachment_button (_context : Lui_ui.ui_context) send : t =
  button ~icon:(`app "composer-add") ~variant:`ghost ~width:32 ~height:32
    ~label:"Add attachment" ~accessibility_identifier:"button.attachment"
    ~on_press:(press send Model.OpenAttachmentPicker)
    []

let composer_task_status_button (_context : Lui_ui.ui_context) send : t =
  button ~icon:(`app "task-todo") ~variant:`ghost ~size:`icon ~width:32
    ~height:32 ~foreground:"border" ~label:"Task status"
    ~accessibility_identifier:"button.task-status"
    ~on_press:(press send Model.OpenTaskStatusPicker)
    []

let composer_asset_preview (context : Lui_ui.ui_context) asset_source : t =
  let asset = Signal.sample asset_source in
  let title = View_base.composer_asset_title asset in
  let path = View_base.composer_asset_path asset in
  if View_base.composer_asset_is_image context asset then
    file_image ~path ~max_pixel_size:384 ~fit:`fill ~width:128 ~height:128
      ~corner_radius:12 ~background:"secondary" ~label:title []
  else
    column ~width:128 ~height:128 ~main:`center ~cross:`center ~gap:4
      ~padding:4 ~background:"secondary" ~corner_radius:12
      [ icon ~name:(`app "composer-file") [];
        text ~value:title ~style_class:"caption line-clamp-3" [] ]

let composer_asset_view (context : Lui_ui.ui_context) asset_source send : t =
  let asset = Signal.sample asset_source in
  stack ~width:128 ~height:128
    ~accessibility_identifier:(View_base.composer_asset_identifier asset)
    [
      composer_asset_preview context asset_source;
      column ~width:128 ~height:128 ~padding:4 ~main:`start
        [
          row ~main:`end_ ~height:24
            [
              button ~icon:(`app "close") ~variant:`ghost ~size:`sm ~width:24
                ~height:24 ~corner_radius:12 ~background:"muted-foreground"
                ~foreground:"white" ~label:"Remove attachment"
                ~accessibility_identifier:"composer.asset.remove"
                ~on_press:(fun _ ->
                  ignore
                    (send
                       (Model.RemoveComposerAsset
                          (Signal.sample asset_source).uuid)))
                [];
            ];
          spacer ~grow:1.0 [];
        ];
    ]

let task_status_row status_source send : t =
  let status = Signal.sample status_source in
  menu_item
    ~text_signal:(reactive View_base.task_status_title status_source)
    ~icon:(View_base.icon_of_wire_name (View_base.task_status_icon_name status))
    ~foreground:(View_base.task_status_foreground status)
    ~accessibility_identifier:(View_base.task_status_identifier status)
    ~on_press:(fun _ ->
      ignore
        (send
           (Model.ChooseTaskStatus
              (Signal.sample status_source).uuid)))
    []

let task_status_picker_dialog model_source send : t =
  dropdown_menu ~anchor:`above ~anchor_alignment:`start ~min_width:220
    ~style_class:"anchored-popover" ~gap:0
    ~on_dismiss:(press send Model.CloseTaskStatusPicker)
    [
      keyed
        ~source:(Signal.map View_base.model_task_statuses model_source)
        ~key:View_base.task_status_identifier ~cmp:compare
        ~mount:(fun status_source -> task_status_row status_source send);
      if_
        ~test:(Signal.map View_base.task_status_selected_ model_source)
        (menu_item ~accessibility_identifier:"button.task-status.clear"
           ~text:"Clear task status"
           ~on_press:(press send Model.ClearTaskStatus)
           []);
    ]

let with_press handler (elem : t) : t =
 fun context parent ->
  let node = elem context parent in
  enable context node Lui_protocol.PressEnabled;
  register_press context node handler;
  node

(* The expanded composer keeps the surface spec from the previous lui pin
   (edf381b): upstream restyled it with a content-hugging `composer-surface`
   column, which changed the capture UI. This is that older spec verbatim,
   minus the parts Logseq does not use. *)
let composer_send_button context ?send_icon send_disabled on_send : t =
  let android_icon = Option.value send_icon ~default:(`send : icon) in
  let apple_icon = Option.value send_icon ~default:(`arrow_up : icon) in
  if Lui_ui.platform context = Lui_protocol.AndroidOS then
    button ~icon:android_icon ~variant:`ghost ~width:36 ~height:36
      ~background:"black" ~foreground:"white" ~corner_radius:18 ~label:"Send"
      ~accessibility_identifier:"button.send" ?disabled_signal:send_disabled
      ~on_press:on_send []
  else
    button ~icon:apple_icon ~variant:`ghost ~width:36 ~height:36
      ~background:"black" ~foreground:"white" ~corner_radius:18 ~label:"Send"
      ~accessibility_identifier:"button.send" ?disabled_signal:send_disabled
      ~on_press:on_send []

let composer_surface ?key ?accessibility_identifier ?attachments
    ?attachments_visible_signal ?(actions = []) ~placeholder ?label ?text
    ?text_signal ?(autofocus = false) ?autofocus_signal ?submit_on_enter
    ?send_icon ?send_disabled_signal ?on_input ?on_submit ?on_send ?on_press ()
    : t =
 fun context parent ->
  let attachment_strip =
    match attachments with
    | None -> []
    | Some content ->
      let strip =
        scroll ~orientation:`horizontal ~height:140 [ row ~gap:8 [ content ] ]
      in
      [
        (match attachments_visible_signal with
         | None -> strip
         | Some test -> if_ ~test strip);
      ]
  in
  let field =
    textarea ~min_height:36 ~style_class:"composer-input" ~placeholder
      ~label:(match label with Some value -> value | None -> placeholder)
      ?text ?text_signal ~autofocus ?submit_on_enter
      ~accessibility_identifier:"field.composer" ?on_input ?on_submit []
  in
  let field =
    match autofocus_signal with
    | None -> field
    | Some signal_ -> View_base.with_bool_prop_signal Lui_protocol.Autofocus signal_ field
  in
  let send_button =
    match on_send with
    | None -> []
    | Some on_send ->
      [ composer_send_button context ?send_icon send_disabled_signal on_send ]
  in
  let capsule =
    column ?key ?accessibility_identifier ~grow:1.0 ~min_height:58 ~main:`end_
      ~gap:0
      ~padding_horizontal:16
      ~padding_vertical:8
      ~background:"glass"
      ~corner_radius:24
      ([ box ~height:6 ~accessibility_identifier:"spacer.composer.top" [] ]
       @ attachment_strip
       @ [
           field;
           box ~height:8
             ~accessibility_identifier:"spacer.composer.field-controls" [];
           row ~gap:8 ~height:44 ~cross:`center
             ~accessibility_identifier:"row.composer.controls"
             (actions
              @ [
                  spacer ~grow:1.0
                    ~accessibility_identifier:"spacer.composer.controls" [];
                ]
              @ send_button);
         ])
  in
  (match on_press with
   | None -> capsule
   | Some handler -> with_press handler capsule)
    context parent

let composer_view (context : Lui_ui.ui_context) model_source send : t =
  box ~accessibility_identifier:"surface.composer.root" ~grow:1.0
    ~min_height:58
    [
      if_
        ~test:(Signal.map View_base.composer_expanded_ model_source)
        (composer_surface
           ~placeholder:"Capture" ~label:"Capture"
           ~text_signal:(reactive View_base.composer_draft model_source)
           ~autofocus_signal:
             (Signal.map View_base.composer_autofocus_ model_source)
           ~attachments:
             (keyed
                ~source:
                  (Signal.map View_base.model_composer_assets model_source)
                ~key:View_base.composer_asset_identifier ~cmp:compare
                ~mount:(fun asset_source ->
                  composer_asset_view context asset_source send))
           ~attachments_visible_signal:
             (Signal.map View_base.composer_assets_present_ model_source)
           ~actions:
             [
               stack
                    [
                      composer_attachment_button context send;
                      if_
                        ~test:
                          (Signal.map
                             View_base.model_attachment_picker_open_
                             model_source)
                        (attachment_picker_menu send);
                    ];
               stack
                 [
                   composer_task_status_button context send;
                   if_
                     ~test:
                       (Signal.map View_base.model_task_status_picker_open_
                          model_source)
                     (task_status_picker_dialog model_source send);
                 ];
             ]
           ~send_icon:(`app "arrow-up")
           ~send_disabled_signal:
             (Signal.map View_base.composer_send_disabled_ model_source)
           ~on_input:(on_input send (fun text ->
                        Model.ChangeComposerDraft text))
           ~on_submit:(press send Model.SendComposer)
           ~on_send:(press send Model.SendComposer)
           ~on_press:(press send Model.FocusComposer)
           ());
      if_
        ~test:(Signal.map View_base.composer_collapsed_ model_source)
        (Lui_element_combine.composer_collapsed
           ~label:"Capture"
           ~accessibility_identifier:"button.composer.expand"
           ~on_press:(press send Model.ExpandComposer) ());
    ]

let outliner_task_status_row block_id status_source send : t =
  let status = Signal.sample status_source in
  menu_item
    ~text_signal:(reactive View_base.task_status_title status_source)
    ~icon:(View_base.icon_of_wire_name (View_base.task_status_icon_name status))
    ~foreground:"secondary"
    ~accessibility_identifier:
      (View_base.outliner_task_status_option_identifier status)
    ~on_press:(fun _ ->
      ignore
        (send
           (Model.SetOutlinerTaskStatus
              (block_id, (Signal.sample status_source).uuid))))
    []
