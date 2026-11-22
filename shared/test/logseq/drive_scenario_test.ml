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
  { Model.id; name; is_encrypted = encrypted; is_ready = true; role = None }

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
    {
      Model.id = "log-error";
      level = "ERROR";
      source = "drive";
      timestamp = "2026-10-09T00:00:01Z";
      message = "drive test failure";
    };
  ]

let tag_choices =
  [ { Model.uuid = "tag-1"; title = "Project" } ]

let page_candidate =
  {
    Model.candidate_index = 0;
    candidate_group = Some "Pages";
    candidate_label = "Alpha Doc";
    candidate_markup_json = "[]";
    candidate_value = "page-1";
  }

let contains_substr haystack needle =
  let limit = String.length haystack - String.length needle in
  let rec go index =
    index <= limit
    && (String.sub haystack index (String.length needle) = needle || go (index + 1))
  in
  needle = "" || (limit >= 0 && go 0)

let json_fields payload =
  try match Yojson.Basic.from_string payload with `Assoc fields -> fields | _ -> []
  with _ -> []

let json_string fields key =
  match List.assoc_opt key fields with Some (`String value) -> Some value | _ -> None

let graph_projection ~graph_id ~graph_name ~encrypted ~unlocked ?(rows = journal_rows)
    ?sidebar ?(flashcards = []) ?(sync_connected = false) ?(node_routes = [])
    ?(selected_block_ids = []) ?(task_statuses = []) ?(has_older_journals = false)
    ?(decks_json = "") ?(applied_server_t = Some 1) graphs =
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
    flashcard_decks_json = decks_json;
    sync_connected;
    applied_server_t;
    node_routes;
    projection_outliner_selected_block_ids = selected_block_ids;
    task_statuses;
    has_older_journals;
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
  ; mutable selected_page : Model.sidebar_page option
  ; mutable runtime_log : Model.runtime_log_record list
  ; mutable task_statuses : Model.task_status list
  ; mutable fail_sign_in : bool
  ; mutable has_older : bool
  ; mutable deck_selected : string option
  ; mutable deck_completed : bool
  ; mutable deck_created : string option
  ; mutable deck_targets : (string * string) list
  }

let host_sidebar host =
  {
    (App_test.empty_sidebar_projection ()) with
    Model.favorites = host.favorites;
    recent_pages = host.recents;
    selected_page = host.selected_page;
  }

let decks_json host =
  let string_field value =
    match value with None -> `Null | Some value -> `String value
  in
  Yojson.Basic.to_string
    (`Assoc
       [
         ( "items"
         , `List
             [
               `Assoc
                 [
                   ("uuid", `String "deck-1"); ("title", `String "Project cards");
                 ];
             ] );
         ("selectedUuid", string_field host.deck_selected);
         ( "totalCards"
         , `Int (if host.deck_completed then 0 else List.length host.flashcards) );
         ("completed", `Bool host.deck_completed);
         ("createdUuid", string_field host.deck_created);
         ( "targetSearch"
         , `Assoc
             [
               ("kind", `String "page");
               ("query", `String "");
               ( "items"
               , `List
                   (List.map
                      (fun (uuid, title) ->
                        `Assoc
                          [ ("uuid", `String uuid); ("title", `String title) ])
                      host.deck_targets) );
             ] );
       ])

let project host ~graph_id ~graph_name ~encrypted ~unlocked ?rows ?sidebar
    ?flashcards ?sync_connected ?node_routes ?selected_block_ids ?task_statuses
    graphs =
  graph_projection ~graph_id ~graph_name ~encrypted ~unlocked ?rows ?sidebar
    ?flashcards ?sync_connected ?node_routes ?selected_block_ids ?task_statuses
    ~has_older_journals:host.has_older ~decks_json:(decks_json host) graphs

let page_title host uuid fallback =
  match
    List.find_opt
      (fun (page : Model.sidebar_page) -> page.uuid = uuid)
      (host.favorites @ host.recents
      @ Option.to_list host.selected_page)
  with
  | Some page -> page.title
  | None -> fallback

let remember_page host uuid =
  let page = { Model.uuid; title = page_title host uuid uuid } in
  host.selected_page <- Some page;
  page

let append_capture host id title ?status ?(tags = []) () =
  let row =
    App_test.journal_outline_row (Printf.sprintf "capture-%d" id) "journal"
      title "Today" 20260828 (List.length host.rows)
  in
  let row =
    match status with None -> row | Some status -> { row with row_status = Some status }
  in
  host.rows <- host.rows @ [ { row with tags } ]

let editing_snapshot ~uuid ~title ~caret ?(autocomplete = None) ?(candidates = [])
    projection =
  {
    projection with
    Model.projection_outliner_editing =
      Some
        {
          Model.editing_uuid = uuid;
          editing_title = title;
          caret_utf16_offset = caret;
        };
    projection_outliner_autocomplete = autocomplete;
    projection_outliner_autocomplete_candidates = candidates;
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
         (project host ~graph_id:g.id ~graph_name:g.name ~encrypted:g.is_encrypted
            ~unlocked:(not g.is_encrypted) ~rows:host.rows
            ~sidebar:(host_sidebar host) ~flashcards:host.flashcards
            ~task_statuses:host.task_statuses ~sync_connected:true host.graphs))
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
        let snapshot =
          match
            Option.map
              (fun graph_id ->
                List.find_opt
                  (fun (g : Model.graph) -> g.id = graph_id)
                  host.graphs)
              model.Model.selected_graph_id
            |> Option.join
          with
          | Some _ -> current_graph_projection host model ~extra:(fun projection -> projection)
          | None -> Model.ApplyCoreSnapshot (catalog_projection host.graphs)
        in
        Model.DequeueEffect id
        :: Model.ApplyLocalGraphIds
             (List.map (fun (g : Model.graph) -> g.id) host.graphs)
        :: snapshot
        :: resolved
      | Model.CreateGraphEffect (id, name, encrypted, _password) ->
        let graph = graph_entry name name encrypted in
        host.graphs <- host.graphs @ [ graph ];
        Model.DequeueEffect id
        :: Model.ApplyLocalGraphIds
             (List.map (fun (g : Model.graph) -> g.id) host.graphs)
        :: Model.ApplyCoreSnapshot
             (project host ~graph_id:name ~graph_name:name ~encrypted
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
      | Model.SignInEffect (id, _) ->
        if host.fail_sign_in then
          [Model.DequeueEffect id; Model.ResolveEffect (id, true, "{\"__type\":\"NotAuthorizedException\"}")]
        else
          [Model.DequeueEffect id;
           Model.ApplyLocalGraphIds (List.map (fun (g : Model.graph) -> g.id) host.graphs);
           Model.ApplyCoreSnapshot (catalog_projection host.graphs);
           Model.ResolveEffect (id, true, "{\"signedIn\":true}")]
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
        append_capture host id title ();
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.SendTaskEffect (id, title, status) ->
        append_capture host id title ~status ();
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.SendTaggedCaptureEffect (id, submission) ->
        append_capture host id submission.Model.capture_text
          ?status:submission.capture_status ~tags:submission.capture_tags ();
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.AddRootBlockEffect (id, _page_uuid) ->
        append_capture host id "New block" ();
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.SetPageFavoriteEffect (id, uuid, favored) ->
        host.favorites <-
          (if favored then
             host.favorites
             @ [ { Model.uuid; title = page_title host uuid uuid } ]
           else
             List.filter
               (fun (page : Model.sidebar_page) -> page.uuid <> uuid)
               host.favorites);
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.SelectSidebarPageEffect (id, uuid) ->
        let page = remember_page host uuid in
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               {
                 projection with
                 Model.sidebar =
                   {
                     (host_sidebar host) with
                     selected_page = Some page;
                     linked_reference_rows = host.rows;
                   };
               })
        :: resolved
      | Model.ClearSelectedPageEffect id ->
        host.selected_page <- None;
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.DeletePageEffect (id, uuid) ->
        let drop pages =
          List.filter (fun (page : Model.sidebar_page) -> page.uuid <> uuid) pages
        in
        host.favorites <- drop host.favorites;
        host.recents <- drop host.recents;
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.DeleteBlockEffect (id, uuid, _) ->
        host.rows <-
          List.filter (fun (row : Model.outline_row) -> row.row_uuid <> uuid) host.rows;
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               {
                 projection with
                 Model.projection_outliner_selected_block_ids = [];
               })
        :: resolved
      | Model.LoadOlderJournalsEffect id ->
        append_capture host id "Older journal note" ();
        host.has_older <- false;
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.ReviewFlashcardEffect (id, uuid, _rating) ->
        host.flashcards <-
          List.filter
            (fun (card : Model.flashcard) -> card.flashcard_uuid <> uuid)
            host.flashcards;
        host.deck_completed <- host.flashcards = [];
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.FlashcardDeckEffect (id, payload) ->
        let fields = json_fields payload in
        (match json_string fields "action" with
         | Some "select" -> host.deck_selected <- json_string fields "uuid"
         | Some "search" ->
           host.deck_targets <- [ ("page-1", "Alpha Doc") ]
         | Some "create" -> host.deck_created <- Some "deck-created"
         | Some "practice" ->
           host.deck_completed <- false;
           host.flashcards <- [ flashcard_seed ]
         | _ -> ());
        Model.DequeueEffect id
        :: current_graph_projection host model ~extra:(fun projection ->
               projection)
        :: resolved
      | Model.LoadComposerTagsEffect (id, _) ->
        Model.DequeueEffect id
        :: Model.ApplyCoreSnapshot
             {
               (catalog_projection host.graphs) with
               Model.selected_graph_id = model.Model.selected_graph_id;
               tag_choices_update = Some tag_choices;
             }
        :: resolved
      | Model.LoadPropertyValuesEffect (id, key, _) ->
        Model.DequeueEffect id
        :: Model.ReceivePropertyValues
             ( key
             , Yojson.Basic.to_string
                 (`Assoc
                    [
                      ("attr", `String "block/tags");
                      ("valuesDeferred", `Bool false);
                      ( "filterValues"
                      , `List
                          (List.map
                             (fun (tag : Model.sidebar_page) ->
                               `Assoc
                                 [
                                   ("title", `String tag.title);
                                   ("match", `List [ `String tag.uuid ]);
                                 ])
                             tag_choices) );
                    ]) )
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
        let autocomplete =
          if action = "pageReference" then
            Some
              {
                Model.autocomplete_kind = Model.NodeAutocomplete;
                autocomplete_query = "";
              }
          else if action = "tag" then
            Some
              {
                Model.autocomplete_kind = Model.TagAutocomplete;
                autocomplete_query = "";
              }
          else None
        in
        if action = "unselect" || Option.is_some autocomplete then
          Model.DequeueEffect id
          :: current_graph_projection host model ~extra:(fun projection ->
                 let projection =
                   if action = "unselect" then
                     {
                       projection with
                       Model.projection_outliner_selected_block_ids = [];
                     }
                   else projection
                 in
                 match (model.Model.outliner_editing, autocomplete) with
                 | Some editing, Some request ->
                   editing_snapshot ~uuid:editing.editing_uuid
                     ~title:editing.editing_title
                     ~caret:editing.caret_utf16_offset
                     ~autocomplete:(Some request) ~candidates:[ page_candidate ]
                     projection
                 | _ -> projection)
          :: resolved
        else resolved
      | Model.ChooseOutlinerAutocompleteEffect (id, _) -> (
        match model.Model.outliner_editing with
        | Some editing ->
          let title = "[[Alpha Doc]]" in
          host.rows <-
            List.map
              (fun (row : Model.outline_row) ->
                if row.row_uuid = editing.editing_uuid then
                  { row with row_title = title }
                else row)
              host.rows;
          Model.DequeueEffect id
          :: current_graph_projection host model ~extra:(fun projection ->
                 editing_snapshot ~uuid:editing.editing_uuid ~title
                   ~caret:(String.length title) projection)
          :: resolved
        | None -> Model.DequeueEffect id :: resolved)
      | Model.EditorOutlinerEventEffect (id, payload) -> (
        match (json_string (json_fields payload) "type", model.Model.outliner_editing) with
        | Some "dismissAutocomplete", Some editing ->
          Model.DequeueEffect id
          :: current_graph_projection host model ~extra:(fun projection ->
                 editing_snapshot ~uuid:editing.editing_uuid
                   ~title:editing.editing_title
                   ~caret:editing.caret_utf16_offset projection)
          :: resolved
        | _ ->
          [
            Model.DequeueEffect id;
            Model.ResolveEffect (id, true, "");
          ])
      | Model.ReportErrorEffect (id, message) ->
        host.runtime_log <- { Model.id = "error-" ^ string_of_int id; level = "ERROR";
          source = "ui"; timestamp = "Now"; message } :: host.runtime_log;
        Model.DequeueEffect id :: resolved
      | Model.RefreshRuntimeLogEffect (id, _, errors_only, _) ->
        let records =
          if errors_only then
            List.filter
              (fun (record : Model.runtime_log_record) ->
                String.lowercase_ascii record.level = "error")
              host.runtime_log
          else host.runtime_log
        in
        Model.DequeueEffect id
        :: Model.ApplyRuntimeLog (records, None)
        :: resolved
      | Model.TapOutlinerBlockEffect (id, uuid) -> (
        match
          Option.map find_graph model.Model.selected_graph_id |> Option.join
        with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               (editing_snapshot ~uuid ~title:"" ~caret:0
                  (project host ~graph_id:g.id ~graph_name:g.name
                     ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
                     ~rows:host.rows ~sidebar:(host_sidebar host)
                     ~flashcards:host.flashcards host.graphs))
          :: resolved
        | None -> Model.DequeueEffect id :: resolved)
      | Model.OpenGraphEffect (id, graph_id) -> (
        match find_graph graph_id with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               (project host ~graph_id:g.id ~graph_name:g.name
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
               (project host ~graph_id:g.id ~graph_name:g.name
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
          let referencing = contains_substr title "[[" in
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               (editing_snapshot ~uuid ~title ~caret
                  ~autocomplete:
                    (if referencing then
                       Some
                         {
                           Model.autocomplete_kind = Model.NodeAutocomplete;
                           autocomplete_query = "Al";
                         }
                     else None)
                  ~candidates:(if referencing then [ page_candidate ] else [])
                  (project host ~graph_id:g.id ~graph_name:g.name
                     ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
                     ~rows:host.rows ~sidebar:(host_sidebar host)
                     ~flashcards:host.flashcards host.graphs))
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
               (project host ~graph_id:g.id ~graph_name:g.name
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
    ?(rows = journal_rows) ?(has_older = false) () =
  let host =
    {
      graphs = [];
      rows;
      flashcards = [ flashcard_seed ];
      favorites = [ { Model.uuid = "fav-1"; title = "Favorite Doc" } ];
      recents = [ { Model.uuid = "recent-1"; title = "Recent Doc" } ];
      selected_page = None;
      runtime_log = runtime_log_seed;
      task_statuses =
        [
          App_test.task_status "ts-1" (Some "todo") "Todo"
            (Some "tabler-icon") (Some "Todo") (Some "blue");
        ];
      fail_sign_in;
      has_older;
      deck_selected = None;
      deck_completed = false;
      deck_created = None;
      deck_targets = [];
    }
  in
  let self = ref None in
  let drain () =
    match !self with
    | None -> []
    | Some s -> host_responses host (Drive.Session.read_model s)
  in
  let initial =
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

let has_prefix prefix name =
  let length = String.length prefix in
  String.length name >= length && String.sub name 0 length = prefix

let run_scenario name () =
  let authentication =
    if has_prefix "auth-" name then "signedOut" else "signedIn"
  in
  let fail_sign_in = name = "auth-signin-error.drive" in
  let rows = if has_prefix "empty-" name then [] else journal_rows in
  let has_older = has_prefix "history-" name in
  let session =
    mount ~profile:(ios_profile ()) ~authentication ~fail_sign_in ~rows
      ~has_older ()
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
