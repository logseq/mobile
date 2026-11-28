open Test_util

let bot_id = "25376367-2819-40cf-b976-f3188018c744"
let message_id = "62e2997c-b14f-4f7a-9a3a-80238f6cb675"
let route = "/bots/" ^ bot_id

let agents =
  `List (List.map (fun (name, available) -> `Assoc ["name", `String name; "available", `Bool available])
    ["devin", true; "codex", true; "pi", false])

let open_bot () =
  let main, _ = Bot_chat.update Bot_chat.empty (Bot_chat.Open (Bot_chat.Main bot_id)) in
  fst (Bot_chat.update main (Bot_chat.Receive (`Assoc ["route", `String route; "agents", agents])))


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
        | None -> `Assoc ["messages", `List [stored]; "more", `Bool false; "agents", agents] in
      Ok (Api.response 200 (Yojson.Basic.to_string body)) in
    let synced = run config "GET" route `Null online in
    check_eq [message_id] !delivered;
    check_eq [] (Bot_store.list "pending" synced);
    let cached = run config "GET" route `Null offline in
    check_eq agents (Bot_store.field "agents" cached);
    check_eq [stored] (Bot_store.list "messages" cached);
    check_eq `Null (Bot_store.field "agents" (run other_server "GET" route `Null offline)))

let dispatch_requires_an_explicit_agent () =
  let send state draft =
    let drafted, _ = Bot_chat.update state (Bot_chat.Draft draft) in
    match snd (Bot_chat.update drafted Bot_chat.Send) with
    | Some request -> Yojson.Basic.from_string request
    | None -> Alcotest.fail "Expected a chat request" in
  let main = open_bot () in
  let request = send main "Fix navigation" in
  check_eq `Null (Bot_store.field "agent" (Bot_store.field "body" request));
  let unconfigured = Bot_store.field "body" (send main "@Pi Fix navigation") in
  check_eq `Null (Bot_store.field "agent" unconfigured);
  check_eq "@Pi Fix navigation" (Bot_store.string "body" unconfigured);
  let request = send main "@Pi triage; @codex Fix navigation" in
  check_eq "@Pi triage; Fix navigation" (Bot_store.string "body" (Bot_store.field "body" request));
  check_eq "codex" (Bot_store.string "agent" (Bot_store.field "body" request));
  let workflow = Bot_store.field "body" (send main "@Codex @Devin @codex Review navigation") in
  check_eq [`String "codex"; `String "devin"] (Bot_store.list "agents" workflow);
  check_eq "Review navigation" (Bot_store.string "body" workflow);
  check_eq "codex" (Bot_store.string "agent" workflow);
  let thread, _ = Bot_chat.update main (Bot_chat.Open (Bot_chat.Thread (bot_id, message_id))) in
  let reply = send thread "Check Android as well" in
  check_eq (route ^ "/sessions/" ^ message_id ^ "/messages") (Bot_store.string "path" reply);
  check_eq `Null (Bot_store.field "agent" (Bot_store.field "body" reply));
  let thread_route = route ^ "/sessions/" ^ message_id in
  let thread, _ = Bot_chat.update thread (Bot_chat.Receive (`Assoc ["route", `String thread_route; "agents", agents])) in
  let forwarded = send thread "@Codex Review the earlier reply" in
  check_eq (thread_route ^ "/messages") (Bot_store.string "path" forwarded);
  check_eq "codex" (Bot_store.string "agent" (Bot_store.field "body" forwarded))


let mentions_complete_inside_the_draft () =
  let update state action = fst (Bot_chat.update state action) in
  let main = open_bot () in
  let typed = update main (Bot_chat.Draft "@") in
  check_eq (Some {Bot_chat.start = 0; stop = 1; query = ""}) typed.active_mention;
  let narrowed = update typed (Bot_chat.Draft "@Co") in
  check_eq (Some {Bot_chat.start = 0; stop = 3; query = "co"}) narrowed.active_mention;
  let selected = update narrowed (Bot_chat.Select_agent "codex") in
  check_eq "@Codex " (Bot_chat.draft selected);
  check_eq None selected.active_mention;
  check_eq (Some "codex", "") (Bot_chat.mentions selected);
  let before = update main (Bot_chat.Draft "Fix the navigation") in
  let editing = update before (Bot_chat.Draft "Fix @dthe navigation") in
  let completed = update editing (Bot_chat.Select_agent "devin") in
  check_eq "Fix @Devin the navigation" (Bot_chat.draft completed);
  check_eq (Some "devin", "Fix the navigation") (Bot_chat.mentions completed);
  let inside_email = update main (Bot_chat.Draft "name@devin") in
  check_eq None inside_email.active_mention;
  check_eq (None, "name@devin") (Bot_chat.mentions inside_email);
  let dismissed = update narrowed Bot_chat.Dismiss_mentions in
  check_eq "@Co" (Bot_chat.draft dismissed);
  check_eq None dismissed.active_mention;
  let reopened = update dismissed Bot_chat.Pick_agent in
  check_eq narrowed.active_mention reopened.active_mention;
  check reopened.focus_request

let bot_handoff_and_attachment_are_bound_to_the_draft () =
  let main_route = route in
  let open Bot_chat in
  let apply state action = fst (update state action) in
  let target = "20926f2b-927d-4ce0-9885-77f09176c9c8" in
  let main = apply (open_bot ()) (Receive (`Assoc ["route", `String main_route;
    "mentionableBots", `List [`Assoc ["id", `String target; "name", `String "Logseq QA"]]])) in
  let main = apply (apply main (Draft "@Log")) (Select_bot target) in
  let main = apply main (Draft (draft main ^ "@codex Check this file")) in
  check_eq (["codex"], Some target, "Check this file") (recipients main);
  let thread_page = Thread (bot_id, message_id) in
  let file = {uuid = message_id; title = "demo.txt"; local_path = "/tmp/demo.txt"; payload = "{}"} in
  let thread = apply (apply main (Open thread_page)) (Stage_attachment (main_route, file)) in
  check_eq [] (attachments thread);
  let back = apply thread Back in
  check_eq [file] (attachments back)

let sending_is_visible_before_acknowledgement () =
  let main = open_bot () in
  let modeled, _ = Bot_chat.update main (Bot_chat.Draft "@Codex Check the layout") in
  let sent, wire = Bot_chat.update modeled Bot_chat.Send in
  let payload = Option.get wire |> Yojson.Basic.from_string |> Bot_store.field "body" in
  let id = Bot_store.string "id" payload in
  check (Ref_text.is_uuid id);
  check_eq (Some id) (Bot_chat.latest_send sent);
  check_eq "" (Bot_chat.draft sent);
  let optimistic = match Bot_chat.messages sent with [row] -> row | _ -> Alcotest.fail "Expected an immediate message" in
  check_eq id (Bot_store.string "id" optimistic);
  check_eq "Check the layout" (Bot_store.string "body" optimistic);
  check_eq (`Bool true) (Bot_store.field "pending" optimistic);
  let receive state fields =
    fst (Bot_chat.update state (Bot_chat.Receive (`Assoc (("route", `String route) :: fields)))) in
  let stale = receive sent ["pending", `List []; "messages", `List []] in
  check_eq [optimistic] (Bot_chat.messages stale);
  let persisted = receive stale ["pending", `List [optimistic]] in
  check_eq [optimistic] (Bot_chat.messages persisted);
  let confirmed = `Assoc ["id", `String id; "author", `String "user";
    "body", `String "Check the layout"; "seq", `String "91"] in
  let ack = receive persisted ["pending", `List [optimistic]; "acknowledged", `List [confirmed]] in
  check_eq [confirmed] (Bot_chat.messages ack);
  let thread, _ = Bot_chat.update sent (Bot_chat.Open (Bot_chat.Thread (bot_id, message_id))) in
  check_eq [] (Bot_chat.messages thread);
  check_eq None (Bot_chat.latest_send thread)

let sessions_filter_by_title_within_scope () =
  let session id status title = `Assoc ["id", `String id; "status", `String status;
    "title", `String title; "agent", `String "Reviewer"] in
  let sessions = [session "pending" "needs_input" "  Logseq [QA] 导航  ";
    session "completed" "completed" "Logseq [QA] 导航";
    session "other" "needs_input" "Graph 導航"] in
  let matches ~needs query =
    List.filter (Bot_chat.session_matches ~needs ~query) sessions |> List.map (Bot_store.string "id") in
  check_eq ["pending"; "completed"] (matches ~needs:false "  [qa] 导  ");
  check_eq ["pending"] (matches ~needs:true "  [qa] 导  ");
  check_eq ["other"] (matches ~needs:true "導航");
  check_eq [] (matches ~needs:true "Reviewer");
  check_eq [] (matches ~needs:true "[qa] 導");
  check_eq ["pending"; "other"] (matches ~needs:true " \t ")

let cases =
  [case "offline send replays the same ID after reopening SQLite" offline_send_survives_reopen;
   case "dispatch uses an explicit Agent and thread replies use their session" dispatch_requires_an_explicit_agent;
   case "selecting an inline Agent replaces the query and preserves the rest of the draft" mentions_complete_inside_the_draft;
   case "handoffs and late attachment results stay in their own draft" bot_handoff_and_attachment_are_bound_to_the_draft;
   case "outgoing messages render immediately and reconcile with a stable ID" sending_is_visible_before_acknowledgement;
   case "session title search preserves the selected scope" sessions_filter_by_title_within_scope]
