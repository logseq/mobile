(* Headless drive scenarios: mount the real Logseq app (reducer + view)
   against drive's recording backend and replay .drive scripts from
   shared/test/logseq/drive/. A small host stub answers the app's
   pending_effects with canned projections — the same responses the
   native bridge would deliver — so UI-driven flows run end to end on
   Linux in microseconds. *)

let scenarios_dir = "logseq/drive"

let ios_profile () =
  Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost

let graph_entry id name encrypted =
  { Model.id; name; is_encrypted = encrypted; is_ready = true }

let catalog_projection graphs =
  { (App_test.empty_core_projection ()) with Model.graphs }

let journal_rows =
  [
    (App_test.journal_outline_row "journal-block-1" "journal"
       "First seeded block" "Today" 20260828 0
    |> fun (row : Model.outline_row) -> { row with has_children = true });
    App_test.journal_outline_row "journal-block-2" "journal"
      "Second seeded block" "Today" 20260828 1;
  ]

let flashcard_seed =
  App_test.flashcard "card-1" "{{c1::hidden}} seed question"
    "hidden seed question"
    [ App_test.flashcard_answer "answer-1" 0 "seed answer" ] true

let runtime_log_seed =
  [
    {
      Model.id = "log-1";
      level = "info";
      source = "drive";
      timestamp = "2026-10-09T00:00:00Z";
      message = "drive test log line";
    };
  ]

let graph_projection ~graph_id ~graph_name ~encrypted ~unlocked ?(rows = journal_rows)
    ?sidebar ?(flashcards = []) ?(sync_connected = false) ?(node_routes = [])
    ?(selected_block_ids = []) ?(task_statuses = []) graphs =
  {
    (App_test.empty_core_projection ()) with
    Model.graph_name = Some graph_name;
    selected_graph_id = Some graph_id;
    graphs;
    is_graph_encrypted = encrypted;
    is_graph_unlocked = unlocked;
    journal_outliner_rows = rows;
    outliner_rows = rows;
    flashcards;
    sync_connected;
    node_routes;
    projection_outliner_selected_block_ids = selected_block_ids;
    task_statuses;
    sidebar =
      (match sidebar with
       | Some projection -> projection
       | None -> App_test.empty_sidebar_projection ());
  }

type host =
  { mutable graphs : Model.graph list
  ; mutable rows : Model.outline_row list
  ; mutable flashcards : Model.flashcard list
  ; mutable favorites : Model.sidebar_page list
  ; mutable recents : Model.sidebar_page list
  ; mutable runtime_log : Model.runtime_log_record list
  ; mutable task_statuses : Model.task_status list
  ; mutable fail_sign_in : bool
  }

let host_sidebar host =
  {
    (App_test.empty_sidebar_projection ()) with
    Model.favorites = host.favorites;
    recent_pages = host.recents;
  }

let current_graph_projection host model ~extra =
  match Option.map
          (fun id ->
            List.find_opt (fun (g : Model.graph) -> g.id = id) host.graphs)
          model.Model.selected_graph_id
        |> Option.join
  with
  | Some g ->
    Model.ApplyCoreSnapshot
      (extra
         (graph_projection ~graph_id:g.id ~graph_name:g.name
            ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
            ~rows:host.rows ~sidebar:(host_sidebar host)
            ~flashcards:host.flashcards ~task_statuses:host.task_statuses
            ~sync_connected:true host.graphs))
  | None -> Model.ApplyCoreSnapshot (catalog_projection host.graphs)

let host_responses host model =
  let find_graph id =
    List.find_opt (fun (g : Model.graph) -> g.id = id) host.graphs
  in
  List.concat_map
    (fun eff ->
      let resolved = [ Model.ResolveEffect (Model.effect_id eff, true, "") ] in
      match eff with
      | Model.RefreshGraphsEffect id ->
        Model.DequeueEffect id
        :: Model.ApplyLocalGraphIds
             (List.map (fun (g : Model.graph) -> g.id) host.graphs)
        :: Model.ApplyCoreSnapshot (catalog_projection host.graphs)
        :: resolved
      | Model.CreateGraphEffect (id, name, encrypted, _password) ->
        let graph = graph_entry name name encrypted in
        host.graphs <- host.graphs @ [ graph ];
        Model.DequeueEffect id
        :: Model.ApplyLocalGraphIds
             (List.map (fun (g : Model.graph) -> g.id) host.graphs)
        :: Model.ApplyCoreSnapshot
             (graph_projection ~graph_id:name ~graph_name:name ~encrypted
                ~unlocked:(not encrypted) ~rows:host.rows
                ~sidebar:(host_sidebar host) ~flashcards:host.flashcards
                ~task_statuses:host.task_statuses host.graphs)
        :: resolved
      | Model.SearchNodesEffect (id, query) ->
        Model.DequeueEffect id
        :: Model.ApplySearchResults
             (query
             , [
               {
                 Model.hit_uuid = "page-1";
                 hit_title = "Alpha Doc";
                 breadcrumb = "";
                 breadcrumbs = [];
                 is_page = true;
               };
               {
                 Model.hit_uuid = "block-1";
                 hit_title = "alpha block";
                 breadcrumb = "Alpha Doc";
                 breadcrumbs = [ { Model.uuid = "page-1"; title = "Alpha Doc" } ];
                 is_page = false;
               };
             ])
        :: resolved
      | Model.DeleteLocalGraphEffect (id, graph_id) ->
        host.graphs <-
          List.filter (fun (g : Model.graph) -> g.id <> graph_id) host.graphs;
        Model.DequeueEffect id
        :: Model.ApplyLocalGraphIds
             (List.map (fun (g : Model.graph) -> g.id) host.graphs)
        :: Model.ApplyCoreSnapshot (catalog_projection host.graphs)
        :: resolved
      | Model.SignInEffect id ->
        if host.fail_sign_in then
          [
            Model.DequeueEffect id;
            Model.ResolveEffect (id, false, "invalid credentials");
          ]
        else
          Model.DequeueEffect id
          :: Model.ApplyLocalGraphIds
               (List.map (fun (g : Model.graph) -> g.id) host.graphs)
          :: Model.ApplyCoreSnapshot (catalog_projection host.graphs)
          :: resolved
      | Model.SignOutEffect id -> Model.DequeueEffect id :: resolved
      | Model.SyncNowEffect id | Model.SyncPendingEffect id ->
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               { projection with Model.sync_connected = true })
        :: resolved
      | Model.LoadFlashcardsEffect id ->
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               { projection with Model.flashcards = host.flashcards })
        :: resolved
      | Model.OpenSearchResultEffect (id, uuid)
      | Model.OpenSearchNodeEffect (id, uuid)
      | Model.OpenAppNodeEffect (id, uuid) ->
        let route =
          {
            (App_test.node_projection uuid "page-1" ("Node " ^ uuid)
               host.rows host.rows)
            with
            Model.node_outliner_rows = host.rows;
          }
        in
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               { projection with Model.node_routes = [ route ] })
        :: resolved
      | Model.SendCaptureEffect (id, title) ->
        let row =
          App_test.journal_outline_row
            (Printf.sprintf "capture-%d" id)
            "journal" title "Today" 20260828 (List.length host.rows)
        in
        host.rows <- host.rows @ [ row ];
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.AddRootBlockEffect (id, _page_uuid) ->
        let row =
          App_test.journal_outline_row
            (Printf.sprintf "capture-%d" id)
            "journal" "New block" "Today" 20260828 (List.length host.rows)
        in
        host.rows <- host.rows @ [ row ];
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.SetPageFavoriteEffect (id, uuid, favored) ->
        host.favorites <-
          (if favored then host.favorites @ [ { Model.uuid; title = uuid } ]
           else
             List.filter
               (fun (page : Model.sidebar_page) -> page.uuid <> uuid)
               host.favorites);
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.SelectSidebarPageEffect (id, uuid) ->
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               {
                 projection with
                 Model.sidebar =
                   {
                     (host_sidebar host) with
                     selected_page = Some { Model.uuid; title = uuid };
                     linked_reference_rows = host.rows;
                   };
               })
        :: resolved
      | Model.LongPressOutlinerBlockEffect (id, uuid) ->
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               {
                 projection with
                 Model.projection_outliner_selected_block_ids = [ uuid ];
               })
        :: resolved
      | Model.SetOutlinerTaskStatusEffect (id, uuid, status) ->
        host.rows <-
          List.map
            (fun (row : Model.outline_row) ->
              if row.row_uuid = uuid then
                { row with row_status = Some status }
              else row)
            host.rows;
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.ToggleOutlinerCollapsedEffect (id, uuid) ->
        host.rows <-
          List.map
            (fun (row : Model.outline_row) ->
              if row.row_uuid = uuid then
                { row with is_collapsed = not row.is_collapsed }
              else row)
            host.rows;
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.OutlinerToolbarEffect (id, action) ->
        if action = "unselect" then
          Model.DequeueEffect id
          :: current_graph_projection host model ~extra:(fun projection ->
                 {
                   projection with
                   Model.projection_outliner_selected_block_ids = [];
                 })
          :: resolved
        else resolved
      | Model.RefreshRuntimeLogEffect (id, _, _, _) ->
        Model.DequeueEffect id
        :: Model.ApplyRuntimeLog host.runtime_log
        :: resolved
      | Model.DeletePageEffect _ -> resolved
      | Model.TapOutlinerBlockEffect (id, uuid) -> (
        match
          Option.map find_graph model.Model.selected_graph_id |> Option.join
        with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               {
                 (graph_projection ~graph_id:g.id ~graph_name:g.name
                    ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
                    ~rows:host.rows ~sidebar:(host_sidebar host)
                    ~flashcards:host.flashcards host.graphs)
                 with
                 projection_outliner_editing =
                   Some
                     {
                       Model.editing_uuid = uuid;
                       editing_title = "";
                       caret_utf16_offset = 0;
                     };
               }
          :: resolved
        | None -> Model.DequeueEffect id :: resolved)
      | Model.OpenGraphEffect (id, graph_id) -> (
        match find_graph graph_id with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               (graph_projection ~graph_id:g.id ~graph_name:g.name
                  ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
                  ~rows:host.rows ~sidebar:(host_sidebar host)
                  ~flashcards:host.flashcards
                  ~task_statuses:host.task_statuses host.graphs)
          :: resolved
        | None ->
          [
            Model.DequeueEffect id;
            Model.ResolveEffect (id, false, "unknown graph");
          ])
      | Model.UnlockGraphEffect (id, _) -> (
        match
          Option.map find_graph model.Model.selected_graph_id
          |> Option.join
        with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               (graph_projection ~graph_id:g.id ~graph_name:g.name
                  ~encrypted:g.is_encrypted ~unlocked:true ~rows:host.rows
                  ~sidebar:(host_sidebar host) ~flashcards:host.flashcards
                  host.graphs)
          :: resolved
        | None -> Model.DequeueEffect id :: resolved)
      | Model.ChangeOutlinerTextEffect (id, uuid, title, caret) -> (
        match
          Option.map find_graph model.Model.selected_graph_id |> Option.join
        with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               {
                 (graph_projection ~graph_id:g.id ~graph_name:g.name
                    ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
                    ~rows:host.rows ~sidebar:(host_sidebar host)
                    ~flashcards:host.flashcards host.graphs)
                 with
                 projection_outliner_editing =
                   Some
                     {
                       Model.editing_uuid = uuid;
                       editing_title = title;
                       caret_utf16_offset = caret;
                     };
               }
          :: resolved
        | None -> Model.DequeueEffect id :: resolved)
      | Model.ReturnOutlinerEditorEffect (id, uuid, title, _caret) -> (
        match
          Option.map find_graph model.Model.selected_graph_id |> Option.join
        with
        | Some g ->
          host.rows <-
            List.map
              (fun (row : Model.outline_row) ->
                if row.row_uuid = uuid then { row with row_title = title }
                else row)
              host.rows;
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               (graph_projection ~graph_id:g.id ~graph_name:g.name
                  ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
                  ~rows:host.rows ~sidebar:(host_sidebar host)
                  ~flashcards:host.flashcards host.graphs)
          :: resolved
        | None -> Model.DequeueEffect id :: resolved)
      | eff ->
        [
          Model.DequeueEffect (Model.effect_id eff);
          Model.ResolveEffect (Model.effect_id eff, true, "");
        ])
    model.Model.pending_effects

let mount ~profile ?(authentication = "signedIn") ?(fail_sign_in = false)
    ?(rows = journal_rows) () =
  let host =
    {
      graphs = [];
      rows;
      flashcards = [ flashcard_seed ];
      favorites = [ { Model.uuid = "fav-1"; title = "Favorite Doc" } ];
      recents = [ { Model.uuid = "recent-1"; title = "Recent Doc" } ];
      runtime_log = runtime_log_seed;
      task_statuses =
        [
          App_test.task_status "ts-1" (Some "todo") "Todo"
            (Some "tabler-icon") (Some "Todo") (Some "blue");
        ];
      fail_sign_in;
    }
  in
  let self = ref None in
  let drain () =
    match !self with
    | None -> []
    | Some s -> host_responses host (Drive.Session.read_model s)
  in
  let initial =
    if authentication = "signedIn" then Model.initial ()
    else
      Model.update (Model.initial ())
        (Model.ApplyAuthentication (authentication, None))
  in
  let session =
    Drive.Session.mount ~profile ~drain
      ~registry:(View.extension_registry ())
      ~initial ~reducer:Model.update ~view:View.logseq_view ()
  in
  self := Some session;
  session

let read_file path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let scenario_names () =
  Sys.readdir scenarios_dir |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".drive")
  |> List.sort String.compare

let run_scenario name () =
  let authentication =
    if String.length name >= 5 && String.sub name 0 5 = "auth-" then
      "signedOut"
    else "signedIn"
  in
  let fail_sign_in = name = "auth-signin-error.drive" in
  let rows =
    if String.length name >= 6 && String.sub name 0 6 = "empty-" then []
    else journal_rows
  in
  let session =
    mount ~profile:(ios_profile ()) ~authentication ~fail_sign_in ~rows ()
  in
  let failures =
    Drive.Scenario.run
      (Drive.Session.driver session)
      (read_file (Filename.concat scenarios_dir name))
  in
  Drive.Session.dispose session;
  let messages =
    List.map
      (fun (f : Drive.Scenario.failure) ->
        Printf.sprintf "line %d: %s" f.line f.message)
      failures
  in
  Alcotest.(check (list string)) name [] messages

let cases =
  List.map
    (fun name -> Alcotest.test_case name `Quick (run_scenario name))
    (scenario_names ())
