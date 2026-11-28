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
    "bots-stroke", adaptive "#DCE6E4" "#FFFFFF19";
    "bots-ink", adaptive "#182524" "#EFF4F2";
    "bots-muted", adaptive "#586C68" "#A6B1AF";
    "bots-accent", adaptive "#236964" "#A5DAD0";
    "bots-on-accent", adaptive "#FFFFFF" "#162D2A";
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

let agent_choices source send state ~default select =
  let agents = Data.list "agents" state.Chat.view in
  let available name = match List.find_opt (fun row -> Data.string "name" row = name) agents with
    | Some row -> Data.field "available" row = `Bool true | None -> true in
  let names = List.map fst Chat.labels in
  let names = if List.mem default names then default :: List.filter ((<>) default) names else names in
  column ~gap:6 (List.map (fun name ->
    let title = Chat.label name ^ (if available name then "" else " · Offline") in
    action source send title ("bots.agent." ^ name) (select name)) names)

let message_card source ~thread message =
  let sender = Data.string "author" message in
  let outgoing = sender = "user" in
  let status =
    if Data.field "pending" message = `Bool true then Some (tr source "Pending")
    else if thread && not outgoing && sender <> "bot" then Some (Chat.label sender)
    else None in
  let width = (Signal.sample source : Model.logseq_model).viewport_width in
  let width = if width <= 0 then 390 else width in
  let max_bubble = max 180 (min 500 ((width - 36) * 82 / 100)) in
  let body = Data.string "body" message in
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

let message_list rows mount =
  let message_id (message, _) = Data.string "id" message in
  let at_end = ref true and target = ref None in
  let rows = Signal.cutoff (=) rows in
  let newest = Signal.map (fun rows ->
    if !at_end || !target = None then
      target := List.fold_left (fun _ row -> Some (message_id row)) None rows;
    !target) rows |> Signal.cutoff (=) in
  column ~grow:1.0 ~cross:`stretch [
    View_rows.windowed_keyed ~scroll_target:newest ~identifier:"bots.messages" ~item_extent:80 ~style:`plain
      ~on_visible_range:(fun _ last -> at_end := last >= List.length (Signal.sample rows) - 1)
      ~source:rows ~key:message_id ~cmp:String.compare
      ~mount:(fun row -> list_item ~padding:0 ~separator:`hidden [reactive mount row]) ();
  ]

let composer source send bots ~thread =
  let select = if thread then box [] else
    if_ ~test:(Signal.map (fun state -> state.Chat.show_agents) bots)
      (reactive (fun state ->
        let default = Data.string "default_agent" (Chat.selected_bot state) in
        column ~padding:12 ~gap:6 ~background:"bots-panel" ~corner_radius:18 [
          text ~value:(tr source "Send to") ~font_size:"13" ~foreground:"bots-muted" ~font_weight:650 [];
          agent_choices source send state ~default (fun agent -> Chat.Select_agent agent);
        ]) (coalesced_view bots)) in
  let mention = if thread then box [] else
    reactive (fun chosen ->
      match chosen with None -> box []
      | Some agent -> row [
          shortcut source send "bots-thread" ("@" ^ Chat.label agent ^ "  ×") "bots.mention" Chat.Stop_picking;
        ])
      (Signal.cutoff (=) (Signal.map (fun state -> state.Chat.agent) bots)) in
  let send_title = Signal.map (fun state ->
    if thread then tr source "Reply"
    else match fst (Chat.mentions state) with
    | Some agent -> Printf.sprintf "%s %s" (tr source "Send to") (Chat.label agent)
    | None -> tr source "Send") bots in
  let placeholder = Signal.cutoff String.equal (Signal.map (fun state ->
    if thread then tr source "Reply in thread"
    else match Data.string "name" (Chat.selected_bot state) with
      | "" -> tr source "Message Bot"
      | name -> View_base.tr_named (Signal.sample source) "Message {1}" name) bots) in
  column ~gap:7 [
    select;
    mention;
    row ~cross:`center ~gap:4 ~padding:4 ~min_height:52 ~corner_radius:26
      ~background:"bots-panel" ~border_color:"bots-stroke" ~border_width:1 [
      (if thread then box ~width:10 [] else button ~text:"@" ~variant:`ghost ~width:42 ~height:44 ~padding:0
        ~foreground:"bots-muted" ~label:(tr source "Choose an Agent") ~accessibility_identifier:"bots.pick-agent"
        ~on_press:(fun () -> dispatch send Chat.Pick_agent) []);
      textarea ~grow:1.0 ~min_height:38 ~style_class:"composer-input"
        ~background:"transparent" ~foreground:"bots-ink"
        ~accessibility_identifier:"bots.composer"
        ~label:(tr source (if thread then "Reply" else "Message Bot"))
        ~placeholder_signal:placeholder
        ~text_signal:(Signal.map Chat.draft bots)
        ~on_input:(fun value -> dispatch send (Chat.Draft value)) [];
      View_base.with_label_signal send_title
        (icon_button ~icon:(`app "comment-send") ~label:(tr source "Send") ~variant:`ghost ~padding:0
          ~width:44 ~height:44 ~corner_radius:22 ~accessibility_identifier:"bots.send"
          ~background_signal:(Signal.map (fun state ->
            if String.trim (Chat.draft state) = "" then "bots-chip" else "bots-accent") bots)
          ~foreground_signal:(Signal.map (fun state ->
            if String.trim (Chat.draft state) = "" then "bots-muted" else "bots-on-accent") bots)
          ~disabled_signal:(Signal.map (fun state -> snd (Chat.mentions state) = "") bots)
          ~on_press:(fun () -> dispatch send Chat.Send) []);
    ];
  ]

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
      (Chat.messages state)) (coalesced_view bots) in
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
      icon_control source send "more-horiz" "Bot settings" "bots.settings" (Chat.Open (Chat.Settings bot_id));
    ];
    older source send bots;
    message_list rows (fun (message, session) ->
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
    composer source send bots ~thread:false;
  ]

let thread source send bots =
  let rows = Signal.map (fun state ->
    let root = Data.field "root" state.Chat.view in
    let entries = if root = `Null then Chat.messages state else root :: Chat.messages state in
    List.map (fun message -> message, ()) entries) (coalesced_view bots) in
  let header = Signal.map Chat.session bots |> Signal.cutoff (=) in
  column ~grow:1.0 ~gap:8 [
    reactive (fun session ->
      let agent = Chat.label (Data.string "agent" session) in
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
    older source send bots;
    message_list rows (fun (message, ()) -> message_card source ~thread:true message);
    composer source send bots ~thread:true;
  ]

let input source ~bots id label get change =
  text_field ~text_signal:(Signal.map get bots) ~label:(tr source label)
    ~placeholder:(tr source label) ~padding:10 ~border_width:1 ~border_color:"border"
    ~corner_radius:10 ~accessibility_identifier:id ~on_input:change []

let settings source send bots ~creating =
  let form id label get action_ =
    input source ~bots id label get (fun text -> dispatch send (action_ text)) in
  let graph = (Signal.sample source : Model.logseq_model).selected_graph_id in
  column ~grow:1.0 ~gap:12 [
    heading source send (tr source (if creating then "New Bot" else "Settings")) [];
    scroll ~grow:1.0 [column ~cross:`stretch ~gap:10 [
      (if creating then column ~gap:10 [
         form "bots.name" "Bot name" (fun state -> state.Chat.name) (fun name -> Chat.Name name);
         form "bots.repository" "GitHub repository (owner/repo)" (fun state -> state.Chat.repository)
           (fun repository -> Chat.Repository repository);
         (if graph = None then box [] else form "bots.graph-target" "Result block UUID (optional)"
           (fun state -> state.Chat.graph_target) (fun target -> Chat.Graph_target target));
       ] else box []);
      text ~value:(tr source "Default Agent") ~font_weight:600 [];
      text ~value:(reactive (fun state -> Chat.label state.Chat.default_agent) bots) ~foreground:"link" [];
      agent_choices source send (Signal.sample bots) ~default:""
        (fun agent -> Chat.Default_agent agent);
      action source send ~variant:`default (if creating then "Create Bot" else "Save")
        "bots.save" (Chat.Save_bot graph);
      (if creating then box [] else reactive (fun state ->
        column ~gap:8 (List.map (fun rule ->
          let enabled = Data.field "enabled" rule = `Bool true in
          let id = Data.string "id" rule in
          column ~gap:6 [
            text ~value:(Data.string "prompt" rule) [];
            action source send (if enabled then "Pause" else "Resume") ("bots.rule." ^ id)
              (Chat.Toggle_automation (id, not enabled));
          ]) (Data.list "automations" state.Chat.view))) (coalesced_view bots));
    ]];
  ]

let rule_form source send bots =
  let string key state = Data.string key state.Chat.proposal in
  let numeric key state = match Data.field key state.Chat.proposal with
    | `Int value -> string_of_int value | `String value -> value | _ -> "" in
  let edit id label get key wrap =
    input source ~bots id label get (fun text -> dispatch send (Chat.Rule_field (key, wrap text))) in
  let number text = Option.fold ~none:(`String text) ~some:(fun n -> `Int n) (int_of_string_opt text) in
  column ~grow:1.0 ~gap:10 [
    heading source send (tr source "Automation") [];
    scroll ~grow:1.0 [column ~gap:10 [
      edit "bots.rule.prompt" "Task" (string "prompt") "prompt" (fun text -> `String text);
      edit "bots.rule.weekday" "Weekday (0 = Sunday)" (numeric "weekday") "weekday" number;
      row ~gap:8 [
        edit "bots.rule.hour" "Hour (24-hour)" (numeric "hour") "hour" number;
        edit "bots.rule.minute" "Minute" (numeric "minute") "minute" number;
      ];
      edit "bots.rule.zone" "Time zone" (string "timeZone") "timeZone" (fun value -> `String value);
      text ~value:(reactive (fun state ->
        match string "agent" state with "" -> tr source "Follow Bot default" | name -> Chat.label name) bots) [];
      action source send "Follow Bot default" "bots.rule.default" (Chat.Rule_field ("agent", `Null));
      agent_choices source send (Signal.sample bots) ~default:""
        (fun name -> Chat.Rule_field ("agent", `String name));
      action source send ~variant:`default "Create automation" "bots.rule.save" Chat.Save_automation;
    ]];
  ]

let screen ~bottom_spacing source send =
  let bots = chat source in
  let pages = Signal.cutoff (=) (Signal.map (fun state -> state.Chat.page) bots) in
  themed ~tokens:colors (
  column ~grow:1.0 ~background:"bots-wall" ~accessibility_identifier:"bots.screen" [
  column ~grow:1.0 ~gap:8 ~padding_horizontal:18 ~margin_top:6 ~margin_bottom:bottom_spacing [
    dyn (function
      | Chat.Index -> bot_list source send bots
      | Create -> settings source send bots ~creating:true
      | Main id -> conversation source send bots id
      | Thread _ -> thread source send bots
      | Settings _ -> settings source send bots ~creating:false
      | Automation _ -> rule_form source send bots
      | Sessions (id, needs) ->
        column ~gap:8 ~grow:1.0 [
          heading source send (tr source (if needs then "Needs you" else "Sessions")) [];
          scroll ~grow:1.0 [reactive (fun state ->
            let sessions = Data.list "sessions" state.Chat.view in
            let sessions = if needs then List.filter (fun session ->
              Data.string "status" session = "needs_input") sessions else sessions in
            if sessions = [] then
              text ~value:(tr source "No sessions yet") ~foreground:"bots-muted" ~padding_vertical:24 []
            else column ~gap:4 (List.map (session_row source send id) sessions)) (coalesced_view bots)];
        ]) pages;
    feedback source send bots;
  ]])
