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


let config : Api.api_config =
  {base_url = "http://local.example"; graph_id = ""; graph_name = None;
   token = "x.eyJzdWIiOiJiMThmNDIwMy0xNmYwLTQzYjUtYWJjMC0zZWVhYzllYzczMmMifQ.x"}

let with_store test =
  let store = Filename.temp_file "logseq-bots" ".sqlite" in
  Fun.protect ~finally:(fun () -> Sys.remove store) (fun () -> test store)

let with_db store f =
  let db = Sqlite.open_session store in
  Fun.protect ~finally:(fun () -> Sqlite.close db) (fun () -> f db)

let command ?account ?before ?(method_ = "GET") ?path ?(body = `Null) db config route =
  let fields = ["route", `String route; "method", `String method_;
    "path", `String (Option.value ~default:route path); "body", body] in
  let fields = match before with None -> fields | Some cursor -> ("before", `String cursor) :: fields in
  match Bot_store.run ?account db ~config ~fresh_id:(fun () -> message_id) (`Assoc fields) with
  | Ok view -> view
  | Error error -> Alcotest.fail error

let sync db config reason send =
  let rec respond = function
    | Bot_store.Done result -> result
    | Bot_store.Send (request, _, resume) -> respond (resume (send request)) in
  respond (Bot_store.sync db ~config (Bot_store.scope config |> Option.get) reason ~changed:ignore)

let reply view = Some (Api.response 200 (Yojson.Basic.to_string (`Assoc view)))

let bot = `Assoc ["id", `String bot_id; "name", `String "Logseq"]

let offline_send_survives_reopen () =
  with_store (fun store ->
    let other_server = {config with base_url = "https://api-staging.logseq.io"} in
    let draft = with_db store (fun db -> command ~method_:"POST" ~path:(route ^ "/messages")
      ~body:(`Assoc ["body", `String "Fix navigation"; "agent", `String "codex"]) db config route) in
    check_eq [message_id]
      (List.map (Bot_store.string "id") (Bot_store.list "pending" draft));
    with_db store (fun db ->
      check_eq [] (Bot_store.list "pending" (command db other_server route));
      ignore (sync db config Bot_store.Account (fun _ -> None));
      check_eq [message_id] (List.map (Bot_store.string "id") (Bot_store.list "pending" (command db config route))));
    let delivered = ref [] in
    let stored = `Assoc ["id", `String message_id; "bot_id", `String bot_id;
      "seq", `String "12"; "body", `String "Fix navigation"] in
    with_db store (fun db ->
      ignore (sync db config Bot_store.Account (fun (request : Api.api_request) ->
        match request.body with
        | Some json ->
          delivered := Bot_store.string "id" (Yojson.Basic.from_string json) :: !delivered;
          reply ["message", stored]
        | None when request.url = config.base_url ^ "/bots" -> reply ["bots", `List [bot]; "agents", agents]
        | None -> reply ["bot", bot; "messages", `List [stored]; "more", `Bool false; "agents", agents])));
    check_eq [message_id] !delivered;
    with_db store (fun db ->
      let cached = command db config route in
      check_eq [] (Bot_store.list "pending" cached);
      check_eq agents (Bot_store.field "agents" cached);
      check_eq [stored] (Bot_store.list "messages" cached);
      let offline = {config with token = ""} in
      let account = (Created_by.of_token config.token |> Option.get).uuid in
      check_eq [stored] (Bot_store.list "messages" (command ~account db offline route));
      let unrelated_account = "cea54979-0963-4697-beb2-747ddc18fa0e" in
      check_eq [] (Bot_store.list "messages" (command ~account:unrelated_account db offline route));
      check_eq `Null (Bot_store.field "agents" (command db other_server route))))

let account_sync_populates_unopened_routes () =
  let session_id = "aa3551f5-1a5f-4138-a52e-124a1fb59fce" in
  let thread = route ^ "/sessions/" ^ session_id in
  let session count = `Assoc ["id", `String session_id; "bot_id", `String bot_id;
    "root_message_id", `String message_id; "reply_count", `Int count] in
  let message id seq fields =
    `Assoc (["id", `String id; "bot_id", `String bot_id; "seq", `String seq] @ fields) in
  let root = message message_id "1" ["body", `String "Run the checks"] in
  let child seq = message seq seq ["session_id", `String session_id] in
  let assert_sync db reason responses =
    let remaining = ref responses in
    ignore (sync db config reason (fun (request : Api.api_request) ->
      match !remaining with
      | [] -> Alcotest.fail ("Unexpected request " ^ request.url)
      | (path, result) :: rest ->
        check_eq (config.base_url ^ path) request.url;
        remaining := rest;
        result));
    check_eq [] !remaining in
  with_store (fun store ->
    with_db store (fun db ->
      assert_sync db Bot_store.Account
        ["/bots", reply ["bots", `List [bot]; "agents", agents];
         route, reply ["bot", bot; "sessions", `List [session 1]; "messages", `List [root]];
         thread, reply ["session", session 1; "root", root; "messages", `List [child "4"]; "more", `Bool true]]);
    with_db store (fun db ->
      check_eq [bot] (Bot_store.list "bots" (command db config "/bots"));
      check_eq [session 1] (Bot_store.list "sessions" (command db config route));
      let cached = command db config thread in
      check_eq root (Bot_store.field "root" cached);
      check_eq [child "4"] (Bot_store.list "messages" cached);
      check_eq (`String "4") (Bot_store.field "fetchOlder" (command ~before:"4" db config thread));
      assert_sync db (Bot_store.History (thread, 4L))
        [thread ^ "?before=4", reply ["session", session 1; "root", root; "messages", `List [child "3"]]];
      check_eq [child "3"] (Bot_store.list "messages" (command ~before:"4" db config thread));
      assert_sync db Bot_store.Account
        ["/bots", reply ["bots", `List [bot]];
         route ^ "?after=1", reply ["bot", bot; "sessions", `List [session 1]; "messages", `List []]];
      assert_sync db (Bot_store.Changed (bot_id, Some session_id))
        ["/bots", reply ["bots", `List [bot]];
         route ^ "?after=1", reply ["bot", bot; "sessions", `List [session 2]; "messages", `List []];
         thread ^ "?after=4", reply ["session", session 2; "root", root; "messages", `List [child "5"]]];
      check_eq [child "3"; child "4"; child "5"] (Bot_store.list "messages" (command db config thread));
      assert_sync db Bot_store.Account ["/bots", reply ["bots", `List []]];
      check_eq [] (Bot_store.list "bots" (command db config "/bots"));
      check_eq [] (Bot_store.list "sessions" (command db config route));
      check_eq [] (Bot_store.list "messages" (command db config thread))))

let navigation_uses_only_local_effects () =
  let open Model in
  let initial = update (initial ()) (ApplyAuthentication ("signedIn", None)) in
  let syncing = update initial (SyncBots Bot_store.Account) in
  check_eq true (List.exists (function BotsSyncEffect _ -> true | _ -> false) syncing.pending_effects);
  let assert_local state =
    check_eq [`String "GET"] (List.filter_map (function
      | BotsEffect (_, payload) -> Some (Bot_store.field "method" (Yojson.Basic.from_string payload))
      | BotsSyncEffect _ -> Alcotest.fail "Navigation enqueued network sync"
      | _ -> None) state.pending_effects) in
  assert_local (update initial ShowBots);
  let cached_index = update initial (BotsAction (Bot_chat.Receive
    (`Assoc ["route", `String "/bots"; "bots", `List [bot]]))) in
  assert_local (update cached_index ShowBots);
  assert_local (update initial (BotsAction (Bot_chat.Open (Bot_chat.Main bot_id))));
  assert_local (update initial (BotsAction (Bot_chat.Open (Bot_chat.Thread (bot_id, message_id)))));
  let main = open_bot () in
  let _, request = Bot_chat.update main (Bot_chat.Open (Bot_chat.Sessions (bot_id, false))) in
  check_eq None request

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

let bot_creation_uses_the_current_graph () =
  let open Bot_chat in
  let graph = "28934400-6a74-7d92-8b2d-06508fff7207" in
  let other = "28934400-6a75-7f11-9d01-0fc9b117c92c" in
  let index, _ = update empty (Receive (`Assoc ["route", `String "/bots";
    "graphIds", `List [`String graph; `String other]; "shareableGraphs", `List [`String graph]])) in
  let form, _ = update ~selected_graph:graph index (Open Create) in
  let form, _ = update form (Name "Mobile") in
  check_eq None (snd (update form Save_bot));
  check_eq None (snd (update ~selected_graph:other form Save_bot));
  let form, _ = update form (Share_graph true) in
  let request = snd (update ~selected_graph:graph form Save_bot) |> Option.get |> Yojson.Basic.from_string in
  let body = Bot_store.field "body" request in
  check_eq graph (Bot_store.string "graphId" body);
  check_eq graph (Bot_store.string "sharedGraphId" body)

let cases =
  [case "offline send replays the same ID after reopening SQLite" offline_send_survives_reopen;
   case "account sync fills unopened routes and keeps earlier messages in SQLite" account_sync_populates_unopened_routes;
   case "Bot, Session and thread navigation uses local data" navigation_uses_only_local_effects;
   case "dispatch uses an explicit Agent and thread replies use their session" dispatch_requires_an_explicit_agent;
   case "selecting an inline Agent replaces the query and preserves the rest of the draft" mentions_complete_inside_the_draft;
   case "handoffs and late attachment results stay in their own draft" bot_handoff_and_attachment_are_bound_to_the_draft;
   case "outgoing messages render immediately and reconcile with a stable ID" sending_is_visible_before_acknowledgement;
   case "session title search preserves the selected scope" sessions_filter_by_title_within_scope;
   case "creating a Bot binds it to the current Graph" bot_creation_uses_the_current_graph]
