open Lui_elements

let field = Model.collaboration_field
let string = Model.collaboration_string
let list key json = match field key json with `List values -> values | _ -> []
let send_event send event _ = ignore (send event)
let copy current key = View_base.tr current key
let ready (current : Model.logseq_model) = current.collaboration <> `Null

let emoji = Node_presentation.reaction_emoji

let selected_reactions items =
  List.filter_map (fun item -> if field "selected" item = `Bool true
    then Some (string "id" item) else None) items

let reaction_tile ~selected children =
  row ~height:30 ~min_width:34 ~padding_horizontal:6 ~gap:4 ~main:`center ~cross:`center
    ~corner_radius:8
    ~background:(if selected then "task-tab-selected-background" else "task-tab-background")
    children

let reaction_chip current send target reaction =
  let id = string "id" reaction in
  let count = match field "count" reaction with `Int count -> string_of_int count | _ -> "0" in
  let selected = field "selected" reaction = `Bool true in
  let symbol = emoji id in
  let label = symbol ^ " " ^ count in
  let foreground = if selected then "link" else "muted-foreground" in
  let tile = reaction_tile ~selected [
    text ~value:symbol ~font_size:"17" ~white_space:`nowrap ~max_width:40 ~text_overflow:`ellipsis [];
    text ~value:count ~font_size:"13" ~white_space:`nowrap ~foreground [];
  ] in
  if not (ready current) then tile
  else
    let toggle = if selected || Reaction_emoji.find id = None then Model.ToggleDiscussionReaction (target, id)
      else Model.ChooseDiscussionReaction (target, id) in
    button ~text:label ~size:`sm ~min_height:44 ~min_width:44 ~padding_horizontal:0 ~variant:`ghost
      ~selected ~label ~accessibility_identifier:("reaction.block." ^ target ^ "." ^ id)
      ~on_press:(send_event send toggle) [tile]

let add_reaction current send target reactions =
  let label = copy current "Add reaction" in
  button ~text:"" ~size:`sm ~variant:`ghost ~min_width:44 ~min_height:44 ~padding_horizontal:0 ~label
    ~accessibility_identifier:("reaction.add." ^ target)
    ~on_press:(send_event send (Model.OpenReactionPicker (target, selected_reactions reactions)))
    [reaction_tile ~selected:false [
      icon ~name:(`app "reaction-add") ~point_size:16 ~width:16 ~height:16 ~foreground:"muted-foreground" [];
    ]]

let reaction_actions current send target reactions =
  List.map (reaction_chip current send target) reactions @
  if ready current then [add_reaction current send target reactions] else []

let reaction_row actions = row ~gap:4 ~cross:`center ~flex_wrap:`wrap actions

let reaction_buttons current send item =
  reaction_row (reaction_actions current send (string "id" item) (list "reactions" item))

let comment current send item =
  let target = string "id" item in
  let actions = reaction_actions current send target (list "reactions" item) in
  column ~gap:2 ~padding_vertical:4
    ~accessibility_identifier:("outliner.comment." ^ target)
    ([column ~gap:3 [
      text ~value:(let actor = string "actor" item in if actor = "" then copy current "Graph member" else actor)
        ~foreground:"muted-foreground" ~style_class:"caption" [];
      text ~value:(string "text" item) ~foreground:"foreground" [];
    ]] @ if actions = [] then [] else [reaction_row actions])

let inline current send ~target ~reactions ~threads =
  let count = List.fold_left (fun count thread -> count + List.length (list "comments" thread)) 0 threads in
  let expanded = List.mem target current.Model.expanded_discussions in
  let disclosure =
    if count = 0 then [] else
      let label = copy current (if expanded then "Hide comments" else "Show comments") in
      let caption = string_of_int count in
      [button ~text:caption ~variant:`ghost ~size:`sm ~min_height:40 ~foreground:"muted-foreground"
        ~selected:expanded ~label ~accessibility_identifier:("comments.toggle." ^ target)
        ~on_press:(send_event send (Model.ToggleInlineComments target))
        [row ~cross:`center ~gap:5 [
          icon ~name:(`app "discussion-comment") ~point_size:13 ~foreground:"muted-foreground" [];
          text ~value:caption ~font_size:"12" ~foreground:"muted-foreground" [];
        ]]] in
  let expanded_threads =
    if not expanded then [] else
      List.map (fun thread ->
        let reply =
          if not (ready current) then [] else
            [button ~text:(copy current "Reply") ~variant:`ghost ~size:`sm ~min_height:40
              ~accessibility_identifier:("comments.reply." ^ string "id" thread)
              ~on_press:(send_event send (Model.ComposeDiscussion ([target], Some (string "id" thread)))) []] in
        box ~padding_horizontal:12 ~padding_vertical:4 ~corner_radius:10
          ~background:"muted"
          [column ~gap:4 (List.map (comment current send) (list "comments" thread) @ reply)]) threads in
  if count = 0 && reactions = [] then box [] else
    column ~gap:4 ~margin_right:8 ~margin_bottom:6
      ~accessibility_identifier:("discussion.inline." ^ target) [
      reaction_row ((if reactions = [] then [] else reaction_actions current send target reactions) @ disclosure);
      column ~gap:6 expanded_threads;
    ]

let composer source send ~autofocus =
  column ~gap:8 [
    if_ ~test:(Signal.map (fun (current : Model.logseq_model) -> current.discussion_error <> None) source)
      (text ~value:(reactive (Signal.map (fun (current : Model.logseq_model) ->
        Option.value ~default:"" current.discussion_error) source)) ~foreground:"error" []);
    View_composer.comment_input source ~autofocus
      ~text_signal:(Signal.map (fun (current : Model.logseq_model) -> current.discussion_draft) source)
      ~disabled_signal:(Signal.map (fun (current : Model.logseq_model) ->
        String.trim current.discussion_draft = "" || Model.posting_comment current) source)
      ~on_input:(fun text -> ignore (send (Model.EditDiscussionDraft text)))
      ~on_submit:(send_event send Model.PostDiscussionComment);
  ]

let discussion_source source =
  Signal.map (fun (current : Model.logseq_model) ->
    let value = field "discussion" current.collaboration in
    if current.discussion_target = Some (string "target" value) then value else `Null) source

let compose_input source send = composer source send ~autofocus:true

let reaction_picker source send ~target ~owned =
  custom @@ fun context parent ->
  let current = Signal.sample source in
  let query = Signal.state context.Lui_ui.ui_scheduler "" in
  let search = Signal.own_signal context.ui_scope
    (Signal.map String.trim (Signal.value query)) in
  let recent = Reaction_emoji.quick ~limit:Reaction_emoji.recent_limit (Model.recent_reaction_ids current) in
  let recent_ids = List.map (fun (entry : Reaction_emoji.emoji) -> entry.id) recent in
  let entries query =
    if query = "" then recent @
      List.filter (fun (entry : Reaction_emoji.emoji) -> not (List.mem entry.id recent_ids)) (Reaction_emoji.all ())
    else Reaction_emoji.search query in
  let dismiss = send_event send Model.CloseReactionPicker in
  let emoji_row (entry : Reaction_emoji.emoji) =
    let selected = List.mem entry.id owned in
    let label = View_base.tr_named current (if selected then "Remove reaction {1}" else "Add reaction {1}") entry.name in
    box ~height:46 ~corner_radius:8
      ?background:(if selected then Some "task-tab-selected-background" else None) [
      row ~height:46 [
        button ~text:entry.id ~label ~variant:`ghost ~grow:1.0 ~height:46 ~main:`start ~selected
          ~accessibility_identifier:("reaction." ^ entry.id)
          ~on_press:(send_event send (Model.ChooseDiscussionReaction (target, entry.id)))
          [row ~grow:1.0 ~gap:12 ~cross:`center [
             row ~width:28 ~main:`center [text ~value:entry.glyph ~font_size:"20" []];
             text ~value:entry.id ~font_size:"15" ~foreground:"foreground" [];
             box ~grow:1.0 [];
             if selected then icon ~name:(`app "selection-done") ~point_size:14 ~margin_right:8 ~foreground:"link" [] else box [];
           ]];
      ];
    ] in
  let catalog = keyed ~source:(Signal.map (fun query -> [query]) search)
    ~key:Fun.id ~cmp:String.compare ~mount:(fun key ->
      match entries (Signal.sample key) with
      | [] -> text ~value:(copy current "No results") ~foreground:"muted-foreground" ~padding:12 []
      | entries -> virtual_list ~grow:1.0 ~accessibility_identifier:"reaction.catalog" [
        View_rows.windowed_keyed ~identifier:"reaction.catalog.window" ~item_extent:46 ~window_size:16
          ~source:(Signal.constant context.ui_scheduler entries)
          ~key:(fun (entry : Reaction_emoji.emoji) -> entry.id) ~cmp:String.compare
          ~mount:(fun entry -> reactive (Signal.map emoji_row entry)) ();
      ]) in
  let search_label = copy current "Search all emoji" in
  let search_input =
    match Lui_ui.profile context with
    | { profile_os = Lui_protocol.IOS; profile_host = Lui_protocol.SwiftUIHost }
    | { profile_os = Lui_protocol.AndroidOS; profile_host = Lui_protocol.KotlinHost } ->
      box ~grow:1.0 [custom (fun context parent ->
        let node = Lui_ui.extension context "reaction-search-input" in
        attach context parent node;
        Lui_ui.extension_property context node "placeholder" (Lui_protocol.StringValue search_label);
        Lui_ui.extension_property context node "clear-title" (Lui_protocol.StringValue (copy current "Clear"));
        Lui_ui.on_event context node (function
          | Lui_protocol.ExtensionEvent (_, _, "query-changed", values) ->
            (match Lui_protocol.String_map.find_opt "query" values with
             | Some (Lui_protocol.StringValue text) -> Signal.set query text | _ -> ())
          | _ -> ());
        node)]
    | _ -> search_field ~grow:1.0 ~min_height:44 ~text_signal:(Signal.value query)
      ~placeholder:search_label ~label:search_label
      ~accessibility_identifier:"reaction.search" ~on_input:(Signal.set query) [] in
  let content = column ~grow:1.0 ~gap:6 ~padding_horizontal:16 ~padding_vertical:8 [
    row ~gap:8 ~cross:`center [
      search_input;
      box ~width:44 ~height:44 ~corner_radius:22 ~background:"task-tab-background" [
        button ~text:"" ~icon:(`app "close") ~variant:`ghost ~size:`sm ~width:44 ~height:44
          ~foreground:"muted-foreground" ~label:(copy current "Close")
          ~accessibility_identifier:"reaction.close" ~on_press:dismiss [];
      ];
    ];
    separator [];
    box ~grow:1.0 [catalog];
  ] in
  match Lui_ui.profile context with
  | { profile_os = Lui_protocol.IOS; profile_host = Lui_protocol.SwiftUIHost } ->
    let node = Lui_ui.extension context "native-reaction-picker" in
    attach context parent node;
    Lui_ui.on_event context node (function
      | Lui_protocol.ExtensionEvent (_, _, "dismiss", _) -> dismiss ()
      | _ -> ());
    ignore (mount context ~parent:node content);
    node
  | profile ->
    let android = profile.profile_host = Lui_protocol.KotlinHost in
    let sheet = View_base.sheet ~model_source:source
      ~title:(if android then "" else copy current "Add reaction") ~detents:"large"
      ?height:(if android then Some 380 else None)
      ~accessibility_identifier:"sheet.reactions" ~on_dismiss:dismiss [content] in
    let panel =
      if android then
        themed ~tokens:["background", Lui_ui.Adaptive { light = "#F2F2F7"; dark = "#073642" }]
          (stack [sheet])
      else sheet in
    mount context ?parent panel

let reaction_overlay root source send =
  let picker = Signal.map (fun (current : Model.logseq_model) ->
    let thread_open = current.discussion_target <> None && current.discussion_composition = None in
    if root <> thread_open then current.reaction_picker else None) source in
  reactive (function
    | Some (target, owned) -> reaction_picker source send ~target ~owned
    | None -> box []) picker

let thread_sheet source send =
  let current = Signal.sample source in
  let discussion = discussion_source source in
  let body = reactive (fun discussion ->
    let current = Signal.sample source in
    match field "subject" discussion with
    | `Null ->
      (match string "error" discussion with
       | "" -> row ~padding:16 ~main:`center [spinner []]
       | message -> text ~value:(copy current message) ~foreground:"muted-foreground" [])
    | subject ->
      column ~gap:12 [
        column ~gap:4 ~margin_bottom:12 [
          text ~value:(string "text" subject) ~style_class:"headline" ~foreground:"foreground" [];
          reaction_buttons current send subject;
        ];
        (match list "comments" discussion with
         | [] -> text ~value:(copy current "No comments yet") ~foreground:"muted-foreground" []
         | comments -> column ~gap:8 (List.map (comment current send) comments))
      ])
    discussion in
  View_base.sheet ~model_source:source ~title:(copy current "Comments") ~detents:"large"
    ~accessibility_identifier:"sheet.comments" ~on_dismiss:(send_event send Model.CloseDiscussion)
    [column ~grow:1.0 ~gap:8 ~padding:16 [
      scroll ~grow:1.0 [body];
      if_ ~test:(Signal.map (fun discussion -> field "subject" discussion <> `Null) discussion)
        (composer source send ~autofocus:false);
      reaction_overlay false source send;
    ]]

let overlays source send =
  stack [
    if_ ~test:(Signal.map (fun (current : Model.logseq_model) ->
      current.discussion_target <> None && current.discussion_composition = None) source)
      (thread_sheet source send);
    reaction_overlay true source send;
  ]

let date current item =
  match field "createdAt" item with
  | `Int time when time > 0 ->
    let tm = Unix.localtime (float_of_int time /. 1000.) in
    let today = Unix.localtime (Unix.time ()) in
    if tm.Unix.tm_year = today.tm_year && tm.tm_yday = today.tm_yday then
      Printf.sprintf "%02d:%02d" tm.tm_hour tm.tm_min
    else Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
  | _ -> copy current "Recent"

let notification_root (current : Model.logseq_model) =
  current.destination = Model.NotificationsDestination && current.app_navigation_path = []

let notification_button source send =
  let label current =
    let title = copy current "Notifications" in
    if Model.notification_count current > 0
    then title ^ ", " ^ copy current "Unread notifications"
    else title in
  let unread = Signal.map (fun current -> Model.notification_count current > 0) source in
  View_base.with_label_signal (Signal.map label source)
    (button ~text:"" ~label:(label (Signal.sample source)) ~variant:`ghost ~size:`sm
      ~width:44 ~height:44 ~foreground:"foreground" ~padding:0
      ~accessibility_identifier:"button.notifications"
      ~on_press:(send_event send Model.ShowNotifications) [
        overlay ~width:24 ~height:24 [
          icon ~name:(`app "tab-notifications") ~width:22 ~height:22 ~point_size:22
            ~foreground:"foreground" [];
          if_ ~test:unread
            (align `top_trailing (box ~width:6 ~height:6 ~margin_top:2 ~margin_right:1
              ~corner_radius:3 ~background:"link" ~accessibility_identifier:"notifications.unread-dot" []));
        ];
      ])

let notification_menu ~android source send =
  let current = Signal.sample source in
  let push_label model = copy model (if model.Model.push_enabled
    then "Turn off system notifications" else "Enable system notifications") in
  box ~width:44 ~height:44 [
    menu ~icon:(`app (if android then "more-vert" else "more-horiz"))
      ?foreground:(if android then Some "foreground" else None)
      ?style_class:(if android then None else Some "capsule") ~label:(copy current "More")
      ~accessibility_identifier:"button.notifications.more" [
      dropdown_menu_item ~text:(copy current "Mark all as read") ~icon:(`app "selection-done")
        ~disabled_signal:(Signal.map (fun current -> Model.notification_count current = 0) source)
        ~accessibility_identifier:"button.notifications.read-all"
        ~on_press:(send_event send Model.ReadAllNotifications) [];
      dropdown_menu_item ~text_signal:(Signal.map push_label source) ~icon:(`app "tab-notifications")
        ~disabled_signal:(Signal.map (fun current -> List.exists (function
          | Model.PushPreferenceEffect _ -> true | _ -> false)
          (current.Model.pending_effects @ current.in_flight_effects)) source)
        ~accessibility_identifier:"button.notifications.system"
        ~on_press:(fun _ ->
          ignore (send (Model.SetPushPreference (not (Signal.sample source).Model.push_enabled)))) [];
    ];
  ]

let notification_screen ~bottom_spacing source send =
  let items = Signal.map Model.notification_items source in
  let current = Signal.sample source in
  let show_error = Signal.map (fun (current : Model.logseq_model) -> current.push_error) source in
  View_base.with_reading_insets
    (scroll ~grow:1.0 ~accessibility_identifier:"screen.notifications" [
      column ~gap:0 ~margin_bottom:bottom_spacing [
        box ~padding_horizontal:16 ~padding_vertical:12 [
          heading ~value:(copy current "Notifications") ~level:`h1 ~style_class:"semibold" ~foreground:"foreground"
            ~accessibility_identifier:"title.notifications" [];
        ];
        reactive (function
          | None -> box []
          | Some message -> text ~value:(copy current message) ~padding_horizontal:16 ~padding_vertical:6
              ~style_class:"caption" ~foreground:"error" []) show_error;
        if_ ~test:(Signal.map ((=) []) items)
          (row ~container_relative_frame:`horizontal ~main:`center ~padding_horizontal:16 [
            column ~height:180 ~gap:10 ~main:`center ~cross:`center [
              icon ~name:(`app "tab-notifications") ~width:25 ~height:25 ~foreground:"muted-foreground" [];
              text ~value:(copy current "No notifications") ~text_alignment:`center
                ~foreground:"muted-foreground" [];
            ];
          ]);
        keyed ~source:items ~key:(string "id") ~cmp:String.compare ~mount:(fun item ->
          let id = string "id" (Signal.sample item) in
          let read = Signal.map (fun current -> Model.notification_read current id) source in
          let caption item =
            let action = if string "kind" item = "comment" then "Commented" else "Reacted" in
            let author = string "actor" item in
            let author = if author = "" then copy current "Graph member" else author in
            let reaction = string "emoji" item in
            author ^ " · " ^ copy current action ^ (if reaction = "" then "" else " " ^ emoji reaction) in
          let title item =
            let title = string "title" item in
            if String.trim title = "" then copy current "Untitled" else title in
          let label = Signal.map2 (fun read item ->
            (if read then "" else copy current "Unread" ^ ", ") ^ caption item ^ ", " ^ title item) read item in
          View_base.with_label_signal label
            (list_item ~separator:`hidden ~min_height:66 ~padding_horizontal:16
              ~accessibility_identifier:("notification." ^ id)
              ~on_press:(send_event send (Model.ReadNotification id))
              [row ~grow:1.0 ~gap:12 ~cross:`center [
                box ~width:30 ~height:34 ~main:`center ~cross:`center [
                  icon ~name:(`app (if string "kind" (Signal.sample item) = "comment"
                    then "discussion-comment" else "reaction-add"))
                    ~point_size:21 ~foreground:"muted-foreground" [];
                ];
                column ~grow:1.0 ~gap:4 [
                  text ~value:(reactive (Signal.map title item)) ~line_clamp:2 ~foreground:"foreground" [];
                  text ~value:(reactive (Signal.map (fun item -> caption item ^ " · " ^ date current item) item))
                    ~line_clamp:2 ~style_class:"caption" ~foreground:"muted-foreground" [];
                ];
                box ~width:12 ~height:20 ~main:`center ~cross:`center [
                  if_ ~test:(Signal.map not read)
                    (box ~width:6 ~height:6 ~corner_radius:3 ~background:"link" []);
                ];
              ]]));
      ];
    ])
