module J = Yojson.Basic
module Data = Bot_store

type page = Index | Create | Main of string | Sessions of string * bool | Thread of string * string
  | Settings of string | Automation of string

let is_bot_page = function
  | Index | Create -> false
  | Main _ | Sessions _ | Thread _ | Settings _ | Automation _ -> true

type mention = { start : int; stop : int; query : string }

type attachment =
  { uuid : string
  ; title : string
  ; local_path : string
  ; payload : string
  }

type t =
  { page : page
  ; view : J.t
  ; sync_queue : Data.sync list
  ; drafts : (string * string) list
  ; optimistic : (string * J.t list) list
  ; last_send : (string * string) option
  ; bot_references : (string * (string * string)) list
  ; graph_ids : string list
  ; graph_id : string option
  ; shareable_graphs : string list
  ; shared_graph : string option
  ; attachments : (string * attachment list) list
  ; active_mention : mention option
  ; focus_request : bool
  ; name : string
  ; repository : string
  ; graph_target : string
  ; default_agent : string
  ; proposal : J.t
  ; thread_origin : page option
  }

type action =
  | Open of page | Back | Back_steps of int | Reload of int64 option | Retry | Older | Receive of J.t
  | Draft of string | Pick_agent | Select_agent of string | Select_bot of string | Dismiss_mentions
  | Share_graph of bool
  | Stage_attachment of string * attachment | Remove_attachment of string
  | Send | Name of string | Repository of string | Graph_target of string | Default_agent of string
  | Save_bot | Edit_automation of J.t | Rule_field of string * J.t
  | Save_automation | Toggle_automation of string * bool

let empty = {page = Index; view = `Null; sync_queue = []; drafts = []; optimistic = []; last_send = None; bot_references = []; graph_ids = []; graph_id = None; shareable_graphs = []; shared_graph = None; attachments = []; active_mention = None; focus_request = false;
  name = ""; repository = ""; graph_target = ""; default_agent = ""; proposal = `Null;
  thread_origin = None}

let parent_page state = function
  | Index -> None
  | Create | Main _ -> Some Index
  | Settings id | Sessions (id, _) | Automation id -> Some (Main id)
  | Thread (id, _) -> Some (Option.value ~default:(Main id) state.thread_origin)

let navigation_path state =
  let rec collect page path =
    match parent_page state page with
    | None -> path
    | Some parent -> collect parent (page :: path) in
  collect state.page []

let bot_path id = "/bots/" ^ id
let route = function
  | Index | Create -> "/bots"
  | Main id | Sessions (id, _) | Settings id | Automation id -> bot_path id
  | Thread (id, thread) -> bot_path id ^ "/sessions/" ^ thread

let request ?before ?(history_fetched = false) ?path ?(method_ = "GET") ?(body = `Null) state =
  let route = route state.page in
  let fields = ["route", `String route; "path", `String (Option.value ~default:route path);
    "method", `String method_; "body", body] in
  let cursor key = function None -> [] | Some value -> [key, `String (Int64.to_string value)] in
  Some (J.to_string (`Assoc (fields @ cursor "before" before @ ["historyFetched", `Bool history_fetched])))

let draft state = Option.value ~default:"" (List.assoc_opt (route state.page) state.drafts)
let set_draft text state =
  let key = route state.page in
  {state with drafts = (key, text) :: List.remove_assoc key state.drafts}

let attachments_for state key = Option.value ~default:[] (List.assoc_opt key state.attachments)
let attachments state = attachments_for state (route state.page)
let set_attachments state key items =
  let drafts = List.remove_assoc key state.attachments in
  {state with attachments = if items = [] then drafts else (key, items) :: drafts}

let attachment_json attachment =
  `Assoc ["id", `String attachment.uuid; "name", `String attachment.title;
    "localPath", `String attachment.local_path; "payload", `String attachment.payload]

let labels = ["devin", "Devin"; "circle", "Circle"; "cursor", "Cursor"; "codex", "Codex"; "pi", "Pi"]
let label agent = Option.value ~default:agent (List.assoc_opt agent labels)
let selected_bot state = Data.field "bot" state.view
let session state = Data.field "session" state.view

let session_matches ~needs ~query =
  let query = String.lowercase_ascii (String.trim query) in
  fun session ->
    (not needs || Data.string "status" session = "needs_input")
    && (query = "" ||
      Data.string "title" session |> String.trim |> String.lowercase_ascii |> String_kit.includes ~sub:query)

let configured_agents state =
  Data.list "agents" state.view
  |> List.filter_map (fun row ->
    let name = Data.string "name" row in
    if Data.field "available" row = `Bool true && List.mem_assoc name labels then Some name else None)

let is_configured state name = List.mem name (configured_agents state)
let bot_default state = Data.string "default_agent" (selected_bot state)

let automation_agent state =
  match Data.string "agent" state.proposal with "" -> bot_default state | agent -> agent


let agent_character = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '\128' .. '\255' -> true
  | _ -> false

let space = function ' ' | '\t' | '\r' | '\n' -> true | _ -> false

let mention_boundary text start =
  start = 0 || space text.[start - 1] || List.mem text.[start - 1] ['('; '['; '{']

let mention_stop text start =
  let rec loop index =
    if index < String.length text && agent_character text.[index] then loop (index + 1)
    else index in
  loop (start + 1)

let mention_at text caret =
  let rec find_start index =
    if index < 0 then None
    else if agent_character text.[index] then find_start (index - 1)
    else if text.[index] = '@' && mention_boundary text index then Some index
    else None in
  Option.map (fun start ->
    {start; stop = caret;
     query = String.lowercase_ascii (String.sub text (start + 1) (caret - start - 1))})
    (find_start (caret - 1))

let edited_caret previous value =
  let old_length = String.length previous and length = String.length value in
  let rec prefix index =
    if index < min old_length length && previous.[index] = value.[index]
    then prefix (index + 1) else index in
  let start = prefix 0 in
  let rec suffix count =
    if count < min old_length length - start
       && previous.[old_length - count - 1] = value.[length - count - 1]
    then suffix (count + 1) else length - count in
  suffix 0

let mentionable_bots state =
  Data.list "mentionableBots" state.view
  |> List.map (fun bot -> Data.string "id" bot, Data.string "name" bot)

let mention_token text start =
  let quote = start + 1 in
  if quote < String.length text && text.[quote] = '"' then
    let rec closing index =
      if index >= String.length text then None
      else match text.[index] with
        | '"' -> Some (index + 1)
        | '\\' -> closing (index + 2)
        | _ -> closing (index + 1) in
    match closing (quote + 1) with
    | Some stop ->
      (try
         match J.from_string (String.sub text quote (stop - quote)) with
         | `String token -> stop, token, true
         | _ -> stop, "", true
       with Yojson.Json_error _ -> stop, "", true)
    | None -> quote + 1, "", true
  else
    let stop = mention_stop text start in
    stop, String.sub text quote (stop - quote), false

let recipients state =
  let text = draft state in
  let configured = match state.page with Main _ | Thread _ -> configured_agents state | _ -> [] in
  let candidates = mentionable_bots state in
  let preferred = List.assoc_opt (route state.page) state.bot_references in
  let find_bot token =
    let matches = List.filter (fun (_, name) -> String.lowercase_ascii name = token) candidates in
    match preferred, matches with
    | Some (name, id), _ when name = token && List.mem_assoc id matches -> Some id
    | _, [(id, _)] -> Some id
    | _ -> None in
  let rec scan from agents target ranges =
    match String.index_from_opt text from '@' with
    | None -> List.rev agents, target, ranges
    | Some start when mention_boundary text start ->
      let stop, token, quoted = mention_token text start in
      let token = String.lowercase_ascii token in
      if not quoted && List.mem token configured then
        let agents = if List.mem token agents then agents else token :: agents in
        scan stop agents target ((start, stop) :: ranges)
      else (match if target = None then find_bot token else None with
        | Some id -> scan stop agents (Some id) ((start, stop) :: ranges)
        | None -> scan stop agents target ranges)
    | Some start -> scan (start + 1) agents target ranges in
  let agents, target, ranges = scan 0 [] None [] in
  let remove value (start, stop) =
    let before = String.sub value 0 start and after = String.sub value stop (String.length value - stop) in
    let before = if after <> "" && space after.[0] && before <> ""
      && space before.[String.length before - 1] then String.sub before 0 (String.length before - 1)
      else before in
    before ^ after in
  agents, target, String.trim (List.fold_left remove text ranges)

let mentions state =
  let agents, _, body = recipients state in
  List.nth_opt agents 0, body

let unsent state = Option.value ~default:[] (List.assoc_opt (route state.page) state.optimistic)

let latest_send state =
  match state.last_send with
  | Some (key, id) when key = route state.page -> Some id
  | _ -> None

let messages state =
  let saved = Data.list "messages" state.view in
  let queued = Data.list "pending" state.view in
  match queued, unsent state with
  | [], [] -> saved
  | queued, local ->
    let seen = Hashtbl.create (List.length saved) in
    let add message =
      let id = Data.string "id" message in
      if Hashtbl.mem seen id then false
      else (Hashtbl.add seen id (); true) in
    List.iter (fun message -> ignore (add message)) saved;
    saved @ List.filter add (queued @ List.rev local)
let seq message = match Data.field "seq" message with
  | `String raw -> Int64.of_string_opt raw | `Int n -> Some (Int64.of_int n) | _ -> None

let merge_messages fresh prior =
  let seen = Hashtbl.create (List.length fresh + List.length prior) in
  List.iter (fun message -> Hashtbl.replace seen (Data.string "id" message) message) prior;
  List.iter (fun message -> Hashtbl.replace seen (Data.string "id" message) message) fresh;
  Hashtbl.to_seq_values seen |> List.of_seq |> List.sort (fun a b -> compare (seq a) (seq b))

let receive state json =
  let key = Data.string "route" json in
  let acknowledged = Data.list "acknowledged" json in
  let state = match List.assoc_opt key state.optimistic with
    | None -> state
    | Some entries ->
      let settled = Hashtbl.create (List.length entries) in
      let settle message = Hashtbl.replace settled (Data.string "id" message) () in
      List.iter (fun key -> List.iter settle (Data.list key json)) ["messages"; "pending"; "rejected"];
      List.iter settle acknowledged;
      let pending = List.filter (fun message -> not (Hashtbl.mem settled (Data.string "id" message))) entries in
      if pending = entries then state else
        let routes = List.remove_assoc key state.optimistic in
        {state with optimistic = if pending = [] then routes else (key, pending) :: routes} in
  if key <> route state.page then state
  else
    let current = if Data.field "unavailable" json = `Bool true then `Null else state.view in
    let fields = match json with `Assoc fields -> List.remove_assoc "acknowledged" fields | _ -> [] in
    let prior = Data.list "messages" current in
    let fresh = Data.list "messages" json in
    let older = Data.field "older" json = `Bool true in
    let retains_history = match prior, fresh with
      | first :: _, new_first :: _ when seq first < seq new_first ->
        List.exists (fun message -> seq message >= seq new_first) prior
      | _ -> false in
    let more = match Data.field "more" json with
      | `Null -> Data.field "more" current
      | _ when retains_history && not older -> Data.field "more" current
      | value -> value in
    let merged = match Data.field "messages" json with
      | `List _ when older || retains_history -> merge_messages fresh prior
      | `List _ -> merge_messages acknowledged fresh
      | _ when acknowledged <> [] -> merge_messages acknowledged prior
      | _ -> prior in
    let previous = match current with `Assoc fields -> fields | _ -> [] in
    let keep = List.filter (fun (key, _) -> not (List.mem_assoc key fields)) previous in
    let state = match Data.list "rejected" json with
      | [rejected] when draft state = "" && attachments state = [] ->
        let target = Data.string "targetBotId" rejected in
        let bot_prefix = match List.assoc_opt target (mentionable_bots state) with
          | Some name -> "@" ^ J.to_string (`String name) ^ " " | None -> "" in
        let agents = match Data.list "agents" rejected with
          | [] -> (match Data.string "agent" rejected with "" -> [] | name -> [`String name])
          | names -> names in
        let agent_prefix = agents |> List.filter_map (function
          | `String name -> Some ("@" ^ label name ^ " ") | _ -> None) |> String.concat "" in
        let files = Data.list "attachments" rejected |> List.map (fun file -> {
          uuid = Data.string "id" file; title = Data.string "name" file;
          local_path = Data.string "localPath" file; payload = Data.string "payload" file }) in
        set_attachments (set_draft (bot_prefix ^ agent_prefix ^ Data.string "body" rejected) state)
          (route state.page) files
      | _ -> state in
    let graph_list field fallback = match Data.field field json with
      | `List graphs -> List.filter_map (function `String graph -> Some graph | _ -> None) graphs
      | _ -> fallback in
    let graph_ids = graph_list "graphIds" state.graph_ids in
    {state with graph_ids;
      shareable_graphs = graph_list "shareableGraphs" state.shareable_graphs;
      view = `Assoc (["messages", `List merged; "more", more]
      @ List.remove_assoc "messages" (List.remove_assoc "more" (fields @ keep)))}

let update ?selected_graph state action =
  let stay state = state, None in
  let open_page page =
    let same = route state.page = route page in
    let thread_origin = match page, state.page with
      | Thread (id, _), Thread (previous, _) when id = previous -> state.thread_origin
      | Thread _, Thread _ -> None
      | Thread _, origin -> Some origin
      | _ -> None in
    let updated = {state with page; view = (if same then state.view else `Null); thread_origin;
      active_mention = None; focus_request = false} in
    if same && page <> Index && state.view <> `Null then stay updated else updated, request updated in
  let select_mention state token =
    match state.active_mention with
    | None -> state
    | Some {start; stop; _} ->
      let value = draft state in
      let before = String.sub value 0 start and after = String.sub value stop (String.length value - stop) in
      let separator = if after = "" || not (space after.[0]) then " " else "" in
      set_draft (before ^ "@" ^ token ^ separator ^ after) {state with active_mention = None} in
  match action with
  | Open Create ->
    let graph_id = selected_graph in
    let updated = {state with page = Create; name = ""; repository = ""; graph_id; shared_graph = None;
      graph_target = ""; default_agent = (match configured_agents state with
        | names when List.mem "devin" names -> "devin"
        | name :: _ -> name | [] -> ""); active_mention = None; focus_request = false} in
    updated, request updated
  | Open (Settings _ as page) when Data.field "canManage" state.view = `Bool true ->
    let bot = selected_bot state in
    let shared_graph = match Data.field "shared_graph_id" bot with `String id -> Some id | _ -> None in
    let graph_id = match Data.field "graph_id" bot with `String graph -> Some graph | _ -> None in
    stay {state with page; graph_id; shared_graph; default_agent = Data.string "default_agent" bot; active_mention = None; focus_request = false}
  | Open (Settings _) -> stay state
  | Open page -> open_page page
  | Back | Back_steps _ ->
    let count = match action with Back_steps count -> count | _ -> 1 in
    let rec target page count =
      if count <= 0 then page
      else match parent_page state page with
      | None -> page
      | Some parent -> target parent (count - 1) in
    open_page (target state.page count)
  | Reload before -> state, request ?before ~history_fetched:true state
  | Retry -> stay (receive state (`Assoc ["route", `String (route state.page); "feedback", `Null]))
  | Older ->
    (match List.find_map seq (Data.list "messages" state.view) with
    | Some cursor -> state, request ~before:cursor state
    | None -> stay state)
  | Receive json -> stay (receive state json)
  | Draft value ->
    let previous = draft state in
    if previous = value then stay state
    else
      let active_mention = match state.page with
        | Main _ | Thread _ -> mention_at value (edited_caret previous value)
        | _ -> None in
      stay (set_draft value {state with active_mention})
  | Pick_agent ->
    let value = draft state in
    let length = String.length value in
    let updated = {state with focus_request = not state.focus_request} in
    (match state.active_mention, mention_at value length with
    | Some _, _ -> stay {state with active_mention = None}
    | None, Some mention -> stay {updated with active_mention = Some mention}
    | None, None ->
      let value = value ^ (if length = 0 || space value.[length - 1] then "@" else " @") in
      stay (set_draft value {updated with active_mention = mention_at value (String.length value)}))
  | Dismiss_mentions ->
    if state.active_mention = None then stay state else stay {state with active_mention = None}
  | Select_agent agent when is_configured state agent ->
    stay (select_mention state (label agent))
  | Select_agent _ -> stay state
  | Select_bot id ->
    (match List.assoc_opt id (mentionable_bots state), state.active_mention with
    | Some name, Some _ ->
      let key = route state.page in
      let references = (key, (String.lowercase_ascii name, id)) :: List.remove_assoc key state.bot_references in
      stay (select_mention {state with bot_references = references} (J.to_string (`String name)))
    | _ -> stay state)
  | Share_graph false -> stay {state with shared_graph = None}
  | Share_graph true when Option.fold ~none:false ~some:(fun graph -> List.mem graph state.shareable_graphs) state.graph_id ->
    stay {state with shared_graph = state.graph_id}
  | Share_graph _ -> stay state
  | Stage_attachment (key, attachment) ->
    let items = attachments_for state key in
    if List.length items = 4 || List.exists (fun item -> item.uuid = attachment.uuid) items then stay state
    else stay (set_attachments state key (items @ [attachment]))
  | Remove_attachment uuid ->
    stay (set_attachments state (route state.page) (List.filter (fun item -> item.uuid <> uuid) (attachments state)))
  | Send when (match state.page with Main _ | Thread _ -> true | _ -> false) ->
    let agents, target, body = recipients state in
    let files = attachments state in
    if body = "" && files = [] then stay state
    else
      let key = route state.page in
      let id = Session_types.fresh_squuid () in
      let agent = match agents with [] -> `Null | name :: _ -> `String name in
      let workflow = match agents with
        | _ :: _ :: _ -> `List (List.map (fun name -> `String name) agents)
        | _ -> `Null in
      let handoff = Option.fold ~none:`Null ~some:(fun name -> `Assoc ["target_name", `String name])
        (Option.bind target (fun id -> List.assoc_opt id (mentionable_bots state))) in
      let pending = `Assoc ["id", `String id; "author", `String "user"; "pending", `Bool true;
        "body", `String body; "handoff", handoff;
        "requested_agent", agent; "requested_agents", workflow;
        "attachments", `List (List.map (fun file -> `Assoc ["name", `String file.title]) files)] in
      let optimistic = (key, pending :: unsent state) :: List.remove_assoc key state.optimistic in
      let updated = set_attachments (set_draft "" {state with active_mention = None;
        optimistic; last_send = Some (key, id);
        bot_references = List.remove_assoc key state.bot_references}) key [] in
      let body = `Assoc ["id", `String id;
        "targetBotId", Option.fold ~none:`Null ~some:(fun id -> `String id) target;
        "body", `String body; "attachments", `List (List.map attachment_json files);
        "agent", agent; "agents", workflow] in
      updated, request ~path:(key ^ "/messages") ~method_:"POST" ~body state
  | Send -> stay state
  | Name name -> stay {state with name}
  | Repository repository -> stay {state with repository}
  | Graph_target graph_target -> stay {state with graph_target}
  | Default_agent default_agent when default_agent = "" || is_configured state default_agent ->
    stay {state with default_agent}
  | Default_agent _ -> stay state
  | Save_bot ->
    let shared = "sharedGraphId", Option.fold ~none:`Null ~some:(fun id -> `String id) state.shared_graph in
    (match state.page, state.graph_id with
    | Create, Some graph when selected_graph = Some graph && String.trim state.name <> "" && List.mem graph state.graph_ids
        && (state.default_agent = "" || is_configured state state.default_agent) ->
      let graph_fields = match String.trim state.graph_target with
        | "" -> [] | target -> ["graphBlockId", `String target] in
      let body = `Assoc ([shared; "graphId", `String graph; "name", `String state.name; "repository", `String state.repository;
        "defaultAgent", `String state.default_agent] @ graph_fields) in
      let index = {state with page = Index} in
      index, request ~method_:"POST" ~body index
    | Settings id, _ when state.default_agent = "" || is_configured state state.default_agent ->
      let main = {state with page = Main id} in
      main, request ~method_:"PATCH" ~body:(`Assoc [shared; "defaultAgent", `String state.default_agent]) main
    | _ -> stay state)
  | Edit_automation proposal ->
    (match state.page with Main id -> stay {state with page = Automation id; proposal}
    | _ -> stay state)
  | Rule_field (key, value) ->
    (match state.proposal with `Assoc fields ->
      stay {state with proposal = `Assoc ((key, value) :: List.remove_assoc key fields)}
    | _ -> stay state)
  | Save_automation ->
    (match state.page with
    | Automation id when is_configured state (automation_agent state) ->
      let main = {state with page = Main id} in
      main, request ~path:(bot_path id ^ "/automations") ~method_:"POST" ~body:state.proposal main
    | _ -> stay state)
  | Toggle_automation (id, enabled) ->
    state, request ~path:(route state.page ^ "/automations/" ^ id) ~method_:"PATCH"
      ~body:(`Assoc ["enabled", `Bool enabled]) state
