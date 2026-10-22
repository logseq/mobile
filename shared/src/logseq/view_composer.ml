open Lui_elements

let attachment_picker_items context send =
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
  if Lui_ui.host context = KotlinHost then items else List.rev items

let composer_attachment_button (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    menu_trigger ~icon:(`app "composer-add") ~label:"Add attachment"
      ~accessibility_identifier:"button.attachment"
      [dropdown_menu (attachment_picker_items context send)]
  else
    button ~icon:(`app "composer-add") ~variant:`ghost ~width:32 ~height:44
      ~label:"Add attachment" ~accessibility_identifier:"button.attachment"
      [context_menu (attachment_picker_items context send)]

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

let task_status_row model_source status_source send : t =
  let status = Signal.sample status_source in
  menu_item
    ~text_signal:(reactive View_base.task_status_title status_source)
    ~icon:(View_base.icon_of_wire_name (View_base.task_status_icon_name status))
    ~foreground:(View_base.task_status_foreground status)
    ~selected_signal:(Signal.map (fun (current : Model.logseq_model) ->
      match current.selected_task_status with
      | Some selected -> selected.uuid = status.uuid
      | None -> false) model_source)
    ~accessibility_identifier:(View_base.task_status_identifier status)
    ~on_press:(fun _ ->
      ignore
        (send
           (Model.ChooseTaskStatus
              (Signal.sample status_source).uuid)))
    []

let task_status_picker_items model_source send =
    [
      keyed
        ~source:(Signal.map View_base.model_task_statuses model_source)
        ~key:View_base.task_status_identifier ~cmp:compare
        ~mount:(fun status_source -> task_status_row model_source status_source send);
      if_
        ~test:(Signal.map View_base.task_status_selected_ model_source)
        (menu_item ~accessibility_identifier:"button.task-status.clear"
           ~text:"Clear task status"
           ~on_press:(press send Model.ClearTaskStatus)
           []);
    ]

let composer_task_status_button (context : Lui_ui.ui_context) model_source send : t =
  let icon (current : Model.logseq_model) =
    match current.selected_task_status with
    | Some status ->
      View_base.icon_of_wire_name (View_base.task_status_icon_name status)
    | None -> `app "task-todo" in
  let foreground (current : Model.logseq_model) =
    match current.selected_task_status with
    | Some status -> View_base.task_status_foreground status
    | None -> "border" in
  if Lui_ui.host context = KotlinHost then
    menu_trigger ~icon:(reactive icon model_source)
      ~foreground:(reactive foreground model_source) ~label:"Task status"
      ~accessibility_identifier:"button.task-status"
      [dropdown_menu (task_status_picker_items model_source send)]
  else
    button ~icon_signal:(Signal.map icon model_source)
      ~variant:`ghost ~size:`icon ~width:32 ~height:44
      ~foreground_signal:(Signal.map foreground model_source) ~label:"Task status"
      ~accessibility_identifier:"button.task-status"
      [context_menu (task_status_picker_items model_source send)]

let with_press handler (elem : t) : t =
 fun context parent ->
  let node = elem context parent in
  enable context node Lui_protocol.PressEnabled;
  register_press context node handler;
  node

let composer_send_button context ?send_icon send_disabled on_send : t =
  let android_icon = Option.value send_icon ~default:(`send : icon) in
  let apple_icon = Option.value send_icon ~default:(`arrow_up : icon) in
  if Lui_ui.platform context = Lui_protocol.AndroidOS then
    button ~icon:android_icon ~variant:`primary ~label:"Send"
      ~accessibility_identifier:"button.send" ?disabled_signal:send_disabled
      ~on_press:on_send []
  else
    button ~icon:apple_icon ~variant:`ghost ~width:36 ~height:36
      ~background:"black" ~foreground:"white" ~corner_radius:18 ~label:"Send"
      ~accessibility_identifier:"button.send" ?disabled_signal:send_disabled
      ~on_press:on_send []

let composer_tag_chips model_source send : t =
  if_ ~test:(Signal.map (fun (model : Model.logseq_model) -> model.composer_tags <> []) model_source)
    (scroll ~orientation:`horizontal ~height:40 [row ~gap:6 [
      keyed ~source:(Signal.map (fun (model : Model.logseq_model) -> model.composer_tags) model_source)
        ~key:(fun (tag : Model.sidebar_page) -> tag.uuid) ~cmp:String.compare
        ~mount:(fun source -> let tag = Signal.sample source in
          button ~text_signal:(Signal.map (fun (tag : Model.sidebar_page) -> "#" ^ tag.title) source)
            ~icon:(`app "close") ~icon_placement:`trailing ~variant:`secondary ~corner_radius:16
            ~style_class:"caption single-line" ~min_height:32 ~padding_vertical:0 ~padding_horizontal:10
            ~foreground:"muted-foreground" ~label:("Remove tag " ^ tag.title)
            ~accessibility_identifier:("button.composer.tag.remove." ^ tag.uuid)
            ~on_press:(fun _ -> ignore (send (Model.RemoveComposerTag (Signal.sample source).uuid))) [])
    ]])

let composer_tag_picker model_source send : t =
  if_ ~test:(Signal.map (fun (model : Model.logseq_model) -> model.composer_tags_open && not model.composer_tags_loading) model_source)
    (fun context parent ->
      let model : Model.logseq_model = Signal.sample model_source in
      let seen = Hashtbl.create 32 in
      let options = List.filter (fun (tag : Model.sidebar_page) ->
        if Hashtbl.mem seen tag.uuid then false else (Hashtbl.add seen tag.uuid (); true))
        (model.composer_tag_choices @ model.composer_tags) in
      let property = `Assoc ["attr", `String "block/tags"; "title", `String "Tags"; "kind", `String "class";
        "many", `Bool true; "ref", `Bool true; "editable", `Bool true; "closed", `Bool false;
        "canCreate", `Bool true; "textLayout", `Bool false;
        "filterValues", `List (List.map (fun (tag : Model.sidebar_page) ->
          `Assoc ["title", `String tag.title; "match", `List [`String tag.uuid]]) options);
        "raw", `Assoc ["type", `String "set"; "value", `List (List.map (fun (tag : Model.sidebar_page) ->
          `Assoc ["type", `String "ref-uuid"; "value", `String tag.uuid]) model.composer_tags)]] in
      (View_query.property_editor ~id:"composer.tags" ~column:property model_source property
        (fun () -> ignore (send Model.CloseComposerTags))
        ~submit:(fun fields ->
          let strings name = match List.assoc_opt name fields with Some (`List values) ->
            List.filter_map (function `String value -> Some value | _ -> None) values | _ -> [] in
          let selected = List.filter_map (fun uuid -> List.find_opt (fun (tag : Model.sidebar_page) -> tag.uuid = uuid) options)
            (strings "selectedValues") in
          let created = List.map (fun title -> ({Model.uuid = "new:" ^ Dev_query.Unicode.lowercase title; title} : Model.sidebar_page))
            (strings "newValues") in
          let seen = Hashtbl.create 8 in
          let tags = List.filter (fun (tag : Model.sidebar_page) ->
            let key = Dev_query.Unicode.lowercase tag.title in
            if Hashtbl.mem seen key then false else (Hashtbl.add seen key (); true)) (selected @ created) in
          ignore (send (Model.SetComposerTags tags)))) context parent)

let composer_surface ?key ?accessibility_identifier ?attachments ?tag_strip
    ?attachments_visible_signal ?(actions = []) ~placeholder ?label ?text
    ?text_signal ?(autofocus = false) ?autofocus_signal ?submit_on_enter
    ?send_icon ?send_disabled_signal ?on_input ?on_submit ?on_send ?on_press ()
    : t =
 fun context parent ->
  (* A tap gesture around the whole capsule competes with its native menus.
     Only unused space should request focus; controls own their own touches. *)
  let focus_target ~height ~accessibility_identifier =
    match on_press with
    | None -> box ~height ~accessibility_identifier []
    | Some handler ->
      button ~variant:`ghost ~grow:1.0 ~height ~padding_horizontal:0
        ~label:"Focus capture" ~accessibility_identifier ~on_press:handler [] in
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
  let field = match tag_strip with None -> field | Some tags -> column ~gap:0 [field; tags] in
  let send_button =
    match on_send with
    | None -> []
    | Some on_send ->
      [ composer_send_button context ?send_icon send_disabled_signal on_send ]
  in
  let surface =
    if Lui_ui.host context = KotlinHost then
      column ?key ?accessibility_identifier ~grow:1.0 ~gap:8 ~padding:8
        ~background:"surface-container-low"
        (attachment_strip
         @ [ field;
             row ~gap:8 ~height:48 ~cross:`center
               ~accessibility_identifier:"row.composer.controls"
               (actions
                @ [ spacer ~grow:1.0
                      ~accessibility_identifier:"spacer.composer.controls" [] ]
                @ send_button) ])
    else
    (* Keep the established Apple capsule and its unused-space focus targets. *)
    column ?key ?accessibility_identifier ~grow:1.0 ~min_height:58 ~main:`end_
      ~gap:0
      ~padding_horizontal:16
      ~padding_vertical:8
      ~background:"glass"
      ~corner_radius:24
      ([ focus_target ~height:6 ~accessibility_identifier:"spacer.composer.top" ]
       @ attachment_strip
       @ [
           field;
           focus_target ~height:8
             ~accessibility_identifier:"spacer.composer.field-controls";
           row ~gap:8 ~height:44 ~cross:`center
             ~accessibility_identifier:"row.composer.controls"
             (actions
              @ [
                  focus_target ~height:44
                    ~accessibility_identifier:"spacer.composer.controls";
                ]
              @ send_button);
         ])
  in
  surface context parent

let collapsed_composer (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    row ~grow:1.0 ~gap:8 ~cross:`center ~padding:8
      ~background:"surface-container-low" ~corner_radius:28
      [ button ~icon:(`app "toolbar-camera") ~variant:`secondary ~label:"Camera"
          ~accessibility_identifier:"button.composer.camera"
          ~on_press:(press send (Model.ChooseAttachment "camera")) [];
        button ~variant:`outline ~grow:1.0 ~text:"Capture" ~label:"Capture"
          ~accessibility_identifier:"button.composer.expand"
          ~on_press:(press send Model.ExpandComposer) [] ]
  else
  row ~grow:1.0 ~height:58 ~gap:0 ~cross:`center
    ~background:"glass" ~corner_radius:999
    ~border_width:(if Lui_ui.host context = KotlinHost then 1 else 0)
    ~border_color:"border"
    [
      with_press (press send Model.ExpandComposer)
        (box ~width:8 ~height:58 []);
      button ~icon:(`app "toolbar-camera") ~variant:`ghost ~size:`icon
        ~width:44 ~height:58 ~foreground:"foreground" ~label:"Camera"
        ~accessibility_identifier:"button.composer.camera"
        ~on_press:(press send (Model.ChooseAttachment "camera")) [];
      button ~variant:`ghost ~grow:1.0 ~height:58 ~padding_horizontal:0
        ~foreground:"muted-foreground" ~text_alignment:`start ~style_class:"body"
        ~label:"Capture" ~accessibility_identifier:"button.composer.expand"
        ~on_press:(press send Model.ExpandComposer) ~text:"Capture" [];
    ]

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
           ~tag_strip:(composer_tag_chips model_source send)
           ~actions:
             [
               stack [composer_attachment_button context send];
               stack [composer_task_status_button context model_source send];
               stack [button ~icon:(`app "toolbar-tag") ~variant:`ghost
                 ~width:(if Lui_ui.host context = KotlinHost then 48 else 32) ~height:44
                 ~label:"Add tags" ~accessibility_identifier:"button.composer.tags"
                 ~disabled_signal:(Signal.map (fun (model : Model.logseq_model) -> model.composer_tags_loading) model_source)
                 ~on_press:(press send Model.OpenComposerTags) []];
             ]
           ~send_icon:(if Lui_ui.host context = KotlinHost then `send
                       else `app "arrow-up")
           ~send_disabled_signal:
             (Signal.map View_base.composer_send_disabled_ model_source)
           ~on_input:(on_input send (fun text ->
                        Model.ChangeComposerDraft text))
           ~on_submit:(press send Model.SendComposer)
           ~on_send:(press send Model.SendComposer)
           ~on_press:(press send Model.FocusComposer)
           ());
      composer_tag_picker model_source send;
      if_
        ~test:(Signal.map View_base.composer_collapsed_ model_source)
        (collapsed_composer context send);
    ]

let outliner_task_status_row block_id status_source send : t =
  let status = Signal.sample status_source in
  menu_item
    ~text_signal:(reactive View_base.task_status_title status_source)
    ~icon:(View_base.icon_of_wire_name (View_base.task_status_icon_name status))
    ~foreground:(View_base.task_status_foreground status)
    ~accessibility_identifier:
      (View_base.outliner_task_status_option_identifier status)
    ~on_press:(fun _ ->
      ignore
        (send
           (Model.SetOutlinerTaskStatus
              (block_id, (Signal.sample status_source).uuid))))
    []
