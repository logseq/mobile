open Test_util
module D = Datascript
module R = Graph_runtime
module G = Graph_runtime_test
module S = Search_index
module J = Yojson.Basic
let bulk_uuid i = Printf.sprintf "00000000-0000-4000-8000-%012d" i
let large_db () =
  let ids = List.init 1024 Fun.id in
  D.db_with (List.concat_map (fun i -> let id = D.Entity_id (10000 + i) in
    [D.Add (id, "block/uuid", D.Uuid (bulk_uuid i));
     D.Add (id, "block/title", D.String (Printf.sprintf "Bulk %04d" i));
     D.Add (id, "block/page", D.Ref_to (D.Lookup_ref ("block/uuid", D.Uuid "page")));
     D.Add (id, "block/parent", D.Ref_to (D.Lookup_ref ("block/uuid", D.Uuid "page")))]) ids)
    (G.base_db "Old")
let count path = S.search_query path "select id, page, title from blocks" [] |> List.length
let finish runtime =
  let rec loop remaining =
    if (R.state runtime).search_index_is_fresh then () else
    if remaining = 0 then fail "Index maintenance did not finish" else
    (R.refresh_search runtime; loop (remaining - 1)) in
  loop 5000
let search_does_not_build_the_graph () = G.with_search_runtime ~indexed:false (large_db ()) (fun path _ runtime ->
  check_eq (count path) 0;
  ignore (R.search runtime "Bulk");
  ignore (R.search_page runtime ~offset:0 ~limit:20 "Bulk");
  check ~msg:"search never performs the deferred full rebuild" (not (R.state runtime).search_index_is_fresh);
  check_eq ~msg:"querying an unbuilt index leaves construction to maintenance" (count path) 0)
let bounded_steps_allow_edits_and_cleanup () = G.with_search_runtime ~indexed:false (large_db ()) (fun path conn runtime ->
  S.search_upsert path ["stale", "Removed page", "page"];
  R.refresh_search runtime;
  check ~msg:"one maintenance slice is bounded independently of graph size" (count path > 1 && count path <= 33);
  check ~msg:"partial indexes are never marked complete" (not (R.state runtime).search_index_is_fresh);
  check_eq (Graph_sqlite.search_version path) None;
  let stage intent = check_ok (R.stage runtime (R.queued_operation runtime (R.fresh_uuid ()) intent)) in
  stage (Pending_ops.Save_title {uuid = (bulk_uuid 900); expected_title = "Bulk 0900"; title = "Renamed during indexing"});
  stage (Pending_ops.Insert_block {uuid = "new-during-indexing"; title = "Created during indexing";
    page_uuid = "page"; parent_uuid = "page"; order = "z0"; created_at = 1234});
  stage (Pending_ops.Delete_blocks {uuids = [(bulk_uuid 901)]});
  ignore (D.transact_conn conn [
    D.Add (D.Lookup_ref ("block/uuid", D.Uuid (bulk_uuid 902)), "block/title", D.String "Remote edit during indexing");
    D.Add (D.Entity_id 20000, "block/uuid", D.Uuid "remote-during-indexing");
    D.Add (D.Entity_id 20000, "block/title", D.String "Remote insertion during indexing");
    D.Add (D.Entity_id 20000, "block/page", D.Ref 1)]);
  R.rebase runtime 43 [] [(bulk_uuid 902); "remote-during-indexing"];
  finish runtime;
  let found query uuid = List.exists (fun (hit : S.indexed_search_hit) -> hit.uuid = uuid) (R.search runtime query) in
  check ~msg:"unvisited rows use the latest title" (found "Renamed" (bulk_uuid 900));
  check ~msg:"new nodes are not lost between rebuild slices" (found "Created" "new-during-indexing");
  check ~msg:"deleted rows cannot be resurrected by an old cursor" (not (found "0901" (bulk_uuid 901)));
  check ~msg:"remote edits and new nodes survive a rebase between slices"
    (found "Remote edit" (bulk_uuid 902) && found "Remote insertion" "remote-during-indexing");
  check_eq (S.search_query path "select id, page, title from blocks where id = ?" ["stale"]) [];
  check_eq (List.length (R.pending_operations runtime)) 3)
let partial_rebuilds_resume_after_restart () = G.with_search_runtime ~indexed:false (large_db ()) (fun path _ original ->
  let stored = D.store ~storage:(Graph_store.storage original.path) (large_db ()) in
  let options = {R.default_options with search_index_path = Some path} in
  let runtime = R.create original.path 42 (D.conn_from_db stored) options in
  R.refresh_search runtime;
  check ~msg:"a partial build remains restartable" (not (R.state runtime).search_index_is_fresh);
  let reopened = R.create original.path 42 (Result.get_ok (Graph_store.restore_conn original.path)) options in
  finish reopened;
  let clean = R.create original.path 42 (Result.get_ok (Graph_store.restore_conn original.path)) options in
  check ~msg:"completed indexes reopen without rebuilding" (R.state clean).search_index_is_fresh;
  check_eq (Graph_sqlite.search_version path) (Graph_sqlite.search_source_version original.path))
let imported_graphs_have_scoped_maintenance () =
  Mobile_session_test.with_favorite_graphs (fun host call fields cache download ->
    ignore (call "bootstrapGraph" (fields "graph-a"));
    ignore (call "importSnapshot" (fields "graph-a" @ download "graph-a"));
    let graph = host.Mobile_session.database.Mobile_database.graph in
    let runtime () = (Option.get !(graph.Mobile_graph.current)).read_runtime in
    let rec build remaining =
      if (R.state (runtime ())).search_index_is_fresh then ()
      else if remaining = 0 then fail "Imported graph never indexed" else
      (ignore (call "maintainSearchIndex" ["graphId", `String "graph-a"]); build (remaining - 1)) in
    build 100;
    check ~msg:"an imported graph is searchable without using search to build it"
      (List.exists (fun (hit : S.indexed_search_hit) -> hit.uuid = "graph-a-page") (R.search (runtime ()) "Favorite"));
    cache "graph-b";
    ignore (call "configure" ["baseUrl", `String "https://example.com"; "token", `String ""; "graphId", `String "graph-b"]);
    ignore (call "bootstrapGraph" (fields "graph-b"));
    let before = R.db (runtime ()) in
    ignore (call "maintainSearchIndex" ["graphId", `String "graph-a"]);
    check ~msg:"a stale queued batch does not act on the newly selected graph"
      (before == R.db (runtime ()) && not (R.state (runtime ())).search_index_is_fresh))
let idle_native_drain_builds_and_yields () =
  G.with_search_runtime ~indexed:false (large_db ()) (fun _ _ runtime ->
    ignore (Native_bridge.initialize 2 2 0);
    Fun.protect ~finally:(fun () ->
      Native_bridge.set_search_index_source (fun () -> None);
      ignore (Native_bridge.dispose ())) (fun () ->
      ignore (Native_bridge.apply_response
        {|{"ok":true,"result":{"selectedGraphId":"graph","graphName":"Graph"}}|});
      let rec drain_existing remaining =
        if remaining = 0 then fail "Initial native effects never drained" else
        let encoded = Native_bridge.take_effect () in
        if encoded <> "" then
          let eff = J.Util.member "effect" (J.from_string encoded) in
          let id = J.Util.member "id" eff |> J.Util.to_int in
          ignore (Native_bridge.resolve_effect id true "");
          drain_existing (remaining - 1) in
      drain_existing 100;
      Native_bridge.set_search_index_source (fun () ->
        if R.search_index_pending runtime then Some "graph" else None);
      let take () =
        let encoded = Native_bridge.take_effect () in
        check ~msg:"idle maintenance is scheduled without a search request" (encoded <> "");
        J.Util.member "effect" (J.from_string encoded) in
      let step eff =
        check_eq (J.Util.member "kind" eff) (`String "maintain-search-index");
        let id = J.Util.member "id" eff |> J.Util.to_int in
        check_eq ~msg:"a running slice is not duplicated" (Native_bridge.take_effect ()) "";
        let payload = J.to_string eff in
        check_eq (Core_effect.request ~now:(fun () -> 0) ~fresh_id:(fun () -> "unused") (Some payload))
          (Ok ("maintainSearchIndex", Some {|{"graphId":"graph"}|}));
        R.refresh_search runtime;
        ignore (Native_bridge.resolve_effect id true "") in
      let first = take () in
      check_eq ~msg:"an in-flight slice is not queued twice" (Native_bridge.take_effect ()) "";
      ignore (Native_bridge.flush_action (Model.ChangeComposerDraft "Typing while indexing"));
      check_eq (Lui_app.model (Native_bridge.app ())).composer_draft "Typing while indexing";
      let draft = take () in
      check_eq (J.Util.member "kind" draft) (`String "persist-composer-draft");
      ignore (Native_bridge.resolve_effect (J.Util.member "id" draft |> J.Util.to_int) true "");
      step first;
      ignore (Native_bridge.flush_action (Model.RequestAppNode "page"));
      let interaction = take () in
      check ~msg:"navigation runs before the next maintenance slice"
        (J.Util.member "kind" interaction <> `String "maintain-search-index");
      let id = J.Util.member "id" interaction |> J.Util.to_int in
      ignore (Native_bridge.resolve_effect id true "");
      let rec build remaining =
        if not (R.search_index_pending runtime) then ()
        else if remaining = 0 then fail "Automatic index drain did not complete"
        else (step (take ()); build (remaining - 1)) in
      build 5000;
      check (R.state runtime).search_index_is_fresh;
      check_eq ~msg:"a complete index stops scheduling work" (Native_bridge.take_effect ()) ""))
let completion_refreshes_visible_search () =
  let model = { (Model.initial ()) with selected_graph_id = Some "graph"; search_query = "Bulk"} in
  let complete = Model.resolve_successful_effect model (Model.MaintainSearchIndexEffect (1, "graph"))
    {|{"ok":true,"result":{"searchIndexReady":true}}|} in
  check ~msg:"search open during indexing refreshes when construction finishes"
    (List.exists (function Model.SearchNodesEffect (_, "Bulk") -> true | _ -> false) complete.pending_effects);
  let partial = Model.resolve_successful_effect model (Model.MaintainSearchIndexEffect (1, "graph"))
    {|{"ok":true,"result":{"searchIndexReady":false}}|} in
  check_eq ~msg:"partial slices do not repeatedly refresh the search UI" partial.pending_effects [];
  let stale = Model.resolve_successful_effect model (Model.MaintainSearchIndexEffect (1, "old-graph"))
    {|{"ok":true,"result":{"searchIndexReady":true}}|} in
  check_eq ~msg:"old graph completion does not change the new graph search" stale.pending_effects []
let cases = [
  case "completed indexing refreshes active search only for the current graph" completion_refreshes_visible_search;
  case "idle native effects automatically build while yielding to interactions" idle_native_drain_builds_and_yields;
  case "search reads never trigger full graph indexing" search_does_not_build_the_graph;
  case "bounded indexing yields to editing and preserves concurrent changes" bounded_steps_allow_edits_and_cleanup;
  case "partial indexing resumes safely after restart" partial_rebuilds_resume_after_restart;
  case "imported graphs build automatically through scoped maintenance" imported_graphs_have_scoped_maintenance;
]
