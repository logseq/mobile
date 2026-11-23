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

let priority_seed =
  [
    App_test.task_status "pri-1" (Some "logseq.property/priority.high") "High"
      None (Some "priorityLvlHigh") None;
  ]

let default_settings =
  {
    Model.appearance = "system";
    dark_theme = "black";
    language = "system";
    system_language = Some "en";
    spell_check = true;
    auto_correction = true;
    sidebar_tabs = [ "journals"; "flashcards"; "graphs" ];
    graph_quick_slots = [];
    base_url = "https://api.logseq.io";
    version = "Development";
    revision = "Development";
  }

let calendar_journal_day = App_test.journal_test_year () * 10000 + 827
let calendar_journal = "journal-" ^ string_of_int calendar_journal_day

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

let json_assoc fields key =
  match List.assoc_opt key fields with Some (`Assoc value) -> value | _ -> []

let json_strings fields key =
  match List.assoc_opt key fields with
  | Some (`List values) ->
    List.filter_map (function `String value -> Some value | _ -> None) values
  | _ -> []

let graph_projection ~graph_id ~graph_name ~encrypted ~unlocked ?(rows = journal_rows)
    ?sidebar ?(flashcards = []) ?(sync_connected = false) ?(node_routes = [])
    ?(selected_block_ids = []) ?(task_statuses = [])
    ?(task_priorities = priority_seed) ?(has_older_journals = false)
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
    task_priorities;
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
  ; mutable deck_practicing : bool
  ; mutable deck_total : int option
  ; mutable deck_search_kind : string
  ; mutable deck_search_query : string
  ; mutable removed_blocks : string list
  ; mutable completion_dismissed : bool
  ; mutable editing_title : string
  ; mutable saved_settings : Model.settings_projection option
  ; mutable property_done : bool
  ; mutable page_tags : bool
  ; mutable schema_attrs : string list
  ; mutable query_expanded : bool
  ; mutable query_filters : Yojson.Basic.t option
  ; mutable query_sorting : Yojson.Basic.t option
  ; mutable query_type : string
  ; mutable scenario : string
  }

let property_json ~attr ~title ~kind ~text ~raw =
  `Assoc
    [
      ("attr", `String attr);
      ("title", `String title);
      ("kind", `String kind);
      ("editable", `Bool true);
      ("text", `String text);
      ("raw", raw);
    ]

let page_properties host (page : Model.sidebar_page) =
  let properties =
    [ property_json ~attr:"done" ~title:"Done" ~kind:"checkbox"
        ~text:(if host.property_done then "Yes" else "No")
        ~raw:(`Assoc [ ("type", `String "boolean"); ("value", `Bool host.property_done) ]) ]
    @
    if host.page_tags then
      [ property_json ~attr:"tags" ~title:"Tags" ~kind:"ref" ~text:"Project"
          ~raw:(`Assoc [ ("type", `String "set"); ("value", `List [ `String "tag-1" ]) ]) ]
    else []
  in
  Yojson.Basic.to_string
    (`Assoc
       [
         ("ownerUuid", `String page.uuid);
         ("canAdd", `Bool true);
         ("classSchema", `Bool true);
         ( "rename"
         , `Assoc
             [
               ("attr", `String "block/title");
               ("editable", `Bool true);
               ("title", `String "Title");
               ("text", `String page.title);
               ("editorValue", `String page.title);
               ( "raw"
               , `Assoc [ ("type", `String "string"); ("value", `String page.title) ] );
             ] );
         ( "tagPicker"
         , `Assoc
             [
               ("attr", `String "block/tags");
               ("title", `String "Tags");
               ("kind", `String "ref");
               ("many", `Bool true);
               ("ref", `Bool true);
               ("valuesDeferred", `Bool false);
               ( "filterValues"
               , `List
                   [
                     `Assoc
                       [
                         ("title", `String "Project");
                         ("match", `List [ `String "tag-1" ]);
                       ];
                   ] );
             ] );
         ( "schemaProperties"
         , `List
             (List.map
                (fun attr -> `Assoc [ ("attr", `String attr); ("title", `String "Alias") ])
                host.schema_attrs) );
         ( "availableProperties"
         , `List
             [
               `Assoc
                 [
                   ("attr", `String "alias");
                   ("title", `String "Alias");
                   ("kind", `String "default");
                 ];
             ] );
         ("properties", `List properties);
       ])

let host_sidebar host =
  {
    (App_test.empty_sidebar_projection ()) with
    Model.favorites = host.favorites;
    recent_pages = host.recents;
    selected_page = host.selected_page;
    properties_json =
      (match host.selected_page with
      | None -> ""
      | Some page -> page_properties host page);
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
         , `Int
             (match host.deck_total with
             | Some count -> count
             | None -> if host.deck_completed then 0 else List.length host.flashcards) );
         ("completed", `Bool host.deck_completed);
         ("practicing", `Bool host.deck_practicing);
         ("createdUuid", string_field host.deck_created);
         ( "targetSearch"
         , `Assoc
             [
               ("kind", `String host.deck_search_kind);
               ("query", `String host.deck_search_query);
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
      "Older journal note" (Journal.day_title calendar_journal_day) calendar_journal_day 0
  in
  host.rows <- row :: host.rows

let append_capture host id title ?status ?(tags = []) ?uuid () =
  let row_uuid =
    match uuid with Some uuid -> uuid | None -> Printf.sprintf "capture-%d" id
  in
  let row =
    App_test.journal_outline_row row_uuid "journal" title "Today" 20260828
      (List.length host.rows)
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
          editing_is_task = None;
          editing_title = title;
          caret_utf16_offset = caret;
        };
    projection_outliner_autocomplete = autocomplete;
    projection_outliner_autocomplete_candidates = candidates;
  }

let rename_page host uuid title =
  let update (page : Model.sidebar_page) =
    if page.uuid = uuid then { page with title } else page
  in
  host.favorites <- List.map update host.favorites;
  host.recents <- List.map update host.recents;
  host.selected_page <- Option.map update host.selected_page

let map_row host uuid f =
  host.rows <-
    List.map
      (fun (row : Model.outline_row) -> if row.row_uuid = uuid then f row else row)
      host.rows

let query_document ?(view_type = "list") ?filters ?sorting expanded =
  let view_fields =
    [
      ("uuid", `String "view-1");
      ("type", `String view_type);
      ("name", `String "All");
      ("rowsDeferred", `Bool true);
      ("rowCount", `Int 1);
      ("rowOffset", `Int 0);
      ("rows", `List []);
      ("input", `String "");
      ("revision", `String "1");
      ("projectionRevision", `String "1");
    ]
    @ (match filters with Some filters -> [ ("filters", filters) ] | None -> [])
    @ (match sorting with Some sorting -> [ ("sorting", sorting) ] | None -> [])
  in
  `Assoc
    [
      ("ownerUuid", `String "query-block");
      ("featureType", `String "query-result");
      ("expanded", `Bool expanded);
      ("views", `List [ `Assoc view_fields ]);
    ]

let query_json expanded = Yojson.Basic.to_string (query_document expanded)

let query_row expanded =
  let row =
    App_test.journal_outline_row "query-block" "journal" "Query block" "Today" 20260828 2
  in
  { row with Model.query_json = query_json expanded }

let pdf_row =
  let row =
    App_test.journal_outline_row "pdf-1" "journal" "Notes.pdf" "Today" 20260828 2
  in
  {
    row with
    Model.is_asset = true;
    asset_type = Some "pdf";
    local_path = Some "/tmp/Notes.pdf";
  }

let code_row =
  let row =
    App_test.journal_outline_row "code-1" "journal" "let x = 1" "Today" 20260828 0
  in
  { row with Model.row_display_type = Some "code" }

let tag_row (row : Model.outline_row) =
  if row.row_uuid = "journal-block-1" then
    { row with tags = [ { Model.uuid = "tag-1"; title = "Project" } ] }
  else row

let failed_sync_row (row : Model.outline_row) =
  if row.row_uuid = "journal-block-1" then
    { row with sync_status = Some "failed" }
  else row

let live_query_json host =
  Yojson.Basic.to_string
    (query_document ~view_type:host.query_type ?filters:host.query_filters
       ?sorting:host.query_sorting host.query_expanded)

let set_query_expanded host expanded =
  host.query_expanded <- expanded;
  map_row host "query-block" (fun row ->
      { row with Model.query_json = live_query_json host })

let find_graph host id =
  List.find_opt (fun (g : Model.graph) -> g.id = id) host.graphs

let graph_ids host =
  List.filter_map
    (fun (g : Model.graph) -> if g.id = "RemoteGraph" then None else Some g.id)
    host.graphs

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
    ?(rows = journal_rows) ?(has_older = false) ?(flashcards = [ flashcard_seed ])
    ?(deck_total = None) ?(scenario = "") () =
  let host =
    {
      graphs = [];
      rows;
      flashcards;
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
      deck_practicing = false;
      deck_total;
      deck_search_kind = "page";
      deck_search_query = "";
      removed_blocks = [];
      completion_dismissed = false;
      editing_title = "";
      saved_settings = None;
      property_done = false;
      page_tags = false;
      schema_attrs = [];
      query_expanded = false;
      query_filters = None;
      query_sorting = None;
      query_type = "list";
      scenario;
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
  let rows =
    let rows = if has_prefix "empty-" name then [] else journal_rows in
    let rows = if has_prefix "query-" name then rows @ [ query_row false ] else rows in
    let rows = if has_prefix "pdf-" name then rows @ [ pdf_row ] else rows in
    let rows = if has_prefix "code-" name then rows @ [ code_row ] else rows in
    let rows = if has_prefix "tag-" name then List.map tag_row rows else rows in
    if has_prefix "sync-row-" name then List.map failed_sync_row rows else rows
  in
  let has_older = has_prefix "history-" name in
  let flashcards, deck_total =
    if has_prefix "nocards-" name then ([], Some 0)
    else if has_prefix "practice-" name then ([], Some 3)
    else ([ flashcard_seed ], None)
  in
  let session =
    mount ~profile:(ios_profile ()) ~authentication ~fail_sign_in ~rows
      ~has_older ~flashcards ~deck_total ~scenario:name ()
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
