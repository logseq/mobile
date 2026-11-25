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
  row ~gap:8 ~padding_vertical:8 ~flex_wrap:`wrap
    (List.map (fun (id, symbol) ->
      button ~text:symbol ~variant:`secondary ~label:(copy current ("Reaction " ^ symbol))
        ~accessibility_identifier:("reaction." ^ id)
        ~on_press:(send_event send (Model.ToggleDiscussionReaction (target, id)))
        []) Collaboration.emoji_choices)

let reaction_buttons current send item =
  let target = string "id" item in
  let reaction_button reaction =
    let id = string "id" reaction in
    let count = match field "count" reaction with `Int count -> count | _ -> 0 in
    let label = emoji id ^ " " ^ string_of_int count in
    button ~text:label ~variant:(if field "selected" reaction = `Bool true then `primary else `secondary)
      ~label ~on_press:(send_event send (Model.ToggleDiscussionReaction (target, id)))
      [] in
  column ~gap:4 [
    row ~gap:6 ~flex_wrap:`wrap
      (List.map reaction_button (list "reactions" item) @ [
        icon_button ~icon:(`app "reaction-add") ~variant:`ghost ~size:`icon
          ~label:(copy current "Add reaction") ~on_press:(send_event send (Model.ShowReactionPicker (Some target))) []
      ]);
    (if current.Model.reaction_picker = Some target then reaction_picker current send target else box []);
  ]

let comment current send item =
  column ~gap:6 ~padding_vertical:10 [
    text ~value:(let actor = string "actor" item in if actor = "" then copy current "Graph member" else actor)
      ~foreground:"muted-foreground" ~style_class:"caption" [];
    text ~value:(string "text" item) [];
    reaction_buttons current send item;
  ]

let thread_sheet source send =
  let current = Signal.sample source in
  let discussion = Signal.map (fun (current : Model.logseq_model) ->
    let value = field "discussion" current.collaboration in
    if current.discussion_target = Some (string "target" value) then value else `Null) source in
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
      if_ ~test:(Signal.map (fun (current : Model.logseq_model) -> current.discussion_error <> None) source)
        (text ~value:(reactive (Signal.map (fun (current : Model.logseq_model) ->
          Option.value ~default:"" current.discussion_error) source)) ~foreground:"error" []);
      if_ ~test:(Signal.map (fun discussion -> field "subject" discussion <> `Null) discussion)
        (row ~gap:8 ~cross:`center [
          textarea ~grow:1.0 ~min_height:44 ~placeholder:(copy current "Write a comment")
            ~label:(copy current "Write a comment")
            ~text_signal:(Signal.map (fun (current : Model.logseq_model) -> current.discussion_draft) source)
            ~accessibility_identifier:"field.comment"
            ~on_input:(fun text -> ignore (send (Model.EditDiscussionDraft text))) [];
          icon_button ~icon:(`app "comment-send") ~variant:`primary ~size:`icon
            ~label:(copy current "Post comment") ~accessibility_identifier:"button.comment.post"
            ~disabled_signal:(Signal.map (fun (current : Model.logseq_model) ->
              String.trim current.discussion_draft = "" || Model.posting_comment current) source)
            ~on_press:(send_event send Model.PostDiscussionComment) [];
        ]);
    ]]

let overlays source send =
  stack [
    if_ ~test:(Signal.map (fun (current : Model.logseq_model) -> current.discussion_target <> None) source)
      (thread_sheet source send);
    reactive (function
      | None -> box []
      | Some target ->
        let current = Signal.sample source in
        View_base.sheet ~model_source:source ~title:(copy current "Add reaction")
          ~detents:"medium" ~accessibility_identifier:"sheet.reactions"
          ~on_dismiss:(send_event send (Model.ShowReactionPicker None))
          [column ~padding:16 [reaction_picker current send target]])
      (Signal.map (fun (current : Model.logseq_model) ->
        if current.discussion_target = None then current.reaction_picker else None) source)
  ]

let date current item =
  match field "createdAt" item with
  | `Int time when time > 0 ->
    let tm = Unix.localtime (float_of_int time /. 1000.) in
    Printf.sprintf "%04d-%02d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
  | _ -> copy current "Recent"

let notification_screen ~bottom_spacing source send =
  let items = Signal.map Model.notification_items source in
  let current = Signal.sample source in
  scroll ~grow:1.0 ~accessibility_identifier:"screen.notifications"
    [column ~gap:12 ~padding_horizontal:16 ~margin_top:12 ~margin_bottom:bottom_spacing [
      row ~main:`space_between ~cross:`center [
        heading ~value:(copy current "Notifications") ~level:`h1 ~style_class:"semibold" ~accessibility_identifier:"title.notifications" [];
        if_ ~test:(Signal.map (fun current -> Model.notification_count current > 0) source)
          (button ~text:(copy current "Mark all as read") ~variant:`ghost
            ~on_press:(send_event send Model.ReadAllNotifications) []);
      ];
      if_ ~test:(Signal.map ready source)
        (reactive (fun (enabled, error) -> column ~gap:4 [
          button ~text:(copy current (if enabled then "Turn off system notifications" else "Enable system notifications"))
            ~variant:`secondary ~accessibility_identifier:"button.notifications.system"
            ~on_press:(send_event send (Model.SetPushPreference (not enabled))) [];
          (match error with None -> box [] | Some message ->
            text ~value:(copy current message) ~foreground:"muted-foreground" []);
        ]) (Signal.map (fun (current : Model.logseq_model) -> current.push_enabled, current.push_error) source));
      if_ ~test:(Signal.map (fun items -> items = []) items)
        (column ~cross:`center ~padding_vertical:40 [
          text ~value:(copy current "No notifications") ~foreground:"muted-foreground" []
        ]);
      keyed ~source:items ~key:(string "id") ~cmp:String.compare ~mount:(fun item ->
        let id = string "id" (Signal.sample item) in
        let read = Signal.map (fun current -> Model.notification_read current id) source in
        let caption item =
          let action = if string "kind" item = "comment" then "Commented" else "Reacted" in
          let actor = string "actor" item in
          (if actor = "" then copy current "Graph member" else actor) ^ " · " ^ copy current action in
        let label item = caption item ^ ", " ^ string "title" item in
        View_base.with_label_signal (Signal.map label item)
          (button ~text:"" ~label:(label (Signal.sample item)) ~variant:`ghost
          ~accessibility_identifier:("notification." ^ id)
          ~on_press:(send_event send (Model.ReadNotification id))
          [row ~grow:1.0 ~gap:10 ~cross:`center [
            icon ~name:(`app "tab-notifications") ~point_size:18
              ~foreground_signal:(Signal.map (fun read -> if read then "muted-foreground" else "link") read) [];
            column ~grow:1.0 ~gap:4 [
              text ~value:(reactive (Signal.map caption item)) ~style_class:"headline" [];
              text ~value:(reactive (Signal.map (string "title") item)) ~foreground:"muted-foreground" [];
            ];
            text ~value:(reactive (Signal.map (date current) item)) ~style_class:"caption" ~foreground:"muted-foreground" [];
          ]]));
    ]]
