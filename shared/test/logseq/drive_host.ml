(* Shared headless drive session. Each feature module registers the effects
   it owns and replays the scripts in its own directory under logseq/drive/. *)

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

let search_block =
  App_test.journal_outline_row "block-1" "page-1" "alpha block" "Today" 20260828 0

let default_settings =
  {
    Model.appearance = "system";
    dark_theme = "black";
    language = "system";
    system_language = Some "en";
    spell_check = true;
    auto_correction = true;
    sidebar_tabs = [ "journals"; "flashcards"; "graphs" ];
    base_url = "https://api.logseq.io";
    version = "Development";
    revision = "Development";
  }

let calendar_journal = "journal-20260827"

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
  ; mutable deck_items : (string * string) list
  ; mutable removed_blocks : string list
  ; mutable completion_dismissed : bool
  ; mutable editing_title : string
  ; mutable saved_settings : Model.settings_projection option
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
             (List.map
                (fun (uuid, title) ->
                  `Assoc [ ("uuid", `String uuid); ("title", `String title) ])
                host.deck_items) );
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

let search_hits host =
  List.filter
    (fun (hit : Model.search_hit) -> not (List.mem hit.hit_uuid host.removed_blocks))
    [
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
    ]

let node_rows host uuid =
  if uuid = search_block.row_uuid && not (List.mem uuid host.removed_blocks) then
    host.rows @ [ search_block ]
  else host.rows

let append_older_journal host id =
  let row =
    App_test.journal_outline_row (Printf.sprintf "older-%d" id) "journal-older"
      "Older journal note" "Aug 27th, 2026" 20260827 0
  in
  host.rows <- row :: host.rows

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

let find_graph host id =
  List.find_opt (fun (g : Model.graph) -> g.id = id) host.graphs

let graph_ids host =
  List.map (fun (g : Model.graph) -> g.id) host.graphs

let current_graph_projection host model ~extra =
  match Option.map (find_graph host) model.Model.selected_graph_id |> Option.join with
  | Some g ->
    Model.ApplyCoreSnapshot
      (extra
         (project host ~graph_id:g.id ~graph_name:g.name ~encrypted:g.is_encrypted
            ~unlocked:(not g.is_encrypted) ~rows:host.rows
            ~sidebar:(host_sidebar host) ~flashcards:host.flashcards
            ~task_statuses:host.task_statuses ~sync_connected:true host.graphs))
  | None -> Model.ApplyCoreSnapshot (catalog_projection host.graphs)

let resolved id = [ Model.ResolveEffect (id, true, "") ]

type handler =
  host -> Model.logseq_model -> Model.logseq_effect -> Model.logseq_action list option

let handlers : handler list ref = ref []

let register handler = handlers := !handlers @ [ handler ]

let fallback eff =
  [
    Model.DequeueEffect (Model.effect_id eff);
    Model.ResolveEffect (Model.effect_id eff, true, "");
  ]

let respond host model eff =
  match List.find_map (fun handler -> handler host model eff) !handlers with
  | Some actions -> actions
  | None -> fallback eff

let host_responses host model =
  List.concat_map (respond host model) model.Model.pending_effects

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
      deck_items = [ ("deck-1", "Project cards") ];
      removed_blocks = [];
      completion_dismissed = false;
      editing_title = "";
      saved_settings = None;
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

let scenario_names dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".drive")
  |> List.sort String.compare

let has_prefix prefix name =
  let length = String.length prefix in
  String.length name >= length && String.sub name 0 length = prefix

let run_scenario dir name () =
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
      (read_file (Filename.concat dir name))
  in
  Drive.Session.dispose session;
  let messages =
    List.map
      (fun (f : Drive.Scenario.failure) ->
        Printf.sprintf "line %d: %s" f.line f.message)
      failures
  in
  Alcotest.(check (list string)) name [] messages

let cases dir =
  List.map
    (fun name -> Alcotest.test_case name `Quick (run_scenario dir name))
    (scenario_names dir)
