module J = Yojson.Basic
module Data = Bot_store

type page = Index | Create | Main of string | Sessions of string * bool | Thread of string * string
  | Settings of string | Automation of string

let is_bot_page = function
  | Index | Create -> false
  | Main _ | Sessions _ | Thread _ | Settings _ | Automation _ -> true

type mention = { start : int; stop : int; query : string }

type t =
  { page : page
  ; view : J.t
  ; drafts : (string * string) list
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
  | Open of page | Back | Refresh | Older | Receive of J.t
  | Draft of string | Pick_agent | Select_agent of string | Dismiss_mentions
  | Send | Name of string | Repository of string | Graph_target of string | Default_agent of string
  | Save_bot of string option | Edit_automation of J.t | Rule_field of string * J.t
  | Save_automation | Toggle_automation of string * bool

let empty = {page = Index; view = `Null; drafts = []; active_mention = None; focus_request = false;
  name = ""; repository = ""; graph_target = ""; default_agent = "devin"; proposal = `Null;
  thread_origin = None}

let bot_path id = "/bots/" ^ id
let route = function
  | Index | Create -> "/bots"
  | Main id | Sessions (id, _) | Settings id | Automation id -> bot_path id
  | Thread (id, thread) -> bot_path id ^ "/sessions/" ^ thread

let request ?before ?after ?path ?(method_ = "GET") ?(body = `Null) state =
  let route = route state.page in
  let fields = ["route", `String route; "path", `String (Option.value ~default:route path);
    "method", `String method_; "body", body] in
  let cursor key = function None -> [] | Some value -> [key, `String (Int64.to_string value)] in
  Some (J.to_string (`Assoc (fields @ cursor "before" before @ cursor "after" after)))

let draft state = Option.value ~default:"" (List.assoc_opt (route state.page) state.drafts)
let set_draft text state =
  let key = route state.page in
  {state with drafts = (key, text) :: List.remove_assoc key state.drafts}

let labels = ["devin", "Devin"; "circle", "Circle"; "codex", "Codex"; "pi", "Pi"]
let label agent = Option.value ~default:agent (List.assoc_opt agent labels)
let selected_bot state = Data.field "bot" state.view
let session state = Data.field "session" state.view

let agent_character = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
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

let mentions state =
  let text = draft state in
  let rec scan from =
    match String.index_from_opt text from '@' with
    | None -> None, String.trim text
    | Some start ->
      let stop = mention_stop text start in
      let agent = String.lowercase_ascii (String.sub text (start + 1) (stop - start - 1)) in
      if mention_boundary text start && List.mem_assoc agent labels then
        let before = String.sub text 0 start and after = String.sub text stop (String.length text - stop) in
        let before = if after <> "" && space after.[0] && before <> ""
          && space before.[String.length before - 1] then String.sub before 0 (String.length before - 1)
          else before in
        Some agent, String.trim (before ^ after)
      else scan stop in
  scan 0

let messages state = Data.list "messages" state.view @ Data.list "pending" state.view
let seq message = match Data.field "seq" message with
  | `String raw -> Int64.of_string_opt raw | `Int n -> Some (Int64.of_int n) | _ -> None

let merge_messages fresh prior =
  let seen = Hashtbl.create (List.length fresh + List.length prior) in
  List.iter (fun message -> Hashtbl.replace seen (Data.string "id" message) message) prior;
  List.iter (fun message -> Hashtbl.replace seen (Data.string "id" message) message) fresh;
  Hashtbl.to_seq_values seen |> List.of_seq |> List.sort (fun a b -> compare (seq a) (seq b))

let receive state json =
  if Data.string "route" json <> route state.page then state
  else
    let current = state.view in
    let fields = match json with `Assoc fields -> fields | _ -> [] in
    let prior = Data.list "messages" current in
    let older = Data.field "older" json = `Bool true in
    let old_more = Data.field "more" current in
    let more = if older || prior = [] then Data.field "more" json else old_more in
    let merged = match Data.list "messages" json with
      | [] -> prior
      | fresh -> merge_messages fresh prior in
    let previous = match current with `Assoc fields -> fields | _ -> [] in
    let keep = List.filter (fun (key, _) -> not (List.mem_assoc key fields)) previous in
    {state with view = `Assoc (["messages", `List merged; "more", more]
      @ List.remove_assoc "messages" (List.remove_assoc "more" (fields @ keep)))}

let update state action =
  let stay state = state, None in
  let open_page page =
    let same = route state.page = route page in
    let thread_origin = match page with Thread _ -> Some state.page | _ -> None in
    let updated = {state with page; view = (if same then state.view else `Null); thread_origin;
      active_mention = None; focus_request = false} in
    updated, request updated in
  match action with
  | Open Create -> stay {state with page = Create; name = ""; repository = "";
      graph_target = ""; default_agent = "devin"; active_mention = None; focus_request = false}
  | Open (Settings _ as page) ->
    let bot = selected_bot state in
    stay {state with page; default_agent = Data.string "default_agent" bot; active_mention = None; focus_request = false}
  | Open page -> open_page page
  | Back ->
    (match state.page with
    | Index | Create | Main _ -> open_page Index
    | Thread (id, _) -> open_page (Option.value ~default:(Main id) state.thread_origin)
    | Settings id | Sessions (id, _) | Automation id -> open_page (Main id))
  | Refresh ->
    (match state.page with Create | Settings _ | Automation _ -> stay state
    | _ ->
      let after = List.fold_left (fun latest row -> max latest (seq row)) None (Data.list "messages" state.view) in
      state, request ?after state)
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
        | Main _ -> mention_at value (edited_caret previous value)
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
  | Select_agent agent ->
    (match state.active_mention with
    | None -> stay state
    | Some {start; stop; _} ->
      let value = draft state in
      let before = String.sub value 0 start and after = String.sub value stop (String.length value - stop) in
      let separator = if after = "" || not (space after.[0]) then " " else "" in
      stay (set_draft (before ^ "@" ^ label agent ^ separator ^ after) {state with active_mention = None}))
  | Send ->
    let agent, body = match state.page with Main _ -> mentions state | _ -> None, String.trim (draft state) in
    if body = "" then stay state
    else
      let updated = set_draft "" {state with active_mention = None} in
      let body = `Assoc ["body", `String body;
        "agent", Option.fold ~none:`Null ~some:(fun name -> `String name) agent] in
      updated, request ~path:(route state.page ^ "/messages") ~method_:"POST" ~body state
  | Name name -> stay {state with name}
  | Repository repository -> stay {state with repository}
  | Graph_target graph_target -> stay {state with graph_target}
  | Default_agent default_agent -> stay {state with default_agent}
  | Save_bot graph ->
    (match state.page with
    | Create when String.trim state.name <> "" ->
      let graph_fields = match graph with
        | Some graph when String.trim state.graph_target <> "" ->
          ["graphId", `String graph; "graphBlockId", `String (String.trim state.graph_target)]
        | _ -> [] in
      let body = `Assoc (["name", `String state.name; "repository", `String state.repository;
        "defaultAgent", `String state.default_agent] @ graph_fields) in
      let index = {state with page = Index} in
      index, request ~method_:"POST" ~body index
    | Settings id ->
      let main = {state with page = Main id} in
      main, request ~method_:"PATCH" ~body:(`Assoc ["defaultAgent", `String state.default_agent]) main
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
    | Automation id ->
      let main = {state with page = Main id} in
      main, request ~path:(bot_path id ^ "/automations") ~method_:"POST" ~body:state.proposal main
    | _ -> stay state)
  | Toggle_automation (id, enabled) ->
    state, request ~path:(route state.page ^ "/automations/" ^ id) ~method_:"PATCH"
      ~body:(`Assoc ["enabled", `Bool enabled]) state
