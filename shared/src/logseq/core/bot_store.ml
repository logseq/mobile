module J = Yojson.Basic

let field name = function
  | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields)
  | _ -> `Null

let string name json = match field name json with `String value -> value | _ -> ""
let list name json = match field name json with `List values -> values | _ -> []
let to_json = J.to_string

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
  exec db "INSERT INTO bots VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value"
    [text scope; text (string "id" bot); text (to_json bot)]

let save_session db scope session =
  exec db "INSERT INTO sessions VALUES(?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value"
    [text scope; text (string "bot_id" session); text (string "id" session); text (to_json session)]

let save_message db scope message =
  let seq = match field "seq" message with
    | `String value -> Option.value ~default:0L (Int64.of_string_opt value)
    | `Int value -> Int64.of_int value
    | _ -> 0L in
  exec db "INSERT INTO messages VALUES(?,?,?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET value=excluded.value"
    [text scope; text (string "bot_id" message); text (string "session_id" message);
     text (string "id" message); Sqlite3.Data.INT seq; text (to_json message)]

let cache db scope view =
  let save_one name save = match field name view with
    | `Assoc _ as value -> save db scope value | _ -> () in
  Sqlite.transaction db (fun () ->
    List.iter (save_bot db scope) (list "bots" view);
    List.iter (save_session db scope) (list "sessions" view);
    List.iter (save_message db scope) (list "messages" view);
    save_one "bot" save_bot;
    save_one "session" save_session;
    save_one "root" save_message)

let first values = Option.value ~default:`Null (List.nth_opt values 0)

let pending db scope =
  query db "SELECT id,method,path,body FROM bot_outbox WHERE scope=? ORDER BY rowid LIMIT 20"
    [text scope] (fun stmt ->
      Sqlite3.column_text stmt 0, Sqlite3.column_text stmt 1,
      Sqlite3.column_text stmt 2, Sqlite3.column_text stmt 3)

let view_cached db scope route before =
  let row = json_rows db in
  let messages id thread =
    row "SELECT value FROM messages WHERE scope=? AND bot_id=? AND thread=? AND seq<? ORDER BY seq DESC LIMIT 41"
      [text scope; text id; text thread; Sqlite3.Data.INT before] in
  let window id thread =
    let rows = messages id thread in
    let rec take count = function
      | item :: rest when count > 0 -> item :: take (count - 1) rest
      | _ -> [] in
    ["messages", `List (List.rev (take 40 rows)); "more", `Bool (List.length rows > 40)] in
  match String.split_on_char '/' route with
  | [""; "bots"] ->
    `Assoc ["bots", `List (row "SELECT value FROM bots WHERE scope=? ORDER BY rowid DESC" [text scope])]
  | [""; "bots"; id] ->
    let bot = row "SELECT value FROM bots WHERE scope=? AND id=?" [text scope; text id] |> first in
    let sessions = row "SELECT value FROM sessions WHERE scope=? AND bot_id=? ORDER BY json_extract(value,'$.updated_at') DESC LIMIT 100"
      [text scope; text id] in
    `Assoc (["bot", bot; "sessions", `List sessions] @ window id "")
  | [""; "bots"; id; "sessions"; thread] ->
    let session = row "SELECT value FROM sessions WHERE scope=? AND id=? AND bot_id=?"
      [text scope; text thread; text id] |> first in
    let root = row "SELECT value FROM messages WHERE scope=? AND id=? AND bot_id=?"
      [text scope; text (string "root_message_id" session); text id] |> first in
    `Assoc (["session", session; "root", root] @ window id thread)
  | _ -> `Assoc []

let allowed path =
  (path = "/bots" || String.starts_with ~prefix:"/bots/" path)
  && not (String.split_on_char '/' path |> List.exists (fun part -> part = "." || part = ".."))
  && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '/' | '-' -> true | _ -> false) path

let run db ~(config : Api.api_config) ~send ~fresh_id command =
  let identity = Created_by.of_token config.token in
  let route = string "route" command and path = string "path" command in
  let method_ = string "method" command in
  match identity with
  | None -> Error "Sign in to open Bots"
  | Some identity when allowed route && allowed path && List.mem method_ ["GET"; "POST"; "PATCH"] ->
    let scope = config.base_url ^ "\000" ^ identity.uuid in
    Sqlite.execute db schema;
    if method_ <> "GET" then (
      let supplied = field "body" command in
      let fields = match supplied with `Assoc fields -> fields | _ -> [] in
      let id = match field "id" supplied with
        | `String id when Ref_text.is_uuid id -> id | _ -> fresh_id () in
      let data = to_json (`Assoc (("id", `String id) :: List.remove_assoc "id" fields)) in
      exec db "INSERT INTO bot_outbox VALUES(?,?,?,?,?)"
        [text scope; text id; text method_; text path; text data]);
    let call method_ path body =
      match send (Api.request config method_ path body) with
      | Error _ -> Error (false, "Waiting for connection")
      | Ok (response : Api.api_response) when response.status = 401 ->
        Error (false, "Sign in again to send pending messages")
      | Ok response when response.status >= 500 || response.status = 429 ->
        Error (false, "Bots server is temporarily unavailable")
      | Ok response ->
        (try
           let result = J.from_string response.body in
           if response.status >= 200 && response.status < 300 then Ok result
           else Error (true, match string "error" result with "" -> "Bots request rejected" | error -> error)
         with Yojson.Json_error _ ->
           Error (response.status >= 400, "Bots is unavailable on this server")) in
    let error = ref None in
    let rec flush = function
      | [] -> ()
      | (id, method_, path, body) :: rest ->
        (match call method_ path (Some body) with
        | Ok result ->
          cache db scope result;
          (match field "message" result with `Assoc _ as message -> save_message db scope message | _ -> ());
          exec db "DELETE FROM bot_outbox WHERE scope=? AND id=?" [text scope; text id];
          flush rest
        | Error (true, message) ->
          exec db "DELETE FROM bot_outbox WHERE scope=? AND id=?" [text scope; text id];
          error := Some message;
          flush rest
        | Error (false, message) -> error := Some message) in
    flush (pending db scope);
    let before = Int64.of_string_opt (string "before" command) in
    let after = Int64.of_string_opt (string "after" command) in
    let suffix = match before, after with
      | Some seq, _ -> "?before=" ^ Int64.to_string seq
      | None, Some seq -> "?after=" ^ Int64.to_string seq
      | None, None -> "" in
    let view = match call "GET" (route ^ suffix) None with
      | Ok view -> cache db scope view; view
      | Error (_, message) ->
        if !error = None then error := Some message;
        (match after with
        | Some _ -> `Assoc []
        | None -> view_cached db scope route (Option.value ~default:Int64.max_int before)) in
    let state = match view with `Assoc fields -> fields | _ -> [] in
    let drafts = pending db scope |> List.filter_map (fun (id, _, path, body) ->
      if path = route ^ "/messages" then
        Some (`Assoc ["id", `String id; "author", `String "user"; "pending", `Bool true;
          "body", field "body" (J.from_string body)])
      else None) in
    Ok (`Assoc (["route", `String route; "older", `Bool (before <> None);
      "pending", `List drafts;
      "feedback", Option.fold ~none:`Null ~some:(fun value -> `String value) !error] @ state))
  | Some _ -> Error "Invalid Bots request"
