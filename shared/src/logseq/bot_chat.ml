module J = Yojson.Basic
module Data = Bot_store

type page = Index | Create | Main of string | Sessions of string * bool | Thread of string * string
  | Settings of string | Automation of string

let is_bot_page = function
  | Index | Create -> false
  | Main _ | Sessions _ | Thread _ | Settings _ | Automation _ -> true

type t =
  { page : page
  ; view : J.t
  ; drafts : (string * string) list
  ; agent : string option
  ; show_agents : bool
  ; name : string
  ; repository : string
  ; graph_target : string
  ; default_agent : string
  ; proposal : J.t
  ; thread_origin : page option
  }

type action =
  | Open of page | Back | Refresh | Older | Receive of J.t
  | Draft of string | Pick_agent | Select_agent of string | Stop_picking
  | Send | Name of string | Repository of string | Graph_target of string | Default_agent of string
  | Save_bot of string option | Edit_automation of J.t | Rule_field of string * J.t
  | Save_automation | Toggle_automation of string * bool

let empty = {page = Index; view = `Null; drafts = []; agent = None; show_agents = false;
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

let pasted_mention input =
  let input = String.trim input in
  match String.index_opt input ' ' with
  | Some stop when stop > 1 && input.[0] = '@' ->
    let agent = String.lowercase_ascii (String.sub input 1 (stop - 1)) in
    if List.mem_assoc agent labels then Some (agent, String.trim (String.sub input stop (String.length input - stop)))
    else None
  | _ -> None

let mentions state =
  match state.agent with
  | Some selected -> Some selected, String.trim (draft state)
  | None ->
    match pasted_mention (draft state) with Some (agent, body) -> Some agent, body
      | None -> None, String.trim (draft state)

let has_mention_start value =
  match String.split_on_char ' ' value |> List.rev with
  | ("@" as query) :: _ -> query = "@"
  | query :: _ when String.starts_with ~prefix:"@" query ->
    let query = String.lowercase_ascii (String.sub query 1 (String.length query - 1)) in
    List.exists (fun (agent, _) -> String.starts_with ~prefix:query agent) labels
  | _ -> false

let remove_mention value =
  if not (has_mention_start value) then value
  else match String.rindex_opt value ' ' with
  | None -> ""
  | Some index -> String.sub value 0 index

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
      agent = None; show_agents = false} in
    updated, request updated in
  match action with
  | Open Create -> stay {state with page = Create; name = ""; repository = "";
      graph_target = ""; default_agent = "devin"; show_agents = false}
  | Open (Settings _ as page) ->
    let bot = selected_bot state in
    stay {state with page; default_agent = Data.string "default_agent" bot; show_agents = false}
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
    let show_agents = (match state.page with Main _ -> has_mention_start value | _ -> false) in
    stay (set_draft value {state with show_agents})
  | Pick_agent -> stay {state with show_agents = not state.show_agents}
  | Stop_picking -> stay {state with show_agents = false; agent = None}
  | Select_agent agent ->
    stay (set_draft (remove_mention (draft state)) {state with agent = Some agent; show_agents = false})
  | Send ->
    let agent, body = match state.page with Main _ -> mentions state | _ -> None, String.trim (draft state) in
    if body = "" then stay state
    else
      let updated = set_draft "" {state with agent = None; show_agents = false} in
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
