open Lui_elements

let field = Model.collaboration_field
let string = Model.collaboration_string
let list key json = match field key json with `List values -> values | _ -> []
let send_event send event _ = ignore (send event)
let copy current key = View_base.tr current key
let ready (current : Model.logseq_model) = current.collaboration <> `Null

let emoji id = match List.assoc_opt id Collaboration.emoji_choices with
  | Some value -> value
  | None -> Node_presentation.reaction_emoji id

let reaction_picker current send target =
  row ~gap:4 ~main:`center ~padding_vertical:6 ~flex_wrap:`wrap
    (List.map (fun (id, symbol) ->
      button ~text:symbol ~variant:`secondary ~min_width:44 ~height:48
        ~label:(copy current ("Reaction " ^ symbol))
        ~accessibility_identifier:("reaction." ^ id)
        ~on_press:(send_event send (Model.ToggleDiscussionReaction (target, id)))
        []) Collaboration.emoji_choices)

let reaction_chip current send target reaction =
  let id = string "id" reaction in
  let count = match field "count" reaction with `Int count -> count | _ -> 0 in
  let selected = field "selected" reaction = `Bool true in
  let label = emoji id ^ " " ^ string_of_int count in
  if not (ready current) then
    text ~value:label ~padding_horizontal:8 ~padding_vertical:4 ~corner_radius:12
      ~background:"muted" ~style_class:"caption" []
  else
    box ~corner_radius:14
      ~background:(if selected then "task-tab-selected-background" else "task-tab-background") [
      button ~text:label ~size:`sm ~min_height:36 ~min_width:44 ~variant:`ghost ~selected
        ~foreground:(if selected then "link" else "foreground")
        ~label ~accessibility_identifier:("reaction.block." ^ target ^ "." ^ id)
        ~on_press:(send_event send (Model.ToggleDiscussionReaction (target, id))) [];
    ]

let add_reaction current send target =
  icon_button ~icon:(`app "reaction-add") ~variant:`ghost ~size:`icon
    ~foreground:"muted-foreground" ~width:44 ~height:40 ~label:(copy current "Add reaction")
    ~accessibility_identifier:("reaction.add." ^ target)
    ~on_press:(send_event send (Model.ShowReactionPicker (Some target))) []

let active_picker current send target =
  if current.Model.discussion_target <> None && current.reaction_picker = Some target then
    [reaction_picker current send target]
  else []

let reaction_buttons current send item =
  let target = string "id" item in
  column ~gap:4
    (row ~gap:4 ~cross:`center ~flex_wrap:`wrap
      (List.map (reaction_chip current send target) (list "reactions" item) @
       if ready current then [add_reaction current send target] else [])
     :: active_picker current send target)

let comment current send item =
  let target = string "id" item in
  let chips = match list "reactions" item with
    | [] -> []
    | reactions -> [row ~gap:4 ~flex_wrap:`wrap (List.map (reaction_chip current send target) reactions)] in
  column ~gap:4 ~padding_vertical:4
    ~accessibility_identifier:("outliner.comment." ^ target)
    (row ~gap:4 ~cross:`start
       ([column ~grow:1.0 ~gap:3 [
          text ~value:(let actor = string "actor" item in if actor = "" then copy current "Graph member" else actor)
            ~foreground:"muted-foreground" ~style_class:"caption" [];
          text ~value:(string "text" item) [];
        ]] @ if ready current then [add_reaction current send target] else [])
     :: chips @ active_picker current send target)

let inline current send ~target ~reactions ~threads =
  let count = List.fold_left (fun count thread -> count + List.length (list "comments" thread)) 0 threads in
  let expanded = List.mem target current.Model.expanded_discussions in
  let disclosure =
    if count = 0 then [] else
      let label = copy current (if expanded then "Hide comments" else "Show comments") in
      [button ~text:(copy current "Comments" ^ " · " ^ string_of_int count)
        ~variant:`ghost ~size:`sm ~min_height:40 ~foreground:"muted-foreground"
        ~selected:expanded ~icon:(`app "discussion-comment") ~label
        ~accessibility_identifier:("comments.toggle." ^ target)
        ~on_press:(send_event send (Model.ToggleInlineComments target)) []] in
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
      row ~gap:4 ~cross:`center ~flex_wrap:`wrap
        (List.map (reaction_chip current send target) reactions @ disclosure);
      column ~gap:6 expanded_threads;
    ]

let composer source send ~autofocus =
  let current = Signal.sample source in
  column ~gap:8 [
    if_ ~test:(Signal.map (fun (current : Model.logseq_model) -> current.discussion_error <> None) source)
      (text ~value:(reactive (Signal.map (fun (current : Model.logseq_model) ->
        Option.value ~default:"" current.discussion_error) source)) ~foreground:"error" []);
    row ~gap:8 ~cross:`end_ [
      textarea ~grow:1.0 ~min_height:(if autofocus then 90 else 44) ~max_height:160 ~autofocus
        ~corner_radius:12 ~background:"input"
        ~placeholder:(copy current "Write a comment") ~label:(copy current "Write a comment")
        ~text_signal:(Signal.map (fun (current : Model.logseq_model) -> current.discussion_draft) source)
        ~accessibility_identifier:"field.comment"
        ~on_input:(fun text -> ignore (send (Model.EditDiscussionDraft text))) [];
      icon_button ~icon:(`app "comment-send") ~variant:`primary ~size:`icon ~width:48 ~height:48
        ~label:(copy current "Post comment") ~accessibility_identifier:"button.comment.post"
        ~disabled_signal:(Signal.map (fun (current : Model.logseq_model) ->
          String.trim current.discussion_draft = "" || Model.posting_comment current) source)
        ~on_press:(send_event send Model.PostDiscussionComment) [];
    ];
  ]

let discussion_source source =
  Signal.map (fun (current : Model.logseq_model) ->
    let value = field "discussion" current.collaboration in
    if current.discussion_target = Some (string "target" value) then value else `Null) source

let compose_sheet source send =
  let current = Signal.sample source in
  let discussion = discussion_source source in
  let subject = Signal.map (fun value -> string "text" (field "subject" value)) discussion in
  let title = match current.Model.discussion_composition with
    | Some (_, Some _) -> "Reply" | _ -> "Add comment" in
  View_base.sheet ~model_source:source ~title:(copy current title) ~detents:"0.36,large"
    ~accessibility_identifier:"sheet.comment.compose" ~on_dismiss:(send_event send Model.CloseDiscussion)
    [column ~gap:10 ~padding:16 [
      if_ ~test:(Signal.map (fun title -> title <> "") subject)
        (text ~value:(reactive subject) ~line_clamp:2 ~foreground:"muted-foreground" []);
      composer source send ~autofocus:true;
    ]]

let thread_sheet source send =
  let current = Signal.sample source in
  let discussion = discussion_source source in
  let body = reactive (fun (discussion, picker) ->
    let current = { (Signal.sample source) with Model.reaction_picker = picker } in
    match field "subject" discussion with
    | `Null ->
      (match string "error" discussion with
       | "" -> row ~padding:16 ~main:`center [spinner []]
       | message -> text ~value:(copy current message) ~foreground:"muted-foreground" [])
    | subject ->
      column ~gap:12 [
        column ~gap:4 ~margin_bottom:12 [
          text ~value:(string "text" subject) ~style_class:"headline" [];
          reaction_buttons current send subject;
        ];
        (match list "comments" discussion with
         | [] -> text ~value:(copy current "No comments yet") ~foreground:"muted-foreground" []
         | comments -> column ~gap:8 (List.map (comment current send) comments))
      ])
    (Signal.map2 (fun discussion (current : Model.logseq_model) -> discussion, current.reaction_picker) discussion source) in
  View_base.sheet ~model_source:source ~title:(copy current "Comments") ~detents:"large"
    ~accessibility_identifier:"sheet.comments" ~on_dismiss:(send_event send Model.CloseDiscussion)
    [column ~grow:1.0 ~gap:8 ~padding:16 [
      scroll ~grow:1.0 [body];
      if_ ~test:(Signal.map (fun discussion -> field "subject" discussion <> `Null) discussion)
        (composer source send ~autofocus:false);
    ]]

let overlays source send =
  stack [
    reactive (function
      | `Hidden -> box []
      | `Compose -> compose_sheet source send
      | `Thread -> thread_sheet source send)
      (Signal.map (fun (current : Model.logseq_model) ->
        match current.discussion_target, current.discussion_composition with
        | None, _ -> `Hidden | Some _, None -> `Thread | Some _, Some _ -> `Compose) source);
    reactive (function
      | None -> box []
      | Some target ->
        let current = Signal.sample source in
        View_base.sheet ~model_source:source ~title:(copy current "Add reaction")
          ~detents:"0.24" ~accessibility_identifier:"sheet.reactions"
          ~on_dismiss:(send_event send (Model.ShowReactionPicker None))
          [column ~padding:16 [reaction_picker current send target]])
      (Signal.map (fun (current : Model.logseq_model) ->
        if current.discussion_target = None then current.reaction_picker else None) source)
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

let notification_menu ~android source send =
  let current = Signal.sample source in
  let push_label model = copy model (if model.Model.push_enabled
    then "Turn off system notifications" else "Enable system notifications") in
  box ~width:44 ~height:44 [
    menu ~icon:(`app (if android then "more-vert" else "more-horiz"))
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
          heading ~value:(copy current "Notifications") ~level:`h1 ~style_class:"semibold"
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
                  text ~value:(reactive (Signal.map title item)) ~line_clamp:2 [];
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
