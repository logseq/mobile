open Lui_elements
module Chat = Bot_chat
module Data = Bot_store

let dispatch send action = ignore (send (Model.BotsAction action))
let tr source value = View_base.tr (Signal.sample source) value
let chat source = Signal.map (fun (current : Model.logseq_model) -> current.bots) source

let colors =
  let adaptive light dark = Lui_ui.Adaptive {light; dark} in
  let wall = adaptive "#FAFCFB" "#15191B" in
  [
    "background", wall;
    "surface", wall;
    "bots-wall", wall;
    "bots-panel", adaptive "#FFFFFF" "#22282B";
    "bots-chip", adaptive "#EDF3F2" "#292F32";
    "bots-ink", adaptive "#182524" "#EFF4F2";
    "bots-muted", adaptive "#586C68" "#A6B1AF";
    "bots-accent", adaptive "#236964" "#A5DAD0";
    "bots-action-ink", adaptive "#FFFFFF" "#162D2A";
    "bots-own", adaptive "#D9EFEC" "#214D4A";
    "bots-own-ink", adaptive "#173B36" "#F2FFFC";
    "bots-warning", adaptive "#91511C" "#F2B77D";
    "bots-avatar-teal", adaptive "#D7F0EA" "#345E57";
    "bots-avatar-blue", adaptive "#E0E8FC" "#414E76";
    "bots-avatar-plum", adaptive "#F3E5F5" "#684764";
    "bots-avatar-sand", adaptive "#F6EBD5" "#6D543C";
    "bots-avatar-ink", adaptive "#293D3A" "#F7FCFA";
  ]

let avatar size ~id name =
  let initials name =
    let first word = if word <> "" && Char.code word.[0] < 128 then
      Some (String.make 1 (Char.uppercase_ascii word.[0])) else None in
    match String.split_on_char ' ' name |> List.filter_map first with
    | first :: second :: _ -> first ^ second
    | [first] -> first
    | [] -> "B" in
  let tones = [|"bots-avatar-teal"; "bots-avatar-blue"; "bots-avatar-plum"; "bots-avatar-sand"|] in
  let role = String.lowercase_ascii name in
  let tone =
    if String.starts_with ~prefix:"qa " role then tones.(3)
    else if String.starts_with ~prefix:"technical " role then tones.(1)
    else if String.starts_with ~prefix:"product " role then tones.(2)
    else tones.(Hashtbl.hash id mod Array.length tones) in
  column ~width:size ~height:size ~corner_radius:(size * 3 / 10)
    ~background:tone ~main:`center ~cross:`center [
    text ~value:(initials name) ~font_size:(if size > 36 then "15" else "11")
      ~foreground:"bots-avatar-ink" ~letter_spacing:0.5 ~font_weight:700 [];
  ]

let icon_control source send image label id event =
  icon_button ~icon:(`app image) ~variant:`ghost ~width:44 ~height:44 ~padding:0
    ~background:"bots-chip" ~corner_radius:22 ~foreground:"bots-ink"
    ~label:(tr source label) ~accessibility_identifier:id
    ~on_press:(fun () -> dispatch send event) []

let back source send = icon_control source send "navigation-back" "Back" "bots.back" Chat.Back

let action source send ?(variant = `outline) title id event =
  button ~text:(tr source title) ~size:`sm ~variant ~min_height:40 ~accessibility_identifier:id
    ~on_press:(fun () -> dispatch send event) []

let heading source send title controls =
  row ~cross:`center ~gap:12 ~padding_vertical:8 ([
    back source send;
    text ~value:title ~grow:1.0 ~min_width:96 ~foreground:"bots-ink"
      ~font_size:"21" ~font_weight:700 ~truncate:true [];
  ] @ controls)

let mention_row source send ?selected ?caption ~identifier ~id title event =
  button ~text:"" ~label:title ~variant:`ghost ~padding:0 ~min_height:47
    ?selected_signal:selected ~accessibility_identifier:identifier
    ~on_press:(fun () -> dispatch send event) [
    row ~grow:1.0 ~min_height:47 ~padding_horizontal:12 ~cross:`center ~gap:10 [
      avatar 28 ~id title;
      column ~grow:1.0 ~cross:`stretch [
        text ~value:title ~text_alignment:`start ~style_class:"body" ~foreground:"bots-ink" [];
      ];
      (match caption with None -> box [] | Some value ->
        text ~value ~font_size:"12" ~foreground:"bots-muted" []);
      (match selected with None -> box [] | Some test ->
        if_ ~test (icon ~name:(`app "selection-done") ~width:18 ~height:18 ~foreground:"bots-accent" []));
    ];
  ]

let agent_row source send ?selected ?caption name event =
  mention_row source send ?selected ?caption ~identifier:("bots.agent." ^ name) ~id:name (Chat.label name) event

let mention_picker source send bots =
  let title label = text ~value:(tr source label) ~padding_horizontal:12 ~padding_vertical:6
    ~font_size:"12" ~font_weight:650 ~foreground:"bots-muted" [] in
  let matching query name =
    String.lowercase_ascii name |> String.split_on_char ' ' |> List.exists (String.starts_with ~prefix:query) in
  let request = Signal.map (fun state ->
    Option.map (fun (mention : Chat.mention) ->
      let default = match state.Chat.page with Chat.Thread _ -> Data.string "agent" (Chat.session state)
        | _ -> Chat.bot_default state in
      mention.query, default, Chat.configured_agents state, Chat.mentionable_bots state) state.Chat.active_mention)
      bots |> Signal.cutoff (=) in
  let visible = Signal.map Option.is_some request in
  if_ ~test:visible (reactive (function
    | None -> box []
    | Some (query, default, agents, candidates) ->
      let names = List.filter (matching query) agents in
      let names = if List.mem default names then default :: List.filter ((<>) default) names else names in
      let bots = List.filter (fun (_, name) -> matching query name) candidates in
      let rows = (match names with [] -> [] | _ -> title "Agents" :: List.map (fun name ->
        agent_row source send ?caption:(if name = default then Some (tr source "Default") else None)
          name (Chat.Select_agent name)) names) @
        (match bots with [] -> [] | _ -> title "Bots" :: List.map (fun (id, name) ->
          mention_row source send ~identifier:("bots.mention." ^ id) ~id name (Chat.Select_bot id)) bots) in
      let rows = if rows = [] then
        [text ~value:(tr source "No matches") ~font_size:"14" ~padding:12 ~foreground:"bots-muted" []]
        else rows in
      column ~width:260 ~padding:5 ~corner_radius:20 ~background:"bots-panel"
        ~border_color:"bots-chip" ~border_width:1 ~accessibility_identifier:"bots.mention-picker"
        (if List.length rows <= 5 then rows else [scroll ~height:230 [column rows]])) request)

let message_card source ~thread message =
  let sender = Data.string "author" message in
  let outgoing = sender = "user" in
  let handoff = Data.field "handoff" message in
  let format label name = View_base.tr_named (Signal.sample source) label name in
  let recipient = Data.string "requested_agent" message in
  let attribution =
    if Data.string "source_name" handoff <> "" then Some (format "From {1}" (Data.string "source_name" handoff))
    else if Data.string "target_name" handoff <> "" then Some (format "To {1}" (Data.string "target_name" handoff))
    else if thread && outgoing && recipient <> "" then Some (format "To {1}" (Chat.label recipient))
    else if thread && not outgoing && sender <> "bot" then Some (Chat.label sender)
    else None in
  let status =
    if Data.field "pending" message = `Bool true then
      Some (String.concat " · " (Option.to_list attribution @ [tr source "Pending"]))
    else attribution in
  let width = (Signal.sample source : Model.logseq_model).viewport_width in
  let width = if width <= 0 then 390 else width in
  let max_bubble = max 180 (min 500 ((width - 36) * 82 / 100)) in
  let body = Data.string "body" message in
  let files = List.map (Data.string "name") (Data.list "attachments" message) in
  let body = String.concat "\n" (if body = "" then files else body :: files) in
  let units line =
    String.fold_left (fun total character ->
      match Char.code character with
      | byte when byte < 128 -> total + 9
      | byte when byte >= 192 -> total + 16
      | _ -> total) 0 line in
  let longest = String.split_on_char '\n' body |> List.fold_left (fun width line -> max width (units line)) 0 in
  let bubble_width = min max_bubble (max 48 (longest + 26)) in
  row ~main:(if outgoing then `end_ else `start) ~padding_vertical:3 [
    column ~cross:(if outgoing then `end_ else `start) ~gap:4 ~width:bubble_width [
      (match status with None -> box [] | Some label ->
        text ~value:label ~foreground:"bots-muted" ~font_size:"12" ~font_weight:600 ~padding_horizontal:6 []);
      box ~corner_radius:16 ~padding_horizontal:13 ~padding_vertical:9
        ~background:(if outgoing then "bots-own" else "bots-panel") [
        text ~value:body ~font_size:"16" ~text_alignment:`start
          ~foreground:(if outgoing then "bots-own-ink" else "bots-ink") [];
      ];
    ];
  ]

let status session =
  match Data.string "status" session with
  | "queued" -> "Queued" | "running" -> "Working" | "completed" -> "Completed"
  | "failed" -> "Failed" | "needs_input" -> "Needs you" | "attention" -> "Check upstream session"
  | value -> value

let session_row ?(compact = false) source send bot_id session =
  let title = Data.string "title" session in
  let id = Data.string "id" session in
  let replies = match Data.field "reply_count" session with `Int count -> count | _ -> 0 in
  let replies = Printf.sprintf "%d %s" replies (tr source (if replies = 1 then "reply" else "replies")) in
  let detail = Printf.sprintf "%s · %s" (Chat.label (Data.string "agent" session)) (tr source (status session)) in
  let open_thread () = dispatch send (Chat.Open (Chat.Thread (bot_id, id))) in
  if compact then
    row ~main:`end_ [
      button ~text:(detail ^ " · " ^ replies) ~icon:(`app "bots-thread")
        ~variant:`ghost ~min_height:40 ~padding_horizontal:10 ~foreground:"bots-accent"
        ~label:(tr source "Open thread") ~accessibility_identifier:("bots.session." ^ id)
        ~on_press:open_thread [];
    ]
  else
    button ~text:"" ~variant:`ghost ~padding:0 ~accessibility_identifier:("bots.session." ^ id)
      ~label:title ~on_press:open_thread [
      row ~min_height:62 ~cross:`center ~gap:12 ~grow:1.0 [
        avatar 36 ~id:(Data.string "agent" session) (Chat.label (Data.string "agent" session));
        column ~gap:4 ~grow:1.0 ~cross:`stretch [
          text ~value:title ~font_size:"16" ~font_weight:650 ~foreground:"bots-ink" ~truncate:true [];
          text ~value:(detail ^ " · " ^ replies) ~font_size:"13" ~foreground:"bots-muted" ~truncate:true [];
        ];
        icon ~name:(`app "bots-next") ~width:14 ~height:14 ~foreground:"bots-muted" [];
      ];
    ]

let shortcut source send icon_name name id event =
  button ~text:name ~icon:(`app icon_name) ~variant:`ghost ~min_height:40 ~padding_horizontal:12
    ~foreground:"bots-ink" ~background:"bots-chip" ~corner_radius:20
    ~accessibility_identifier:id ~on_press:(fun () -> dispatch send event) []

let feedback source send bots =
  reactive (fun state ->
    match Data.string "feedback" state.Chat.view with
    | "" -> box []
    | message -> row ~gap:8 ~cross:`center [
        text ~value:(tr source message) ~grow:1.0 ~font_size:"13" ~foreground:"bots-warning" [];
        action source send "Retry" "bots.retry" Chat.Refresh;
      ])
    (Signal.cutoff (fun a b -> Data.string "feedback" a.Chat.view = Data.string "feedback" b.Chat.view) bots)

let older source send bots =
  if_ ~test:(Signal.map (fun state -> Data.field "more" state.Chat.view = `Bool true) bots)
    (row ~main:`center [
      shortcut source send "bots-history" (tr source "Earlier messages") "bots.older" Chat.Older;
    ])

let coalesced_view bots =
  Signal.cutoff (fun a b -> a.Chat.view = b.Chat.view) bots

let message_view bots =
  Signal.cutoff (fun a b -> a.Chat.view = b.Chat.view && Chat.unsent a = Chat.unsent b) bots

let message_list source bots rows render =
  let message_id (message, _) = Data.string "id" message in
  let rows = Signal.cutoff (=) rows in
  let sent = Signal.map Chat.latest_send bots |> Signal.cutoff (=) in
  custom (fun context parent ->
    let tail = "bots.tail" in
    let at_end = ref true and last_send = ref None and following = ref None in
    let away = Signal.state context.Lui_ui.ui_scheduler false in
    let jump = Signal.state context.Lui_ui.ui_scheduler 0 in
    let own signal = Signal.own_signal context.Lui_ui.ui_scope signal in
    let newest = own (Signal.map2 (fun rows sent ->
      if sent <> !last_send && Option.fold ~none:false
          ~some:(fun id -> List.exists (fun row -> message_id row = id) rows) sent then (
        last_send := sent;
        at_end := true;
        Signal.set away false);
      if !at_end || !following = None then
        following := List.fold_left (fun _ row -> Some (message_id row)) None rows;
      !following) rows sent) |> Signal.cutoff (=) |> own in
    let target = own (Signal.map (Option.map (fun _ -> tail)) newest) in
    let revision = own (Signal.map2 (fun newest jump -> newest, jump) newest (Signal.value jump)) in
    let token = ref 0 in
    let revision = own (Signal.map (fun _ -> incr token; !token) revision) in
    let items = own (Signal.map (fun rows -> if rows = [] then [] else List.map Option.some rows @ [None]) rows) in
    let row_id = Option.fold ~none:tail ~some:message_id in
    let window = View_rows.windowed_keyed ~scroll_target:target ~scroll_revision:revision ~native_scroll_anchor:`bottom
      ~identifier:"bots.messages" ~item_extent:80 ~style:`plain
      ~on_visible_range:(fun _ last ->
        let count = List.length (Signal.sample rows) in
        at_end := count = 0 || last >= count;
        Signal.set away (not !at_end))
      ~source:items ~key:row_id ~cmp:String.compare
      ~mount:(fun item ->
        let key = row_id (Signal.sample item) in
        if key = tail then list_item ~key ~height:1 ~padding:0 ~separator:`hidden [box ~height:1 []]
        else list_item ~key ~padding:0 ~separator:`hidden
          [reactive (function Some row -> render row | None -> box []) item]) () in
    let list = match Lui_ui.host context with
      | KotlinHost -> virtual_list ~grow:1.0 ~accessibility_identifier:"bots.message-scroll" [window]
      | _ -> column ~grow:1.0 ~cross:`stretch [window] in
    overlay ~grow:1.0 ~alignment:`bottom_trailing [
      list;
      if_ ~test:(Signal.value away)
        (icon_button ~icon:(`app "chevron-down") ~label:(tr source "Jump to latest")
          ~variant:`ghost ~width:44 ~height:44 ~padding:0 ~margin:6 ~corner_radius:22
          ~background:"bots-chip" ~foreground:"bots-ink" ~accessibility_identifier:"bots.jump-latest"
          ~on_press:(fun () ->
            at_end := true;
            Signal.set away false;
            Signal.set jump (Signal.sample (Signal.value jump) + 1)) []);
    ] |> mount context ?parent)

let waiting source bots ~thread =
  let working session = List.mem (Data.string "status" session) ["queued"; "running"] in
  let visible = Signal.map (fun state ->
    Chat.unsent state <> [] ||
    if thread then working (Chat.session state)
    else
      match Chat.latest_send state with
      | None -> false
      | Some id -> List.exists (fun session ->
          Data.string "root_message_id" session = id && working session) (Data.list "sessions" state.Chat.view)) bots
      |> Signal.cutoff Bool.equal in
  if_ ~test:visible (row ~gap:8 ~padding_horizontal:8 ~padding_vertical:4 ~cross:`center
    ~accessibility_identifier:"bots.waiting" [
      spinner ~width:14 ~height:14 ~foreground:"bots-muted" [];
      text ~value:(tr source "Waiting for reply…") ~font_size:"13" ~foreground:"bots-muted" [];
    ])

let composer source send bots ~thread =
  let send_title = Signal.map (fun state ->
    let agent, target, _ = Chat.recipients state in
    match Option.bind target (fun id -> List.assoc_opt id (Chat.mentionable_bots state)), agent with
    | Some name, _ -> View_base.tr_named (Signal.sample source) "Send to {1}" name
    | None, Some name -> View_base.tr_named (Signal.sample source) "Send to {1}" (Chat.label name)
    | None, None -> tr source (if thread then "Reply" else "Send")) bots in
  let placeholder = Signal.cutoff String.equal (Signal.map (fun state ->
    if thread then tr source "Reply in thread"
    else match Data.string "name" (Chat.selected_bot state) with
      | "" -> tr source "Message Bot"
      | name -> View_base.tr_named (Signal.sample source) "Message {1}" name) bots) in
  let actions = [
    button ~text:"@" ~variant:`ghost ~width:44 ~height:44 ~padding:0
      ~foreground:"muted-foreground" ~label:(tr source "Mention a Bot or Agent")
      ~accessibility_identifier:"bots.pick-agent" ~on_press:(fun () -> dispatch send Chat.Pick_agent) [];
  ] in
  let disabled = Signal.map (fun state ->
    let _, _, body = Chat.recipients state in
    (body = "" && Chat.attachments state = []) || state.Chat.active_mention <> None) bots in
  View_composer.bot_input source ~placeholder ~label:(tr source (if thread then "Reply" else "Message Bot"))
    ~actions ~assets:(Signal.map Chat.attachments bots |> Signal.cutoff (=)) ~send ~text_signal:(Signal.map Chat.draft bots) ~send_label:send_title ~disabled_signal:disabled
    ~autofocus_signal:(Signal.map (fun state -> state.Chat.focus_request) bots)
    ~on_input:(fun value -> dispatch send (Chat.Draft value)) ~on_send:(fun () -> dispatch send Chat.Send)

let bot_list source send bots =
  column ~grow:1.0 ~gap:12 [
    row ~cross:`center ~main:`space_between ~padding_vertical:8 [
      text ~value:(tr source "Bots") ~font_size:"29" ~font_weight:750 ~foreground:"bots-ink" [];
      icon_control source send "add" "New Bot" "bots.new" (Chat.Open Chat.Create);
    ];
    scroll ~grow:1.0 [reactive (fun state ->
      match Data.list "bots" state.Chat.view with
      | [] -> column ~gap:8 ~padding_vertical:36 ~cross:`center [
          text ~value:(tr source (if state.view = `Null then "Loading Bots…" else "No Bots yet"))
            ~font_size:"16" ~foreground:"bots-muted" [];
          (if state.view = `Null then box [] else
            shortcut source send "add" (tr source "New Bot") "bots.empty.new" (Chat.Open Chat.Create));
        ]
      | rows ->
        column ~gap:4 (List.map (fun bot ->
          let name = Data.string "name" bot and id = Data.string "id" bot in
          button ~text:"" ~label:name ~variant:`ghost ~padding:0 ~accessibility_identifier:("bots.bot." ^ id)
            ~on_press:(fun () -> dispatch send (Chat.Open (Chat.Main id))) [
            row ~cross:`center ~gap:13 ~grow:1.0 ~min_height:64 [
              avatar 46 ~id name;
              column ~grow:1.0 ~gap:4 ~cross:`stretch [
                text ~value:name ~font_size:"17" ~font_weight:650 ~foreground:"bots-ink" ~truncate:true [];
                text ~value:(Data.string "preview" bot) ~font_size:"14" ~foreground:"bots-muted" ~truncate:true [];
              ];
            ];
          ]) rows)) (coalesced_view bots)];
  ]

let conversation source send bots bot_id =
  let rows = Signal.map (fun state ->
    let sessions = Data.list "sessions" state.Chat.view in
    let by_root = Hashtbl.create (List.length sessions) in
    List.iter (fun session -> Hashtbl.replace by_root (Data.string "root_message_id" session) session) sessions;
    List.map (fun message -> message, Hashtbl.find_opt by_root (Data.string "id" message))
      (Chat.messages state)) (message_view bots) in
  let name = Signal.map (fun state -> Data.string "name" (Chat.selected_bot state)) bots
    |> Signal.cutoff String.equal in
  let needs_you = Signal.map (fun state ->
    List.fold_left (fun count session ->
      count + (if Data.string "status" session = "needs_input" then 1 else 0))
      0 (Data.list "sessions" state.Chat.view)) bots |> Signal.cutoff Int.equal in
  column ~grow:1.0 ~gap:8 [
    row ~gap:10 ~cross:`center ~padding_vertical:6 [
      back source send;
      reactive (fun name ->
        column ~grow:1.0 ~gap:6 ~cross:`center [
          avatar 40 ~id:bot_id name;
          text ~value:(if name = "" then tr source "Bot" else name) ~font_size:"17"
            ~font_weight:700 ~foreground:"bots-ink" ~truncate:true [];
        ]) name;
      if_ ~test:(Signal.map (fun state -> Data.field "canManage" state.Chat.view = `Bool true) bots)
        (icon_control source send "more-horiz" "Bot settings" "bots.settings" (Chat.Open (Chat.Settings bot_id)));
    ];
    overlay ~grow:1.0 ~alignment:`bottom_leading [
      column ~grow:1.0 ~gap:8 [
        older source send bots;
        message_list source bots rows (fun (message, session) ->
          column [
            message_card source ~thread:false message;
            (match session with None -> box [] | Some row -> session_row ~compact:true source send bot_id row);
            (match Data.field "proposal" message with
            | `Assoc fields ->
              let proposal = `Assoc (("id", Data.field "id" message) :: fields) in
              row [
                shortcut source send "bots-history" (tr source "Review automation")
                  "bots.automation.review" (Chat.Edit_automation proposal);
              ]
            | _ -> box []);
          ]);
        row ~gap:8 [
          reactive (fun count -> if count = 0 then box [] else
            shortcut source send "bots-attention" (Printf.sprintf "%d · %s" count (tr source "Needs you"))
              "bots.needs-you" (Chat.Open (Chat.Sessions (bot_id, true)))) needs_you;
          shortcut source send "bots-sessions" (tr source "Sessions") "bots.sessions"
            (Chat.Open (Chat.Sessions (bot_id, false)));
        ];
      ];
      mention_picker source send bots;
    ];
    waiting source bots ~thread:false;
    composer source send bots ~thread:false;
  ]

let thread source send bots =
  let rows = Signal.map (fun state ->
    let root = Data.field "root" state.Chat.view in
    let entries = if root = `Null then Chat.messages state else root :: Chat.messages state in
    List.map (fun message -> message, ()) entries) (message_view bots) in
  let header = Signal.map (fun state -> Chat.session state, Data.list "participants" state.Chat.view) bots
    |> Signal.cutoff (=) in
  column ~grow:1.0 ~gap:8 [
    reactive (fun (session, participants) ->
      let names = List.filter_map (function `String agent -> Some (Chat.label agent) | _ -> None) participants in
      let agent = match names with [] -> Chat.label (Data.string "agent" session) | names -> String.concat ", " names in
      let url = Data.string "provider_url" session in
      row ~gap:12 ~cross:`center ~padding_vertical:8 [
        back source send;
        column ~grow:1.0 ~gap:3 [
          text ~value:(tr source "Thread") ~font_size:"21" ~font_weight:700 ~foreground:"bots-ink" [];
          (if agent = "" then box [] else text ~value:(agent ^ " · " ^ tr source (status session))
            ~font_size:"13" ~foreground:"bots-muted" []);
        ];
        (if String.starts_with ~prefix:"https://" url then
          icon_button ~icon:(`app "bots-external") ~variant:`ghost ~width:44 ~height:44 ~padding:0
            ~background:"bots-chip" ~foreground:"bots-ink" ~corner_radius:22 ~label:(tr source "Open run")
            ~on_press:(fun () -> ignore (send (Model.OpenExternalURL url))) []
         else box []);
      ]) header;
    overlay ~grow:1.0 ~alignment:`bottom_leading [
      column ~grow:1.0 ~gap:8 [
        older source send bots;
        message_list source bots rows (fun (message, ()) -> message_card source ~thread:true message);
      ];
      mention_picker source send bots;
    ];
    waiting source bots ~thread:true;
    composer source send bots ~thread:true;
  ]

let form_label value =
  text ~value ~font_size:"13" ~font_weight:600 ~foreground:"bots-muted" []

let form_section title content =
  column ~gap:7 ~cross:`stretch [
    text ~value:title ~font_size:"15" ~font_weight:700 ~padding_horizontal:4 ~foreground:"bots-ink" [];
    column ~gap:2 ~cross:`stretch ~corner_radius:16 ~background:"bots-panel" content;
  ]

let form_field source ~bots ?placeholder id label get change =
  let label = tr source label in
  let placeholder = Option.value ~default:label placeholder in
  column ~grow:1.0 ~gap:4 ~padding_horizontal:12 ~padding_vertical:6 ~cross:`stretch [
    form_label label;
    text_field ~text_signal:(Signal.map get bots) ~label ~placeholder ~min_height:44
      ~accessibility_identifier:id ~on_input:change [];
  ]

let form_footer source send ~disabled label id event =
  let label = tr source label in
  row ~corner_radius:14
    ~background_signal:(Signal.map (fun value -> if value then "bots-chip" else "bots-accent") disabled) [
    button ~text:"" ~label ~variant:`ghost ~min_height:50 ~grow:1.0 ~accessibility_identifier:id
      ~disabled_signal:disabled ~on_press:(fun () -> dispatch send event) [
      text ~value:label ~grow:1.0 ~text_alignment:`center ~style_class:"headline"
        ~foreground_signal:(Signal.map (fun value -> if value then "bots-muted" else "bots-action-ink") disabled) [];
    ];
  ]

let agent_list source send bots ~selected choose =
  let agents = Signal.map Chat.configured_agents bots |> Signal.cutoff (=) in
  reactive (function
    | [] -> text ~value:(tr source "No configured agents") ~padding:14 ~foreground:"bots-muted" []
    | names -> column ~cross:`stretch (List.map (fun name ->
        agent_row source send ~selected:(Signal.map (String.equal name) selected) name (choose name)) names)) agents

let weekdays = [|"Sunday"; "Monday"; "Tuesday"; "Wednesday"; "Thursday"; "Friday"; "Saturday"|]
let weekday source index =
  if index >= 0 && index < Array.length weekdays then tr source weekdays.(index) else ""

let number_field name json =
  match Data.field name json with `Int number -> Some number
  | `String value -> int_of_string_opt value | _ -> None

let schedule_description source rule =
  match number_field "weekday" rule, number_field "hour" rule, number_field "minute" rule with
  | Some day, Some hour, Some minute ->
    let recurrence = View_base.tr_named (Signal.sample source) "Every {1}" (weekday source day) in
    Printf.sprintf "%s · %02d:%02d · %s" recurrence hour minute (Data.string "time_zone" rule)
  | _ -> ""

let automation_list source send bots =
  let rules = Signal.map (fun state -> Data.list "automations" state.Chat.view) bots |> Signal.cutoff (=) in
  reactive (function
    | [] -> form_section (tr source "Automations") [
        text ~value:(tr source "No automations yet") ~padding:14 ~foreground:"bots-muted" [];
      ]
    | rules ->
      form_section (tr source "Automations") (List.map (fun rule ->
        let enabled = Data.field "enabled" rule = `Bool true in
        let id = Data.string "id" rule in
        let agent = match Data.string "agent" rule with
          | "" -> tr source "Follow Bot default" | name -> Chat.label name in
        row ~gap:10 ~padding:12 ~cross:`start [
          icon ~name:(`app "calendar") ~width:20 ~height:20 ~foreground:"bots-accent" [];
          column ~gap:4 ~grow:1.0 [
            text ~value:(Data.string "prompt" rule) ~font_size:"15" ~font_weight:600 ~foreground:"bots-ink" [];
            text ~value:(schedule_description source rule) ~font_size:"12" ~foreground:"bots-muted" [];
            text ~value:(if enabled then agent else agent ^ " · " ^ tr source "Paused")
              ~font_size:"12" ~foreground:"bots-muted" [];
          ];
          icon_button ~icon:(`app (if enabled then "bots-pause" else "bots-resume"))
            ~label:(tr source (if enabled then "Pause automation" else "Resume automation"))
            ~variant:`ghost ~width:44 ~height:44 ~foreground:"bots-accent"
            ~accessibility_identifier:("bots.rule." ^ id)
            ~on_press:(fun () -> dispatch send (Chat.Toggle_automation (id, not enabled))) [];
        ]) rules)) rules

let share_bot source send bots graph =
  let graph_id = Option.map (fun (graph : Model.graph) -> graph.id) graph in
  let enabled = Signal.map (fun state -> state.Chat.shared_graph <> None) bots in
  let can_share = Signal.map (fun state ->
    state.Chat.shared_graph <> None ||
    Option.fold ~none:false ~some:(fun id -> List.mem id state.Chat.shareable_graphs) graph_id) bots in
  if_ ~test:can_share (form_section (tr source "Sharing") [
    custom (fun context parent ->
      let text = match graph with
        | Some graph -> View_base.tr_named (Signal.sample source) "Share with {1}" graph.Model.name
        | None -> tr source "Share with the Graph team" in
      let on_toggle checked = dispatch send (Chat.Share_graph (if checked then graph_id else None)) in
      let id = "bots.share" in
      let control = if Lui_ui.host context = KotlinHost
        then switch_ ~text ~checked_signal:enabled ~on_toggle ~accessibility_identifier:id ~min_height:48 []
        else toggle ~text ~checked_signal:enabled ~on_toggle ~accessibility_identifier:id ~min_height:48 [] in
      mount context ?parent (column ~padding_horizontal:12 [control]));
    text ~value:(tr source "Graph members can see this Bot and its conversations.")
      ~font_size:"13" ~padding_horizontal:12 ~padding_vertical:8 ~foreground:"bots-muted" [];
  ])

let settings source send bots ~creating =
  let form ?placeholder id label get action_ =
    form_field source ~bots ?placeholder id label get (fun value -> dispatch send (action_ value)) in
  let model = (Signal.sample source : Model.logseq_model) in
  let graph = model.selected_graph_id in
  let shared = (Signal.sample bots).Chat.shared_graph in
  let share_graph = Option.bind (Option.fold ~none:graph ~some:Option.some shared)
    (fun id -> List.find_opt (fun (graph : Model.graph) -> graph.id = id) model.graphs) in
  let disabled = Signal.map (fun state ->
    (creating && String.trim state.Chat.name = "")
    || (state.Chat.default_agent <> "" && not (Chat.is_configured state state.Chat.default_agent))) bots in
  column ~grow:1.0 ~gap:10 ~cross:`stretch [
    heading source send (tr source (if creating then "New Bot" else "Bot Settings")) [];
    scroll ~grow:1.0 [column ~gap:20 ~cross:`stretch [
      (if creating then form_section (tr source "Bot") [
         form "bots.name" "Name" (fun state -> state.Chat.name) (fun name -> Chat.Name name);
         form ~placeholder:"owner/repo" "bots.repository" "GitHub repository" (fun state -> state.Chat.repository)
           (fun repository -> Chat.Repository repository);
         (if graph = None then box [] else form "bots.graph-target" "Result block UUID (optional)"
           (fun state -> state.Chat.graph_target) (fun target -> Chat.Graph_target target));
       ] else box []);
      form_section (tr source "Default Agent") [
        button ~text:(tr source "None") ~variant:`ghost ~min_height:44
          ~selected_signal:(Signal.map (fun state -> state.Chat.default_agent = "") bots)
          ~on_press:(fun () -> dispatch send (Chat.Default_agent "")) [];
        agent_list source send bots ~selected:(Signal.map (fun state -> state.Chat.default_agent) bots)
          (fun agent -> Chat.Default_agent agent);
      ];
      share_bot source send bots share_graph;
      (if creating then box [] else automation_list source send bots);
    ]];
    form_footer source send ~disabled (if creating then "Create Bot" else "Save")
      "bots.save" (Chat.Save_bot graph);
  ]

let rule_form source send bots =
  let rule state = state.Chat.proposal in
  let string key state = Data.string key (rule state) in
  let numeric key state = match Data.field key (rule state) with
    | `Int value -> string_of_int value | `String value -> value | _ -> "" in
  let edit id label get key wrap =
    form_field source ~bots id label get (fun value -> dispatch send (Chat.Rule_field (key, wrap value))) in
  let number value = Option.fold ~none:(`String value) ~some:(fun n -> `Int n) (int_of_string_opt value) in
  let day = Signal.map (fun state -> number_field "weekday" (rule state)) bots in
  let day_text = Signal.map (fun index -> Option.fold ~none:(tr source "Choose day") ~some:(weekday source) index) day in
  let selected = Signal.map (string "agent") bots in
  let follow_default = Signal.map (String.equal "") selected in
  let disabled = Signal.map (fun state ->
    let valid key max = match number_field key (rule state) with Some n -> n >= 0 && n <= max | None -> false in
    String.trim (string "prompt" state) = "" || String.trim (string "timeZone" state) = ""
    || not (Chat.is_configured state (Chat.automation_agent state))
    || not (valid "weekday" 6 && valid "hour" 23 && valid "minute" 59)) bots in
  column ~grow:1.0 ~gap:10 ~cross:`stretch [
    heading source send (tr source "New Automation") [];
    scroll ~grow:1.0 [column ~gap:20 ~cross:`stretch [
      form_section (tr source "Task") [
        textarea ~text_signal:(Signal.map (string "prompt") bots) ~label:(tr source "Task")
          ~min_height:64 ~padding:12 ~foreground:"bots-ink" ~style_class:"composer-input"
          ~accessibility_identifier:"bots.rule.prompt"
          ~on_input:(fun value -> dispatch send (Chat.Rule_field ("prompt", `String value))) [];
      ];
      form_section (tr source "Schedule") [
        row ~min_height:44 ~gap:8 ~padding_horizontal:12 ~cross:`center [
          column ~grow:1.0 ~cross:`stretch [
            text ~value:(tr source "Repeats weekly on") ~font_size:"14" ~text_alignment:`start ~foreground:"bots-ink" [];
          ];
          row ~width:132 ~main:`end_ [
            menu ~text_signal:day_text ~label:(tr source "Day of the week") ~foreground:"bots-accent"
              ~accessibility_identifier:"bots.rule.weekday"
              (Array.to_list (Array.mapi (fun index _ ->
                dropdown_menu_item ~text:(weekday source index) ~selected:(reactive (fun day -> day = Some index) day)
                  ~on_press:(fun () -> dispatch send (Chat.Rule_field ("weekday", `Int index))) []) weekdays));
          ];
        ];
        row ~cross:`stretch [
          edit "bots.rule.hour" "Hour (24-hour)" (numeric "hour") "hour" number;
          edit "bots.rule.minute" "Minute" (numeric "minute") "minute" number;
        ];
        edit "bots.rule.zone" "Time zone" (string "timeZone") "timeZone" (fun value -> `String value);
      ];
      form_section (tr source "Agent") [
        if_ ~test:(Signal.map (fun state -> Chat.is_configured state (Chat.bot_default state)) bots)
        (button ~text:"" ~label:(tr source "Follow Bot default") ~variant:`ghost ~padding:0 ~min_height:47
          ~selected_signal:follow_default ~accessibility_identifier:"bots.rule.default"
          ~on_press:(fun () -> dispatch send (Chat.Rule_field ("agent", `Null))) [
          row ~grow:1.0 ~min_height:47 ~padding_horizontal:12 ~cross:`center ~gap:10 [
            icon ~name:(`app "tab-bots") ~width:28 ~height:18 ~foreground:"bots-accent" [];
            column ~grow:1.0 ~cross:`stretch [
              text ~value:(tr source "Follow Bot default") ~text_alignment:`start
                ~style_class:"body" ~foreground:"bots-ink" [];
            ];
            if_ ~test:follow_default
              (icon ~name:(`app "selection-done") ~width:18 ~height:18 ~foreground:"bots-accent" []);
          ];
        ]);
        agent_list source send bots ~selected (fun agent -> Chat.Rule_field ("agent", `String agent));
      ];
    ]];
    form_footer source send ~disabled "Create automation" "bots.rule.save" Chat.Save_automation;
  ]

let sessions source send bots bot_id ~needs =
  custom (fun context parent ->
    let own signal = Signal.own_signal context.Lui_ui.ui_scope signal in
    let query = Signal.state context.ui_scheduler "" in
    let sessions = own (Signal.map (fun state ->
      if state.Chat.view = `Null then None else Some (Data.list "sessions" state.Chat.view)) bots
      |> Signal.cutoff (=)) in
    let results = own (Signal.map2 (fun sessions query ->
      match sessions with
      | None -> `Empty "Loading sessions…"
      | Some sessions ->
        match List.filter (Chat.session_matches ~needs ~query) sessions with
        | [] -> `Empty (if String.trim query = "" then "No sessions yet" else "No matching sessions")
        | rows -> `Rows rows) sessions (Signal.value query) |> Signal.cutoff (=)) in
    let search_label = tr source "Search by title" in
    column ~gap:8 ~grow:1.0 ~cross:`stretch [
      heading source send (tr source (if needs then "Needs you" else "Sessions")) [];
      View_base.filter_search_field ~model_source:source ~text_signal:(Signal.value query)
        ~placeholder:search_label ~label:search_label ~accessibility_identifier:"bots.sessions.search"
        ~on_input:(Signal.set query) ();
      scroll ~grow:1.0 [reactive (function
        | `Empty label -> text ~value:(tr source label) ~foreground:"bots-muted" ~padding_vertical:24 []
        | `Rows rows -> column ~gap:4 (List.map (session_row source send bot_id) rows)) results];
    ] |> mount context ?parent)

let screen ~bottom_spacing source send =
  let bots = chat source in
  let pages = Signal.cutoff (=) (Signal.map (fun state -> state.Chat.page) bots) in
  let spacing = Signal.map (fun page -> if Chat.is_bot_page page then 8 else bottom_spacing) pages in
  themed ~tokens:colors (
  column ~grow:1.0 ~background:"bots-wall" ~accessibility_identifier:"bots.screen" [
  View_base.with_int_prop_signal Lui_protocol.MarginBottom spacing
  (column ~grow:1.0 ~gap:8 ~padding_horizontal:18 ~margin_top:6 [
    dyn (function
      | Chat.Index -> bot_list source send bots
      | Create -> settings source send bots ~creating:true
      | Main id -> conversation source send bots id
      | Thread _ -> thread source send bots
      | Settings _ -> settings source send bots ~creating:false
      | Automation _ -> rule_form source send bots
      | Sessions (id, needs) -> sessions source send bots id ~needs) pages;
    feedback source send bots;
  ])])
