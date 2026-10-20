module Json = Yojson.Basic

type phase = Idle | Connecting | Open | Waiting | Offline | Stopped
type command =
  | Connect of string
  | Send of string
  | Close
  | Retry of int
  | Snapshot
  | Sync_pending

type t =
  { generation : int
  ; graph_id : string
  ; phase : phase
  ; pull_in_flight : bool
  ; notified_t : int
  ; applied_t : int
  ; response_t : int option
  ; attempt : int
  ; snapshot_required : bool
  ; commands : command list
  ; error : string option
  }

type event =
  | Opened
  | Frame of string
  | Failed of string
  | Closed
  | Cancelled
  | Snapshot_applied
  | Network of bool

let empty =
  { generation = 0; graph_id = ""; phase = Idle; pull_in_flight = false;
    notified_t = -1; applied_t = -1; response_t = None; attempt = 0;
    snapshot_required = false; commands = []; error = None }

let generation state = state.generation
let graph_id state = state.graph_id
let connected state = state.phase = Open
let without_commands state = { state with commands = [] }
let invalidate state =
  { empty with generation = state.generation + 1; phase = Stopped }

let pull cursor =
  Send (Json.to_string (`Assoc ["type", `String "pull"; "since", `Int cursor]))

let reconnect_delay attempt =
  match attempt with
  | 0 -> 1000 | 1 -> 2000 | 2 -> 4000 | 3 -> 8000 | 4 -> 16000 | _ -> 30000

let fail message state =
  { state with phase = Waiting; pull_in_flight = false;
    attempt = min 5 (state.attempt + 1);
    commands = [Close; Retry (reconnect_delay state.attempt)]; error = Some message }

let require_snapshot ~editing state =
  { state with phase = Waiting; snapshot_required = true; pull_in_flight = false;
    commands = [Close; (if editing then Retry 1000 else Snapshot)] }

let socket_url config =
  let root = Api.api_root config in
  let replace before after =
    if String.starts_with ~prefix:before root then
      Some (after ^ String.sub root (String.length before) (String.length root - String.length before))
    else None in
  let root =
    if String.starts_with ~prefix:"ws://" root || String.starts_with ~prefix:"wss://" root then Some root
    else match replace "https://" "wss://" with Some _ as root -> root | None -> replace "http://" "ws://" in
  Option.map (fun root -> root ^ "/sync/" ^ Api.url_encode config.Api.graph_id) root

let begin_connection config ~cursor ~editing previous =
  let state = if previous.graph_id = config.Api.graph_id then previous
    else { empty with generation = previous.generation } in
  let state = { state with generation = state.generation + 1;
    graph_id = config.graph_id; commands = []; response_t = None } in
  match socket_url config with
  | None -> Error "Unsupported sync base URL"
  | Some url ->
    if state.snapshot_required || cursor = None then
      Ok { state with phase = Waiting; snapshot_required = true;
        commands = [if editing then Retry 1000 else Snapshot] }
    else
      let cursor = Option.get cursor in
      Ok { state with phase = Connecting; pull_in_flight = false;
        notified_t = cursor; applied_t = cursor;
        commands = (if connected previous then [Close; Connect url] else [Connect url]) }

let snapshot_error message =
  message = "sync schema mismatch"
  || String.starts_with ~prefix:"snapshot required:" message

let int_field name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some (`Int value) when value >= 0 -> Some value | _ -> None)
  | _ -> None

let string_field name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some (`String value) -> Some value | _ -> None)
  | _ -> None

let receive_frame ~cursor ~editing ~apply_frame body state =
  try
    let frame = Json.from_string body in
    match string_field "type" frame with
    | Some ("hello" | "changed") ->
      let notified_t = max state.notified_t (Option.value ~default:state.notified_t (int_field "t" frame)) in
      let state = { state with notified_t } in
      (match cursor with
       | Some cursor when not state.pull_in_flight && notified_t > cursor ->
         { state with pull_in_flight = true; commands = [pull cursor] }
       | _ -> state)
    | Some "pull/ok" ->
      if not state.pull_in_flight
         || (match state.response_t, int_field "t" frame with Some previous, Some incoming -> incoming <= previous | _ -> false)
      then state
      else
        let scoped = match frame with
          | `Assoc fields -> `Assoc (("graphId", `String state.graph_id) :: List.remove_assoc "graphId" fields)
          | _ -> assert false in
        (match apply_frame (Json.to_string scoped) with
         | Error message when snapshot_error message ->
           { (require_snapshot ~editing state) with error = Some message }
         | Error message -> fail message state
         | Ok None -> require_snapshot ~editing state
         | Ok (Some cursor) ->
           let pending = state.notified_t > cursor in
           { state with pull_in_flight = pending; response_t = int_field "t" frame;
             applied_t = cursor; attempt = (if cursor > state.applied_t then 0 else state.attempt);
             commands = (if pending then [Sync_pending; pull cursor] else [Sync_pending]); error = None })
    | Some "reset" -> require_snapshot ~editing state
    | Some "error" ->
      let message = Option.value ~default:"Sync server returned an error" (string_field "message" frame) in
      if string_field "code" frame = Some "snapshot_required" || snapshot_error message
      then require_snapshot ~editing state else fail message state
    | Some _ -> state
    | None -> fail "Sync frame requires a type" state
  with Yojson.Json_error message -> fail ("Invalid sync frame: " ^ message) state

let receive ~cursor ~editing ~apply_frame event previous =
  let state = without_commands previous in
  match event with
  | Cancelled -> { state with phase = Stopped; pull_in_flight = false; commands = [Close] }
  | Snapshot_applied when state.snapshot_required ->
    { state with phase = Idle; snapshot_required = false; attempt = 0; error = None }
  | Network false when state.phase <> Stopped ->
    { state with phase = Offline; pull_in_flight = false; commands = [Close] }
  | Network true when state.phase = Offline ->
    { state with phase = Waiting; commands = [Retry 0] }
  | Opened when state.phase = Connecting ->
    (match cursor with
     | Some cursor -> { state with phase = Open; pull_in_flight = true;
         commands = [pull cursor; Sync_pending]; error = None }
     | None -> require_snapshot ~editing state)
  | Frame body when state.phase = Open -> receive_frame ~cursor ~editing ~apply_frame body state
  | Failed message when state.phase <> Stopped && state.phase <> Offline -> fail message state
  | Closed when state.phase = Open || state.phase = Connecting -> fail "WebSocket closed" state
  | _ -> state

let command_json = function
  | Connect url -> `Assoc ["type", `String "connect"; "url", `String url]
  | Send body -> `Assoc ["type", `String "send"; "body", `String body]
  | Close -> `Assoc ["type", `String "close"]
  | Retry delay -> `Assoc ["type", `String "retry"; "delayMs", `Int delay]
  | Snapshot -> `Assoc ["type", `String "snapshot"]
  | Sync_pending -> `Assoc ["type", `String "sync-pending"]

let to_yojson state =
  `Assoc ["generation", `Int state.generation; "graphId", `String state.graph_id;
    "snapshotRequired", `Bool state.snapshot_required;
    "error", (match state.error with Some message -> `String message | None -> `Null);
    "commands", `List (List.map command_json state.commands)]
