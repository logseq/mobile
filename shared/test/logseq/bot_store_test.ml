open Test_util

let bot_id = "25376367-2819-40cf-b976-f3188018c744"
let message_id = "62e2997c-b14f-4f7a-9a3a-80238f6cb675"
let route = "/bots/" ^ bot_id

let offline_send_survives_reopen () =
  let store = Filename.temp_file "logseq-bots" ".sqlite" in
  Fun.protect ~finally:(fun () -> Sys.remove store) (fun () ->
    let config : Api.api_config =
      {base_url = "http://local.example"; graph_id = ""; graph_name = None;
       token = "x.eyJzdWIiOiJiMThmNDIwMy0xNmYwLTQzYjUtYWJjMC0zZWVhYzllYzczMmMifQ.x"} in
    let run config method_ path body send =
      let db = Sqlite.open_session store in
      Fun.protect ~finally:(fun () -> Sqlite.close db) (fun () ->
        let command = `Assoc ["route", `String route; "method", `String method_;
          "path", `String path; "body", body] in
        match Bot_store.run db ~config ~send ~fresh_id:(fun () -> message_id) command with
        | Ok view -> view | Error error -> Alcotest.fail error) in
    let offline _ = Error "offline" in
    let draft = run config "POST" (route ^ "/messages")
      (`Assoc ["body", `String "Fix navigation"; "agent", `String "codex"]) offline in
    check_eq [message_id]
      (List.map (Bot_store.string "id") (Bot_store.list "pending" draft));
    let other_server = {config with base_url = "http://another.example"} in
    check_eq [] (Bot_store.list "pending" (run other_server "GET" route `Null offline));
    let delivered = ref [] in
    let stored = `Assoc ["id", `String message_id; "bot_id", `String bot_id;
      "seq", `String "12"; "body", `String "Fix navigation"] in
    let online (request : Api.api_request) =
      let body = match request.body with
        | Some json ->
          delivered := [Bot_store.string "id" (Yojson.Basic.from_string json)];
          `Assoc ["message", stored]
        | None -> `Assoc ["messages", `List [stored]; "more", `Bool false] in
      Ok (Api.response 200 (Yojson.Basic.to_string body)) in
    let synced = run config "GET" route `Null online in
    check_eq [message_id] !delivered;
    check_eq [] (Bot_store.list "pending" synced);
    check_eq [stored] (Bot_store.list "messages" (run config "GET" route `Null offline)))

let dispatch_requires_an_explicit_agent () =
  let send state draft =
    let drafted, _ = Bot_chat.update state (Bot_chat.Draft draft) in
    match snd (Bot_chat.update drafted Bot_chat.Send) with
    | Some request -> Yojson.Basic.from_string request
    | None -> Alcotest.fail "Expected a chat request" in
  let main, _ = Bot_chat.update Bot_chat.empty (Bot_chat.Open (Bot_chat.Main bot_id)) in
  let request = send main "Fix navigation" in
  check_eq `Null (Bot_store.field "agent" (Bot_store.field "body" request));
  let request = send main "@codex Fix navigation" in
  check_eq "codex" (Bot_store.string "agent" (Bot_store.field "body" request));
  let thread, _ = Bot_chat.update main (Bot_chat.Open (Bot_chat.Thread (bot_id, message_id))) in
  let reply = send thread "Check Android as well" in
  check_eq (route ^ "/sessions/" ^ message_id ^ "/messages") (Bot_store.string "path" reply);
  check_eq `Null (Bot_store.field "agent" (Bot_store.field "body" reply))

let cases =
  [case "offline send replays the same ID after reopening SQLite" offline_send_survives_reopen;
   case "dispatch uses an explicit Agent and thread replies use their session" dispatch_requires_an_explicit_agent]
