open Test_util
module J = Yojson.Basic
module Ds = Datascript
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let result response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true); member "result" response

let comments_and_reactions_have_distinct_presentation () =
  let db = match Graph_bootstrap.database "discussion" false (fun x -> Ok x) with Ok db -> db | Error e -> fail e in
  let uuid n = Printf.sprintf "10000000-0000-4000-8000-%012d" n in
  let add n attr value = Ds.Add (Ds.Lookup_ref ("block/uuid", Ds.Uuid (uuid n)), attr, value) in
  let db = Ds.db_with [
    Ds.Add (Ds.Entity_id 9001, "block/uuid", Ds.Uuid (uuid 1));
    Ds.Add (Ds.Entity_id 9002, "block/uuid", Ds.Uuid (uuid 2));
    Ds.Add (Ds.Entity_id 9003, "block/uuid", Ds.Uuid (uuid 3));
    Ds.Add (Ds.Entity_id 9004, "block/uuid", Ds.Uuid (uuid 4));
    add 1 "block/title" (Ds.String "Discussion");
    add 1 "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Comments"));
    add 2 "block/title" (Ds.String "A comment");
    add 2 "block/parent" (Ds.Ref_to (Ds.Lookup_ref ("block/uuid", Ds.Uuid (uuid 1))));
    add 3 "logseq.property.reaction/target" (Ds.Ref_to (Ds.Lookup_ref ("block/uuid", Ds.Uuid (uuid 2))));
    add 3 "logseq.property.reaction/emoji-id" (Ds.String "+1");
    add 4 "logseq.property.reaction/target" (Ds.Ref_to (Ds.Lookup_ref ("block/uuid", Ds.Uuid (uuid 2))));
    add 4 "logseq.property.reaction/emoji-id" (Ds.String "+1")
  ] db in
  let decorate uuid = Node_presentation.decorate db uuid (`Assoc []) in
  check_eq (member "discussionKind" (decorate (uuid 1))) (`String "thread");
  check_eq (member "discussionKind" (decorate (uuid 2))) (`String "comment");
  let reactions = Q.items "reactions" (decorate (uuid 2)) in
  check_eq (List.length reactions) 1;
  check_eq (member "count" (List.hd reactions)) (`Int 2);
  check_eq (member "emoji" (List.hd reactions)) (`String "👍")

let task_comment_links_follow_local_and_confirmed_renames () =
  Graph_runtime_test.with_store (fun path ->
    let db = Q.fixture "" in
    let now = Int64.to_int (Dev_query.Date_time_util.journal_day_to_local_ms 20261123) in
    let db = Ds.db_with (List.map (fun uuid ->
      Q.put uuid Journal_task_dates.scheduled (Ds.Int64 (Int64.of_int now))) [Q.alpha; Q.beta]) db in
    let operation_id = "rename" in
    let comment = Pending_ops.Add_comment {
      targets = [Q.alpha]; thread = "10000000-0000-4000-8000-000000000091";
      uuid = "10000000-0000-4000-8000-000000000092"; reply_to = None;
      text = "See [[" ^ Q.beta ^ "]]"; created_at = now } in
    let tx = match Pending_projection.compile db comment with Ok tx -> tx | Error why -> fail why in
    let conn = Ds.conn_from_db (Ds.db_with tx db) in
    let runtime = Graph_runtime.create_base path 42 conn Graph_runtime.default_options in
    let cache = Journal_task_dates.create_cache () in
    let project force = Journal_task_dates.project cache ~graph:"tasks" ~now ~force (Graph_runtime.db runtime) in
    let label agenda =
      let task = List.find (fun row -> member "uuid" row = `String Q.alpha) (Q.items "today" agenda) in
      let thread = List.hd (Q.items "commentThreads" (member "block" task)) in
      let preview = member "preview" (List.hd (Q.items "comments" thread)) in
      member "displayTitle" preview in
    let expect_label expected agenda =
      let actual = label agenda in
      check_eq ~msg:(J.to_string actual) actual (`String expected) in
    expect_label "See Beta result" (project false);
    let operation : Pending_ops.pending_operation = {
      operation_id; base_t = 42; state = Pending_ops.Queued;
      intent = Pending_ops.Save_title {uuid = Q.beta; expected_title = "Beta result"; title = "Local title"} } in
    (match Graph_runtime.stage ~journal_tasks:cache runtime operation with Ok () -> () | Error why -> fail why);
    let local = project false in
    expect_label "See Local title" local;
    check_eq local (project true);
    ignore (Ds.transact_conn conn [Q.put Q.beta "block/title" (Ds.String "Confirmed title")]);
    let eid = Option.get (Ds.entid (Ds.conn_db conn) "block/uuid" (Ds.Uuid Q.beta)) in
    let applied : Journal_sync.applied = {
      operation_ids = [operation_id]; changed_uuids = [Q.beta];
      changed_attributes = ["block/title"]; changed_eids = [eid] } in
    Graph_runtime.rebase ~agenda_update:(cache, applied) ~changed_attributes:applied.changed_attributes
      runtime 43 applied.operation_ids applied.changed_uuids;
    let confirmed = project false in
    expect_label "See Confirmed title" confirmed;
    check_eq confirmed (project true))

let leaving_notifications_cancels_an_unresolved_push () =
  let graph = Q.page and id = Q.alpha in
  let current = {(Model.initial ()) with selected_graph_id = Some graph} in
  let opened = Model.update current (Model.OpenPushedDiscussion (graph, id)) in
  check_eq opened.destination Model.NotificationsDestination;
  check_eq opened.pending_push_route (Some (graph, id));
  List.iter (fun destination ->
    let left = Model.update opened destination in
    check_eq left.pending_push_route None)
    [Model.ShowJournals; Model.ShowTasks]

let cases = [
  case "discussion presentation" comments_and_reactions_have_distinct_presentation;
  case "leaving Notifications cancels an unresolved push" leaving_notifications_cancels_an_unresolved_push;
  case "task comment UUID links follow local and confirmed renames" task_comment_links_follow_local_and_confirmed_renames;
]
