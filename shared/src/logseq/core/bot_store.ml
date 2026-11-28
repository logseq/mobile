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
CREATE TABLE IF NOT EXISTS bot_route_config (
  scope TEXT NOT NULL, route TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(scope,route));
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

let purge_bot db scope bot =
  let args = [text scope; text bot] in
  exec db "DELETE FROM bots WHERE scope=? AND id=?" args;
  exec db "DELETE FROM sessions WHERE scope=? AND bot_id=?" args;
  exec db "DELETE FROM messages WHERE scope=? AND bot_id=?" args;
  exec db "DELETE FROM bot_route_config WHERE scope=? AND (route=? OR route LIKE ?)"
    [text scope; text ("/bots/" ^ bot); text ("/bots/" ^ bot ^ "/%")]

let cache db scope view =
  let save_one name save = match field name view with
    | `Assoc _ as value -> save db scope value | _ -> () in
  Sqlite.transaction db (fun () ->
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
  let config = match row "SELECT value FROM bot_route_config WHERE scope=? AND route=?" [text scope; text route] with
    | [`Assoc fields] -> fields | _ -> [] in
  match String.split_on_char '/' route with
  | [""; "bots"] ->
    `Assoc (("bots", `List (row "SELECT value FROM bots WHERE scope=? ORDER BY rowid DESC" [text scope])) :: config)
  | [""; "bots"; id] ->
    let bot = row "SELECT value FROM bots WHERE scope=? AND id=?" [text scope; text id] |> first in
    let sessions = row "SELECT value FROM sessions WHERE scope=? AND bot_id=? ORDER BY json_extract(value,'$.updated_at') DESC LIMIT 100"
      [text scope; text id] in
    `Assoc (["bot", bot; "sessions", `List sessions] @ config @ window id "")
  | [""; "bots"; id; "sessions"; thread] ->
    let session = row "SELECT value FROM sessions WHERE scope=? AND id=? AND bot_id=?"
      [text scope; text thread; text id] |> first in
    let root = row "SELECT value FROM messages WHERE scope=? AND id=? AND bot_id=?"
      [text scope; text (string "root_message_id" session); text id] |> first in
    `Assoc (["session", session; "root", root] @ config @ window id thread)
  | _ -> `Assoc []

let allowed path =
  (path = "/bots" || String.starts_with ~prefix:"/bots/" path)
  && not (String.split_on_char '/' path |> List.exists (fun part -> part = "." || part = ".."))
  && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '/' | '-' -> true | _ -> false) path

let run ?(upload = Http.upload_file) db ~(config : Api.api_config) ~send ~fresh_id command =
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
      exec db "INSERT INTO bot_outbox VALUES(?,?,?,?,?) ON CONFLICT(scope,id) DO NOTHING"
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
    let upload_attachments path raw =
      let latest = J.from_string raw in
      match list "attachments" latest with
      | [] -> Ok raw
      | files ->
        let ( let* ) = Result.bind in
        let bot = List.nth (String.split_on_char '/' path) 2 in
        let upload_one attachment =
          let id = string "id" attachment in
          let location = string "localPath" attachment in
          let filename = string "name" attachment in
          let file_size = try Ok (Unix.stat location).st_size with Unix.Unix_error _ ->
            Error (true, "The attachment is no longer on this device") in
          let* size = file_size in
          if not (Ref_text.is_uuid id) || size < 1 || size > 10 * 1024 * 1024
          then Error (true, "Attachments must be between 1 byte and 10 MB")
          else
            let request = Api.request config "PUT" ("/bots/" ^ bot ^ "/uploads/" ^ id) None in
            match upload {Api.request; file_path = location; content_type = "application/octet-stream"; headers = []} with
            | Ok response when response.status >= 200 && response.status < 300 ->
              Ok (`Assoc ["id", `String id; "name", `String filename])
            | Ok response when response.status = 401 || response.status = 429 || response.status >= 500 ->
              Error (false, "Waiting to upload attachments")
            | Ok _ -> Error (true, "The server rejected an attachment")
            | Error _ -> Error (false, "Waiting to upload attachments") in
        let* uploaded = List.fold_left (fun acc file ->
          let* items = acc in let* item = upload_one file in Ok (item :: items)) (Ok []) files in
        let fields = match latest with `Assoc fields -> fields | _ -> [] in
        Ok (to_json (`Assoc (("attachments", `List (List.rev uploaded)) :: List.remove_assoc "attachments" fields))) in
    let error = ref None in
    let rejected = ref [] and acknowledged = ref [] in
    let rec flush = function
      | [] -> ()
      | (id, method_, path, body) :: rest ->
        (match Result.bind (upload_attachments path body) (fun body -> call method_ path (Some body)) with
        | Ok result ->
          cache db scope result;
          (match field "message" result with
          | `Assoc _ as message ->
            save_message db scope message;
            if path = route ^ "/messages" then acknowledged := message :: !acknowledged
          | _ -> ());
          exec db "DELETE FROM bot_outbox WHERE scope=? AND id=?" [text scope; text id];
          flush rest
        | Error (true, message) ->
          if path = route ^ "/messages" then rejected := J.from_string body :: !rejected;
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
      | Ok view ->
        cache db scope view;
        (match field "agents" view with
        | `List _ ->
          let config = List.map (fun key -> key, field key view) ["agents"; "shareableGraphs"; "canManage"; "participants"] in
          exec db "INSERT INTO bot_route_config VALUES(?,?,?) ON CONFLICT(scope,route) DO UPDATE SET value=excluded.value"
            [text scope; text route; text (to_json (`Assoc config))]
        | _ -> ());
        view
      | Error (permanent, message) ->
        if !error = None then error := Some message;
        if permanent then (
          (match String.split_on_char '/' route with
          | [""; "bots"; bot] -> Sqlite.transaction db (fun () -> purge_bot db scope bot)
          | [""; "bots"; _; "sessions"; thread] ->
            let args = [text scope; text thread] in
            Sqlite.transaction db (fun () ->
              exec db "DELETE FROM sessions WHERE scope=? AND id=?" args;
              exec db "DELETE FROM messages WHERE scope=? AND thread=?" args;
              exec db "DELETE FROM bot_route_config WHERE scope=? AND route=?" [text scope; text route])
          | _ -> ());
          `Assoc ["unavailable", `Bool true])
        else (match after with
        | Some _ -> `Assoc []
        | None -> view_cached db scope route (Option.value ~default:Int64.max_int before)) in
    let state = match view with `Assoc fields -> fields | _ -> [] in
    let drafts = pending db scope |> List.filter_map (fun (id, _, path, body) ->
      if path = route ^ "/messages" then
        let request = J.from_string body in
        Some (`Assoc ["id", `String id; "author", `String "user"; "pending", `Bool true;
          "body", field "body" request; "requested_agent", field "agent" request;
          "attachments", `List (List.map (fun file -> `Assoc ["name", field "name" file])
            (list "attachments" request))])
      else None) in
    Ok (`Assoc (["route", `String route; "older", `Bool (before <> None);
      "pending", `List drafts; "rejected", `List (List.rev !rejected);
      "acknowledged", `List (List.rev !acknowledged);
      "feedback", Option.fold ~none:`Null ~some:(fun value -> `String value) !error] @ state))
  | Some _ -> Error "Invalid Bots request"
