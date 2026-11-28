module J = Yojson.Basic

let field name = function
  | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields)
  | _ -> `Null

let string name json = match field name json with `String value -> value | _ -> ""
let list name json = match field name json with `List values -> values | _ -> []
let to_json = J.to_string

let seq name json = match field name json with
  | `String value -> Int64.of_string_opt value
  | `Int n -> Some (Int64.of_int n)
  | _ -> None

let seq_json seq = `String (Int64.to_string seq)

let object_fields = function `Assoc fields -> fields | _ -> []

let schema = {|
CREATE TABLE IF NOT EXISTS bots (
  scope TEXT NOT NULL, id TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(scope,id));
CREATE TABLE IF NOT EXISTS sessions (
  scope TEXT NOT NULL, bot_id TEXT NOT NULL, id TEXT NOT NULL, value TEXT NOT NULL,
  PRIMARY KEY(scope,id));
CREATE INDEX IF NOT EXISTS bot_session_list ON sessions(scope,bot_id);
CREATE TABLE IF NOT EXISTS messages (
  scope TEXT NOT NULL, bot_id TEXT NOT NULL, thread TEXT NOT NULL, id TEXT NOT NULL,
  seq INTEGER NOT NULL, value TEXT NOT NULL, PRIMARY KEY(scope,id));
CREATE INDEX IF NOT EXISTS bot_message_window ON messages(scope,bot_id,thread,seq);
CREATE TABLE IF NOT EXISTS bot_route_config (
  scope TEXT NOT NULL, route TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(scope,route));
CREATE TABLE IF NOT EXISTS bot_message_sync (
  scope TEXT NOT NULL, route TEXT NOT NULL, oldest INTEGER, latest INTEGER NOT NULL,
  more INTEGER NOT NULL, PRIMARY KEY(scope,route));
CREATE TABLE IF NOT EXISTS bot_outbox (
  scope TEXT NOT NULL, id TEXT NOT NULL, method TEXT NOT NULL, path TEXT NOT NULL,
  body TEXT NOT NULL, PRIMARY KEY(scope,id));
|}

let query db sql args collect =
  Sqlite.with_statement db sql (fun stmt ->
    List.iteri (fun index data ->
      Sqlite.check_result db "bind bot data" (Sqlite3.bind stmt (index + 1) data)) args;
    let rec rows acc =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> rows (collect stmt :: acc)
      | Sqlite3.Rc.DONE -> List.rev acc
      | code -> Sqlite.check_result db "read bot data" code; assert false in
    rows [])

let text value = Sqlite3.Data.TEXT value
let exec db sql args = ignore (query db sql args (fun _ -> ()))
let json_rows db sql args =
  query db sql args (fun stmt -> J.from_string (Sqlite3.column_text stmt 0))

let save_bot db scope bot =
  exec db {|INSERT INTO bots VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=
    CASE WHEN json_type(excluded.value,'$.preview') IS NULL AND json_type(bots.value,'$.preview') IS NOT NULL
    THEN json_set(excluded.value,'$.preview',json_extract(bots.value,'$.preview')) ELSE excluded.value END|}
    [text scope; text (string "id" bot); text (to_json bot)]

let save_session db scope session =
  exec db "INSERT INTO sessions VALUES(?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value WHERE sessions.value<>excluded.value"
    [text scope; text (string "bot_id" session); text (string "id" session); text (to_json session)]

let save_message db scope message =
  Option.iter (fun seq ->
    exec db "INSERT INTO messages VALUES(?,?,?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value"
      [text scope; text (string "bot_id" message); text (string "session_id" message);
       text (string "id" message); Sqlite3.Data.INT seq; text (to_json message)]) (seq "seq" message)

let purge_bot db scope bot =
  let args = [text scope; text bot] in
  exec db "DELETE FROM bots WHERE scope=? AND id=?" args;
  exec db "DELETE FROM sessions WHERE scope=? AND bot_id=?" args;
  exec db "DELETE FROM messages WHERE scope=? AND bot_id=?" args;
  let routes = [text scope; text ("/bots/" ^ bot); text ("/bots/" ^ bot ^ "/%")] in
  exec db "DELETE FROM bot_route_config WHERE scope=? AND (route=? OR route LIKE ?)" routes;
  exec db "DELETE FROM bot_message_sync WHERE scope=? AND (route=? OR route LIKE ?)" routes

let store_rows db scope view =
  let save_one name save = match field name view with
    | `Assoc _ as value -> save db scope value | _ -> () in
  (match field "bots" view with
    | `List bots ->
      let visible = Hashtbl.create (List.length bots) in
      List.iter (fun bot -> Hashtbl.replace visible (string "id" bot) (); save_bot db scope bot) bots;
      query db "SELECT id FROM bots WHERE scope=?" [text scope] (fun stmt -> Sqlite3.column_text stmt 0)
      |> List.iter (fun id -> if not (Hashtbl.mem visible id) then purge_bot db scope id)
    | _ -> ());
  List.iter (save_session db scope) (list "sessions" view);
  List.iter (save_message db scope) (list "messages" view);
  save_one "bot" save_bot;
  save_one "session" save_session;
  save_one "root" save_message;
  save_one "message" save_message

let first values = Option.value ~default:`Null (List.nth_opt values 0)

let pending db scope =
  query db "SELECT id,method,path,body FROM bot_outbox WHERE scope=? ORDER BY rowid LIMIT 20"
    [text scope] (fun stmt ->
      Sqlite3.column_text stmt 0, Sqlite3.column_text stmt 1,
      Sqlite3.column_text stmt 2, Sqlite3.column_text stmt 3)

type sync = Account | Changed of string * string option | History of string * int64

type route = Index | Main of string | Thread of string * string

let parse_route path =
  match String.split_on_char '/' path with
  | [""; "bots"] -> Some Index
  | [""; "bots"; bot] when Ref_text.is_uuid bot -> Some (Main bot)
  | [""; "bots"; bot; "sessions"; id] when Ref_text.is_uuid bot && Ref_text.is_uuid id ->
    Some (Thread (bot, id))
  | _ -> None

let bot_path bot = "/bots/" ^ bot
let thread_path bot thread = bot_path bot ^ "/sessions/" ^ thread

let scope ?account (config : Api.api_config) =
  let account = match Created_by.of_token config.token with
    | Some identity -> Some identity.uuid
    | None -> account in
  Option.map (fun id -> config.base_url ^ "\000" ^ id) account

type coverage = { oldest : int64 option; latest : int64; more : bool }

let coverage db scope route =
  query db "SELECT oldest,latest,more FROM bot_message_sync WHERE scope=? AND route=?"
    [text scope; text route] (fun stmt ->
      let oldest = match Sqlite3.column stmt 0 with Sqlite3.Data.INT seq -> Some seq | _ -> None in
      {oldest; latest = Sqlite3.column_int64 stmt 1; more = Sqlite3.column_bool stmt 2})
  |> fun rows -> List.nth_opt rows 0

let save_coverage db scope route {oldest; latest; more} =
  let oldest = Option.fold ~none:Sqlite3.Data.NULL ~some:(fun n -> Sqlite3.Data.INT n) oldest in
  exec db "INSERT OR REPLACE INTO bot_message_sync VALUES(?,?,?,?,?)"
    [text scope; text route; oldest; Sqlite3.Data.INT latest; Sqlite3.Data.INT (if more then 1L else 0L)]

let route_config db scope route =
  json_rows db "SELECT value FROM bot_route_config WHERE scope=? AND route=?"
    [text scope; text route] |> first |> object_fields

let save_config db scope route fields =
  exec db "INSERT INTO bot_route_config VALUES(?,?,?) ON CONFLICT(scope,route) DO UPDATE SET value=excluded.value WHERE bot_route_config.value<>excluded.value"
    [text scope; text route; text (to_json (`Assoc fields))]

let sessions db scope bot =
  json_rows db "SELECT value FROM sessions WHERE scope=? AND bot_id=? ORDER BY json_extract(value,'$.updated_at') DESC,id LIMIT 100"
    [text scope; text bot]

let changed_threads db scope bot =
  (* Compare the latest summary with the summary saved alongside each thread.
     If a thread request was interrupted, the older snapshot still triggers a retry. *)
  query db {|
    WITH recent AS (
      SELECT id, value FROM sessions WHERE scope=? AND bot_id=?
      ORDER BY json_extract(value,'$.updated_at') DESC,id LIMIT 100
    )
    SELECT ? || recent.id FROM recent
    LEFT JOIN bot_route_config ON bot_route_config.scope=?
      AND bot_route_config.route=? || recent.id
    WHERE json_extract(bot_route_config.value,'$.sessionSnapshot') IS NOT json(recent.value)
    ORDER BY json_extract(recent.value,'$.updated_at') DESC,recent.id|}
    [text scope; text bot; text (bot_path bot ^ "/sessions/"); text scope;
     text (bot_path bot ^ "/sessions/")] (fun stmt -> Sqlite3.column_text stmt 0)

let pending_bots db scope =
  json_rows db "SELECT body FROM bot_outbox WHERE scope=? AND path='/bots' ORDER BY rowid DESC" [text scope]
  |> List.map (fun request ->
    `Assoc ["id", field "id" request; "name", field "name" request;
      "default_agent", field "defaultAgent" request; "graph_id", field "graphId" request;
      "shared_graph_id", field "sharedGraphId" request])

let cached_bots db scope =
  json_rows db "SELECT value FROM bots WHERE scope=? ORDER BY rowid DESC" [text scope]

let ordered_bots db scope metadata =
  let bots = cached_bots db scope in
  let ids = list "botOrder" (`Assoc metadata) in
  let by_id = Hashtbl.create (List.length bots) in
  List.iter (fun bot -> Hashtbl.replace by_id (string "id" bot) bot) bots;
  let ordered = List.filter_map (function
    | `String id -> let bot = Hashtbl.find_opt by_id id in Hashtbl.remove by_id id; bot
    | _ -> None) ids in
  pending_bots db scope @ List.filter (fun bot -> Hashtbl.mem by_id (string "id" bot)) bots @ ordered

let queued_messages db scope route metadata =
  json_rows db "SELECT body FROM bot_outbox WHERE scope=? AND path=? ORDER BY rowid"
    [text scope; text (route ^ "/messages")]
  |> List.map (fun request ->
    let target_id = string "targetBotId" request in
    let target = list "mentionableBots" (`Assoc metadata)
      |> List.find_opt (fun bot -> string "id" bot = target_id) in
    let handoff = Option.fold ~none:`Null
      ~some:(fun bot -> `Assoc ["target_name", field "name" bot]) target in
    `Assoc ["id", field "id" request; "author", `String "user"; "pending", `Bool true;
      "body", field "body" request; "handoff", handoff; "requested_agent", field "agent" request;
      "requested_agents", field "agents" request;
      "attachments", `List (List.map (fun file -> `Assoc ["name", field "name" file])
        (list "attachments" request))])

let read db scope route destination before ~allow_history =
  let row = json_rows db in
  let metadata = route_config db scope route in
  let window bot thread =
    let saved = coverage db scope route in
    let floor = Option.fold ~none:None ~some:(fun saved -> saved.oldest) saved in
    let rows = row
      "SELECT value FROM messages WHERE scope=? AND bot_id=? AND thread=? AND seq>=? AND seq<? ORDER BY seq DESC LIMIT 41"
      [text scope; text bot; text thread; Sqlite3.Data.INT (Option.value ~default:0L floor);
       Sqlite3.Data.INT (Option.value ~default:Int64.max_int before)] in
    let more_remote = Option.fold ~none:true ~some:(fun saved -> saved.more) saved in
    let history = match before, rows with
      | Some cursor, [] when allow_history && more_remote -> ["fetchOlder", seq_json cursor]
      | _ -> [] in
    let more = List.length rows > 40 || (more_remote && (saved <> None || rows <> [] || before <> None)) in
    ["messages", `List (rows |> List.take 40 |> List.rev); "more", `Bool more;
      "pending", `List (queued_messages db scope route metadata)] @ history in
  let find_bot id =
    match row "SELECT value FROM bots WHERE scope=? AND id=?" [text scope; text id] with
    | [] -> pending_bots db scope |> List.find_opt (fun bot -> string "id" bot = id)
      |> Option.value ~default:`Null
    | bot :: _ ->
      let edits = json_rows db "SELECT body FROM bot_outbox WHERE scope=? AND path=? AND method='PATCH' ORDER BY rowid"
        [text scope; text (bot_path id)] in
      let apply fields edit =
        List.fold_left (fun fields (wire, key) ->
          match List.assoc_opt wire (object_fields edit) with
          | None -> fields
          | Some value -> (key, value) :: List.remove_assoc key fields)
          fields ["defaultAgent", "default_agent"; "sharedGraphId", "shared_graph_id"] in
      `Assoc (List.fold_left apply (object_fields bot) edits) in
  let state =
    match destination with
    | Index -> ["bots", `List (ordered_bots db scope metadata)]
    | Main bot ->
      let bot_row = find_bot bot in
      ["bot", bot_row; "sessions", `List (sessions db scope bot)] @ window bot ""
    | Thread (bot, thread) ->
      let session = row "SELECT value FROM sessions WHERE scope=? AND id=? AND bot_id=?"
        [text scope; text thread; text bot] |> first in
      let root = row "SELECT value FROM messages WHERE scope=? AND id=? AND bot_id=?"
        [text scope; text (string "root_message_id" session); text bot] |> first in
      ["session", session; "root", root; "bot", find_bot bot] @ window bot thread in
  let unavailable = match destination with
    | Index -> false
    | Main _ -> List.assoc_opt "bot" state = Some `Null
    | Thread _ -> List.assoc_opt "session" state = Some `Null in
  `Assoc (["route", `String route; "older", `Bool (before <> None); "unavailable", `Bool unavailable]
    @ state @ List.filter (fun (key, _) -> not (List.mem key ["botOrder"; "sessionSnapshot"; "unavailable"])) metadata)

let valid_write destination method_ path =
  match destination, method_ with
  | Index, "POST" -> path = "/bots"
  | Main bot, "POST" -> path = bot_path bot ^ "/messages" || path = bot_path bot ^ "/automations"
  | Main bot, "PATCH" ->
    path = bot_path bot ||
    (match String.split_on_char '/' path with
     | [""; "bots"; id; "automations"; rule] -> id = bot && Ref_text.is_uuid rule
     | _ -> false)
  | Thread (bot, thread), "POST" -> path = thread_path bot thread ^ "/messages"
  | _ -> false

let run ?account db ~config ~fresh_id command =
  let route = string "route" command and path = string "path" command in
  let method_ = string "method" command in
  match scope ?account config, parse_route route with
  | None, _ -> Error "Sign in to open Bots"
  | Some scope, Some destination when method_ = "GET" || valid_write destination method_ path ->
    Sqlite.execute db schema;
    if method_ <> "GET" then (
      let supplied = field "body" command in
      let id = match field "id" supplied with
        | `String id when Ref_text.is_uuid id -> id | _ -> fresh_id () in
      let data = to_json (`Assoc (("id", `String id) :: List.remove_assoc "id" (object_fields supplied))) in
      exec db "INSERT INTO bot_outbox VALUES(?,?,?,?,?) ON CONFLICT(scope,id) DO NOTHING"
        [text scope; text id; text method_; text path; text data]);
    Ok (read db scope route destination (seq "before" command)
      ~allow_history:(field "historyFetched" command <> `Bool true))
  | _ -> Error "Invalid Bots request"

type 'a step =
  | Done of 'a
  | Send of Api.api_request * string option * (Api.api_response option -> 'a step)

type pull_result = Updated | Removed | Unavailable

let rec bind step next =
  match step with
  | Done result -> next result
  | Send (request, file, resume) -> Send (request, file, fun response -> bind (resume response) next)

let ( let* ) = bind

let response = function
  | None | Some {Api.status = (401 | 429 | 0); _} -> Error (false, "Waiting for connection")
  | Some {Api.status; _} when status >= 500 -> Error (false, "Bots server is temporarily unavailable")
  | Some {Api.status; body} ->
    let json = try J.from_string body with Yojson.Json_error _ -> `Null in
    if status >= 200 && status < 300 then
      (match json with `Assoc _ -> Ok json | _ -> Error (false, "Invalid Bots response"))
    else Error (true, match string "error" json with "" -> "Bots request rejected" | error -> error)

let sync db ~(config : Api.api_config) scope reason ~changed =
  Sqlite.execute db schema;
  let fetch method_ path body file next = Send (Api.request config method_ path body, file, next) in
  let reports = ref [] and flushed_outbox = ref false in
  let report route feedback rejected =
    reports := `Assoc ["route", `String route; "feedback", `String feedback;
      "rejected", `List rejected] :: !reports in
  let route_for_write path =
    match String.split_on_char '/' path with
    | [""; "bots"; bot; "sessions"; thread; "messages"] -> thread_path bot thread
    | "" :: "bots" :: bot :: _ -> bot_path bot
    | _ -> "/bots" in
  let dirty = Hashtbl.create 4 and settled = Hashtbl.create 4 in
  let forget id =
    exec db "DELETE FROM bot_outbox WHERE scope=? AND id=?" [text scope; text id] in
  let rec upload bot uploaded files next =
    match files with
    | [] -> next (Ok (List.rev uploaded))
    | file :: rest ->
      let id = string "id" file and path = string "localPath" file in
      let size = try (Unix.stat path).st_size with Unix.Unix_error _ -> 0 in
      if not (Ref_text.is_uuid id) || size < 1 || size > 10 * 1024 * 1024 then
        next (Error (true, "Attachments must exist and be between 1 byte and 10 MB"))
      else
        fetch "PUT" (bot_path bot ^ "/uploads/" ^ id) None (Some path) (function
          | Some {Api.status; _} when status >= 200 && status < 300 ->
            upload bot (`Assoc ["id", `String id; "name", field "name" file] :: uploaded) rest next
          | reply ->
            let permanent = match response reply with Error (permanent, _) -> permanent | Ok _ -> false in
            next (Error (permanent, if permanent then "The server rejected an attachment"
              else "Waiting to upload attachments"))) in
  let rec flush = function
    | [] -> Done true
    | (id, method_, path, raw) :: rest ->
      let route = route_for_write path in
      let request = J.from_string raw in
      let settle = function
        | Ok result ->
          Sqlite.transaction db (fun () -> store_rows db scope result; forget id);
          Hashtbl.replace settled route ();
          (match parse_route route with
           | Some (Main bot | Thread (bot, _)) -> Hashtbl.replace dirty bot ()
           | _ ->
             let bot = string "id" (field "bot" result) in
             if Ref_text.is_uuid bot then Hashtbl.replace dirty bot ());
          let target = string "targetBotId" request in
          if Ref_text.is_uuid target then Hashtbl.replace dirty target ();
          flush rest
        | Error (permanent, message) ->
          let rejected = if permanent && path = route ^ "/messages" then [request] else [] in
          report route message rejected;
          if permanent then (forget id; flush rest) else Done false in
      let send body = fetch method_ path (Some body) None (fun reply -> settle (response reply)) in
      (match list "attachments" request with
       | [] -> send raw
       | files ->
         let bot = match parse_route route with Some (Main bot | Thread (bot, _)) -> bot | _ -> "" in
         upload bot [] files (function
           | Error error -> settle (Error error)
           | Ok files -> send (to_json (`Assoc (("attachments", `List files)
               :: List.remove_assoc "attachments" (object_fields request)))))) in
  let cache route view update =
    Sqlite.transaction db (fun () ->
      store_rows db scope view;
      (* Bot detail has no activity preview. Keep the value from the index. *)
      let keys = ["agents"; "graphIds"; "shareableGraphs"; "canManage"; "participants";
        "mentionableBots"; "automations"] in
      let fields = List.filter (fun (key, _) -> List.mem key keys) (object_fields view) in
      let fields = match field "bots" view with
        | `List bots -> ("botOrder", `List (List.map (field "id") bots)) :: fields
        | _ -> match field "session" view with
          | `Assoc _ as session -> ("sessionSnapshot", session) :: fields
          | _ -> fields in
      save_config db scope route fields;
      update ());
    changed route in
  let remove route =
    Sqlite.transaction db (fun () ->
      (match parse_route route with
       | Some (Main bot) -> purge_bot db scope bot
       | Some (Thread (_, thread)) ->
         let args = [text scope; text thread] in
         exec db "DELETE FROM sessions WHERE scope=? AND id=?" args;
         exec db "DELETE FROM messages WHERE scope=? AND thread=?" args;
         exec db "DELETE FROM bot_message_sync WHERE scope=? AND route=?" [text scope; text route]
       | _ -> ());
      exec db "DELETE FROM bot_route_config WHERE scope=? AND route=?" [text scope; text route]);
    changed route in
  let rec download route direction =
    let suffix = match direction with
      | `Latest -> ""
      | `After saved -> "?after=" ^ Int64.to_string saved.latest
      | `Before cursor -> "?before=" ^ Int64.to_string cursor in
    fetch "GET" (route ^ suffix) None None (fun reply ->
      match response reply with
      | Ok (`Assoc fields as view) when (match List.assoc_opt "messages" fields with Some (`List _) -> true | _ -> false) ->
        let messages = list "messages" view in
        let oldest = List.find_map (seq "seq") messages in
        let latest = List.find_map (seq "seq") (List.rev messages) in
        let more = field "more" view = `Bool true in
        let saved = match direction with
          | `Latest -> {oldest; latest = Option.value ~default:0L latest; more}
          | `After saved -> {saved with
              oldest = (if saved.more then saved.oldest else None);
              latest = Option.value ~default:saved.latest latest}
          | `Before _ ->
            let saved = Option.value ~default:{oldest = None; latest = 0L; more} (coverage db scope route) in
            {oldest = (if more then oldest else None);
             latest = max saved.latest (Option.value ~default:0L latest); more} in
        cache route view (fun () -> save_coverage db scope route saved);
        (match direction with
         | `After previous when more && saved.latest > previous.latest -> download route (`After saved)
         | _ -> Done Updated)
      | _ ->
        (match reply with
         | Some {Api.status = (403 | 404); _} -> remove route; Done Removed
         | _ -> Done Unavailable)) in
  let refresh route =
    let direction = match coverage db scope route with None -> `Latest | Some saved -> `After saved in
    download route direction in
  let rec refresh_threads = function
    | [] -> Done ()
    | route :: rest ->
      let* result = refresh route in
      match result with Unavailable -> Done () | Updated | Removed -> refresh_threads rest in
  let refresh_bots bots =
    let rec summaries threads = function
      | [] -> refresh_threads (List.rev threads)
      | (bot, forced) :: rest ->
        let* result = refresh (bot_path bot) in
        match result with
        | Unavailable -> Done ()
        | Removed -> summaries threads rest
        | Updated ->
          let routes = changed_threads db scope bot in
          let routes = match forced with
            | Some id ->
              let route = thread_path bot id in
              route :: List.filter ((<>) route) routes
            | None -> routes in
          summaries (List.rev_append routes threads) rest in
    summaries [] bots in
  let work =
    match reason with
    | History (route, cursor) ->
      let* _ = download route (`Before cursor) in
      Done ()
    | Account | Changed _ ->
      let* flushed = flush (pending db scope) in
      flushed_outbox := flushed;
      if not flushed then Done () else
      fetch "GET" "/bots" None None (fun reply ->
        match response reply with
        | Ok (`Assoc fields as view) when (match List.assoc_opt "bots" fields with Some (`List _) -> true | _ -> false) ->
          cache "/bots" view (fun () -> ());
          let bots = list "bots" view |> List.map (string "id") in
          (match reason with
           | Account -> refresh_bots (List.map (fun id -> id, None) bots)
           | Changed (bot, thread) ->
             let other_bots = bots |> List.filter_map (fun id ->
               if id <> bot && (Hashtbl.mem dirty id || coverage db scope (bot_path id) = None)
               then Some (id, None) else None) in
             refresh_bots (if List.mem bot bots then (bot, thread) :: other_bots else other_bots)
           | History _ -> assert false)
        | _ -> Done ()) in
  let* () = work in
  let reports = Hashtbl.fold (fun route () reports ->
    `Assoc ["route", `String route; "feedback", `Null] :: reports) settled (List.rev !reports) in
  Done (`Assoc ["reports", `List reports;
    "morePending", `Bool (!flushed_outbox && pending db scope <> [])])
