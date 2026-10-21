open Test_util
open Model

let decoded input =
  match Response_snapshot.decode_response input with
  | Ok projection -> projection
  | Error message -> failwith message

let invalid_envelopes_preserve_errors () =
  List.iter
    (fun (input, expected) ->
       match Response_snapshot.decode_response input with
       | Error message -> check_eq expected message
       | Ok _ -> check ~msg:"invalid envelope was accepted" false)
    [
      ("[]", "Core response must be a JSON object");
      ("{\"ok\":true}", "Core response did not contain a snapshot");
      ("{\"ok\":true,\"result\":null}", "Core response did not contain a snapshot");
      ("{\"ok\":false,\"error\":null}", "core_request_failed\nCore request failed");
      ( "{\"apiVersion\":1,\"ok\":false,\"error\":{\"code\":\"graph_discovery_failed\",\"message\":\"Connection refused\"}}"
      , "graph_discovery_failed\nConnection refused" );
    ];
  match Response_snapshot.decode_response "{" with
  | Error message ->
    check (String.starts_with ~prefix:"Invalid core response: " message)
  | Ok _ -> check ~msg:"malformed JSON was accepted" false

let empty_route_and_legacy_boundaries () =
  let projection =
    decoded
      "{\"ok\":true,\"result\":{\"graphName\":\"first\",\"graphName\":\"second\",\"outlinerState\":{\"editing\":{\"uuid\":\"base\",\"title\":\"Base\",\"caretUTF16Offset\":2},\"selectedBlockIds\":[\"base\"]},\"nodeRoutes\":[{\"uuid\":\"empty\",\"outlinerRows\":[]}],\"outlinerAutocompleteCandidates\":[null,{\"label\":\"Good\",\"value\":\"good\"}],\"outlinerRows\":[{\"depth\":0,\"block\":{\"uuid\":\"base\",\"title\":\"Base\",\"markup\":null}}],\"flashcards\":[{\"block\":{\"uuid\":\"card\",\"title\":\"{{CLOZE answer}} {{unknown x}} {{cloze unfinished\"},\"children\":[null,{\"uuid\":\"answer\",\"title\":\"Answer\"}]}]}}"
  in
  let card = List.nth projection.flashcards 0 in
  check_eq (Some "first") projection.graph_name;
  check_eq [] projection.outliner_rows;
  check (projection.projection_outliner_editing = None);
  check_eq [] projection.projection_outliner_selected_block_ids;
  check_eq "null"
    (List.nth projection.journal_outliner_rows 0).markup_json;
  check_eq "[\xE2\x80\xA6] {{unknown x}} {{cloze unfinished" card.question_hidden;
  check_eq "answer {{unknown x}} {{cloze unfinished" card.question_revealed;
  check_eq 0 (List.nth card.answer_rows 0).answer_index

let full_snapshot_retains_search_outliner_and_sync () =
  let projection =
    decoded
      "{\"apiVersion\":1,\"ok\":true,\"result\":{\"graphName\":\"Work\",\"searchQuery\":\"project\",\"searchResults\":[{\"uuid\":\"page-a\",\"title\":\"Project Alpha\",\"isPage\":true,\"page\":null,\"breadcrumbs\":[]},{\"uuid\":\"block-a\",\"title\":\"Project note\",\"isPage\":false,\"page\":{\"uuid\":\"page-a\",\"title\":\"Project Alpha\"},\"breadcrumbs\":[{\"uuid\":\"parent-a\",\"title\":\"Parent\"}]}],\"outlinerState\":{\"editing\":{\"uuid\":\"outline-a\",\"title\":\"Nested note\",\"caretUTF16Offset\":6},\"selectedBlockIds\":[\"outline-a\"],\"autocomplete\":{\"kind\":\"node\",\"query\":\"Pro\"}},\"outlinerAutocompleteCandidates\":[{\"label\":\"Project Alpha\",\"value\":\"page-a\"}],\"outlinerRows\":[{\"block\":{\"uuid\":\"outline-a\",\"title\":\"Nested note\",\"pageId\":\"journal-a\",\"journalTitle\":\"August 27th, 2026\",\"journalDay\":20260827},\"depth\":2,\"hasChildren\":true,\"isCollapsed\":false}],\"hasOlderJournals\":true,\"appliedServerT\":42,\"hasPendingSemanticOperations\":true,\"pendingSyncRequest\":{\"id\":7},\"syncConnected\":true}}"
  in
  let results = projection.search_results in
  let page = List.nth results 0 in
  let block = List.nth results 1 in
  let rows = projection.outliner_rows in
  let row = List.nth rows 0 in
  check_eq (Some "Work") projection.graph_name;
  check_eq "project" projection.projection_search_query;
  check projection.sync_connected;
  check_eq (Some 42) projection.applied_server_t;
  check projection.has_pending_semantic_operations;
  check projection.has_pending_sync_request;
  check projection.has_older_journals;
  check_eq 2 (List.length results);
  check_eq "page-a" page.hit_uuid;
  check page.is_page;
  check_eq "Parent" block.breadcrumb;
  check_eq [ [ "parent-a"; "Parent" ] ]
    (List.map
       (fun (entry : sidebar_page) -> [ entry.uuid; entry.title ])
       block.breadcrumbs);
  check_eq 1 (List.length rows);
  check_eq "outline-a" row.row_uuid;
  check_eq "Nested note" row.row_title;
  check_eq "journal-a" row.page_id;
  check_eq (Some "August 27th, 2026") row.journal_title;
  check_eq (Some 20260827) row.journal_day;
  check_eq 2 row.depth;
  check row.has_children;
  check (not row.is_collapsed);
  (match projection.projection_outliner_editing with
   | Some editing ->
     check_eq "outline-a" editing.editing_uuid;
     check_eq "Nested note" editing.editing_title;
     check_eq 6 editing.caret_utf16_offset
   | None -> check ~msg:"missing editor" false);
  check (not projection.is_outliner_patch);
  check_eq [ "outline-a" ] projection.projection_outliner_selected_block_ids;
  (match projection.projection_outliner_autocomplete with
   | Some autocomplete ->
     check_eq NodeAutocomplete autocomplete.autocomplete_kind;
     check_eq "Pro" autocomplete.autocomplete_query
   | None -> check ~msg:"missing autocomplete" false);
  check_eq 1
    (List.length projection.projection_outliner_autocomplete_candidates);
  let candidate =
    List.nth projection.projection_outliner_autocomplete_candidates 0
  in
  check_eq "Project Alpha" candidate.candidate_label;
  check_eq "page-a" candidate.candidate_value;
  check_eq 0 candidate.candidate_index

let patch_identities () =
  check
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"revision\":2,\"blocks\":[],\"pendingSyncRequest\":null,\"hasPendingSemanticOperations\":false,\"isPendingSyncPatch\":true}}")
      .is_pending_sync_patch;
  check
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"graphs\":[],\"isGraphCatalogPatch\":true}}")
      .is_graph_catalog_patch

let active_route_becomes_outliner_surface () =
  let projection =
    decoded
      "{\"apiVersion\":1,\"ok\":true,\"result\":{\"graphName\":\"Work\",\"outlinerState\":{\"editing\":null},\"outlinerRows\":[{\"block\":{\"uuid\":\"base\",\"title\":\"Base\"},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false}],\"nodeRoutes\":[{\"uuid\":\"node-a\",\"isTag\":false,\"isProperty\":false,\"page\":{\"uuid\":\"page-a\",\"title\":\"Project\"},\"outlinerState\":{\"editing\":{\"uuid\":\"child\",\"title\":\"Child\",\"caretUTF16Offset\":5},\"selectedBlockIds\":[],\"autocomplete\":null},\"outlinerAutocompleteCandidates\":[],\"outlinerRows\":[{\"block\":{\"uuid\":\"child\",\"title\":\"Child\"},\"depth\":1,\"hasChildren\":false,\"isCollapsed\":false}]}],\"syncConnected\":true}}"
  in
  check_eq [ [ "node-a"; "Project" ] ]
    (List.map
       (fun (route : node_projection) -> [ route.node_uuid; route.node_title ])
       projection.node_routes);
  check_eq [ "child" ]
    (List.map (fun (row : outline_row) -> row.row_uuid) projection.outliner_rows);
  check_eq (Some "child")
    (Option.map
       (fun (editing : outliner_editing) -> editing.editing_uuid)
       projection.projection_outliner_editing)

let rich_markup_and_cross_block_youtube_target () =
  let rows =
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerState\":{\"editing\":null},\"outlinerRows\":[{\"block\":{\"uuid\":\"video\",\"title\":\"{{youtube dQw4w9WgXcQ}}\",\"markup\":[{\"type\":\"video\",\"url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}]},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false},{\"block\":{\"uuid\":\"timestamp\",\"title\":\"{{youtube-timestamp 01:23}}\",\"markup\":[{\"type\":\"youtubeTimestamp\",\"text\":\"01:23\",\"style\":\"83\"}]},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false,\"youtubeTargetURL\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}],\"syncConnected\":true}}")
      .outliner_rows
  in
  check_eq 2 (List.length rows);
  check_eq
    "[{\"type\":\"video\",\"url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}]"
    (List.nth rows 0).markup_json;
  check_eq (Some "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    (List.nth rows 1).youtube_target_url

let asset_status_and_deduplicated_trailing_tags () =
  let rows =
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerState\":{\"editing\":null},\"outlinerRows\":[{\"block\":{\"uuid\":\"asset-a\",\"title\":\"Photo.jpg\",\"markup\":[{\"type\":\"emphasis\",\"style\":\"bold\",\"children\":[{\"type\":\"tagReference\",\"uuid\":\"tag-a\",\"title\":\"Project\"}]}],\"isAsset\":true,\"assetType\":\"image/jpeg\",\"localPath\":\"Assets/Photo.jpg\",\"syncStatus\":\"failed\",\"tags\":[{\"uuid\":\"tag-a\",\"title\":\"Project\"},{\"uuid\":\"tag-b\",\"title\":\"Trailing\"},{\"uuid\":\"tag-b\",\"title\":\"Trailing\"}],\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\",\"icon\":{\"type\":\"tabler-icon\",\"id\":\"Todo\"}}},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false}],\"syncConnected\":true}}")
      .outliner_rows
  in
  let row = List.nth rows 0 in
  check_eq 1 (List.length rows);
  check row.is_asset;
  check_eq (Some "image/jpeg") row.asset_type;
  check_eq (Some "Assets/Photo.jpg") row.local_path;
  check_eq (Some "failed") row.sync_status;
  check_eq [ [ "tag-b"; "Trailing" ] ]
    (List.map (fun (tag : sidebar_page) -> [ tag.uuid; tag.title ]) row.tags);
  check_eq (Some "todo")
    (Option.map (fun (status : task_status) -> status.uuid) row.row_status)

let related_page_navigation_and_breadcrumb_identity () =
  let routes =
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerState\":{\"editing\":null},\"nodeRoutes\":[{\"uuid\":\"tag-a\",\"isTag\":true,\"isProperty\":false,\"page\":{\"uuid\":\"tag-a\",\"title\":\"Project\"},\"blocks\":[],\"relatedBlocks\":[{\"uuid\":\"page-object\",\"title\":\"Tagged page\",\"pageId\":\"page-object\",\"breadcrumbs\":[{\"uuid\":\"journal\",\"title\":\"Journal\"}],\"markup\":[]}],\"linkedReferenceBlocks\":[{\"uuid\":\"linked\",\"title\":\"Linked block\",\"pageId\":\"journal\",\"breadcrumbs\":[],\"markup\":[]}],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"outlinerAutocompleteCandidates\":[]}],\"syncConnected\":true}}")
      .node_routes
  in
  let route = List.nth routes 0 in
  let related = route.node_related_rows in
  let linked = route.node_linked_reference_rows in
  let row = List.nth related 0 in
  check_eq 1 (List.length routes);
  check_eq 1 (List.length related);
  check_eq 1 (List.length linked);
  check row.opens_as_page;
  check_eq "Journal" row.row_breadcrumb;
  check_eq [ [ "journal"; "Journal" ] ]
    (List.map
       (fun (entry : sidebar_page) -> [ entry.uuid; entry.title ])
       row.row_breadcrumbs);
  check_eq "linked" (List.nth linked 0).row_uuid

let sidebar_pages_and_related_rows () =
  let sidebar =
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"favorites\":[{\"uuid\":\"page-a\",\"title\":\"Favorite page\"}],\"recentPages\":[{\"uuid\":\"page-b\",\"title\":\"Recent page\"}],\"selectedPage\":{\"uuid\":\"page-a\",\"title\":\"Favorite page\"},\"selectedPageIsTag\":false,\"selectedPageIsProperty\":false,\"relatedBlocks\":[{\"uuid\":\"reference\",\"title\":\"Linked from journal\",\"pageId\":\"journal\",\"breadcrumbs\":[{\"uuid\":\"journal\",\"title\":\"Journal\"}],\"markup\":[]}],\"linkedReferenceBlocks\":[],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}")
      .sidebar
  in
  check_eq [ "page-a" ]
    (List.map (fun (page : sidebar_page) -> page.uuid) sidebar.favorites);
  check_eq [ "page-b" ]
    (List.map (fun (page : sidebar_page) -> page.uuid) sidebar.recent_pages);
  check_eq (Some "page-a")
    (Option.map (fun (page : sidebar_page) -> page.uuid) sidebar.selected_page);
  check_eq [ [ "reference"; "Journal" ] ]
    (List.map
       (fun (row : outline_row) -> [ row.row_uuid; row.row_breadcrumb ])
       sidebar.related_rows)

let rich_flashcard_cloze_and_answers () =
  let cards =
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"flashcards\":[{\"block\":{\"uuid\":\"card-a\",\"title\":\"Remember {{cloze this}}\",\"markup\":[{\"type\":\"text\",\"text\":\"Remember \"},{\"type\":\"cloze\",\"text\":\"this\"}]},\"children\":[{\"uuid\":\"answer-a\",\"title\":\"Child answer\",\"markup\":[{\"type\":\"text\",\"text\":\"Child answer\"}]}],\"due\":1,\"repetitions\":0,\"lapses\":0,\"state\":\"new\"}],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}")
      .flashcards
  in
  let card = List.nth cards 0 in
  check_eq 1 (List.length cards);
  check_eq "card-a" card.flashcard_uuid;
  check_eq "Remember [\xE2\x80\xA6]" card.question_hidden;
  check_eq "Remember this" card.question_revealed;
  check card.has_cloze;
  check_eq 1 (List.length card.answer_rows);
  let answer = List.nth card.answer_rows 0 in
  check_eq "answer-a" answer.answer_uuid;
  check_eq "Child answer" answer.answer_text;
  check_eq 0 answer.answer_index

let legacy_flashcard_cloze () =
  let cards =
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"flashcards\":[{\"block\":{\"uuid\":\"legacy-card\",\"title\":\"Remember {{cloze this}}\"},\"children\":[],\"due\":1,\"repetitions\":0,\"lapses\":0,\"state\":\"new\"}],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}")
      .flashcards
  in
  let card = List.nth cards 0 in
  check_eq 1 (List.length cards);
  check_eq "Remember [\xE2\x80\xA6]" card.question_hidden;
  check_eq "Remember this" card.question_revealed;
  check card.has_cloze

let graph_catalog_flags () =
  let projection =
    decoded
      "{\"apiVersion\":1,\"ok\":true,\"result\":{\"graphName\":\"Local graph\",\"selectedGraphId\":\"local\",\"graphs\":[{\"id\":\"local\",\"name\":\"Local graph\",\"schemaVersion\":\"65.33\",\"isEncrypted\":false,\"isReady\":true},{\"id\":\"remote\",\"name\":\"Remote graph\",\"schemaVersion\":null,\"isEncrypted\":true,\"isReady\":false}],\"isGraphEncrypted\":false,\"isGraphUnlocked\":true,\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}"
  in
  let graphs = projection.graphs in
  let local = List.nth graphs 0 in
  let remote = List.nth graphs 1 in
  check_eq (Some "local") projection.selected_graph_id;
  check (not projection.is_graph_encrypted);
  check projection.is_graph_unlocked;
  check_eq 2 (List.length graphs);
  check_eq "local" local.id;
  check_eq "Local graph" local.name;
  check (not local.is_encrypted);
  check local.is_ready;
  check remote.is_encrypted;
  check (not remote.is_ready)

let task_status_icons () =
  let statuses =
    (decoded
       "{\"apiVersion\":1,\"ok\":true,\"result\":{\"taskStatuses\":[{\"uuid\":\"waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"icon\":{\"type\":\"tabler-icon\",\"id\":\"clock\",\"color\":\"#7c3aed\"}}],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}")
      .task_statuses
  in
  let status = List.nth statuses 0 in
  check_eq 1 (List.length statuses);
  check_eq "waiting" status.uuid;
  check_eq (Some "user.status/waiting") status.ident;
  check_eq "Waiting" status.title;
  check_eq (Some "tabler-icon") status.icon_type;
  check_eq (Some "clock") status.icon_id;
  check_eq (Some "#7c3aed") status.icon_color

let row_splice_bounds_and_content () =
  let projection =
    decoded
      "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerRows\":[],\"outlinerRowSplices\":[{\"start\":0,\"afterBlockId\":null,\"beforeBlockId\":null,\"deleteCount\":2,\"rows\":[{\"block\":{\"uuid\":\"outline-a\",\"title\":\"Nested note\",\"pageId\":\"journal-a\",\"journalTitle\":\"August 27th, 2026\",\"journalDay\":20260827},\"depth\":0,\"hasChildren\":true,\"isCollapsed\":true}]}],\"outlinerState\":{\"editing\":null},\"isOutlinerPatch\":true,\"syncConnected\":false}}"
  in
  let splices = projection.outliner_row_splices in
  let splice = List.nth splices 0 in
  let rows = splice.splice_rows in
  let row = List.nth rows 0 in
  check projection.is_outliner_patch;
  check_eq 1 (List.length splices);
  check_eq (Some 0) splice.splice_start;
  check_eq 2 splice.delete_count;
  check_eq 1 (List.length rows);
  check_eq "outline-a" row.row_uuid;
  check row.is_collapsed;
  check_eq "journal-a" row.page_id;
  check_eq (Some 20260827) row.journal_day

let bounded_block_replacements_hydrate_content_only () =
  let projection = decoded
    "{\"apiVersion\":1,\"ok\":true,\"result\":{\"blocks\":[{\"uuid\":\"outline-a\",\"title\":\"Nested note\",\"pageId\":\"journal-a\",\"syncStatus\":\"pending\",\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\"}}],\"outlinerRows\":[],\"outlinerRowSplices\":[],\"outlinerState\":{\"editing\":null},\"isOutlinerPatch\":true,\"syncConnected\":false}}" in
  check_eq ~msg:"content patches cannot replace hierarchy metadata" projection.outliner_rows [];
  let rows = projection.hydrated_rows in
  let row = List.nth rows 0 in
  check_eq 1 (List.length rows);
  check_eq "outline-a" row.row_uuid;
  check_eq (Some "Todo")
    (Option.map (fun (status : task_status) -> status.title) row.row_status)

let cases =
  [
    case "invalid envelopes preserve errors" invalid_envelopes_preserve_errors;
    case "empty route and legacy boundaries" empty_route_and_legacy_boundaries;
    case "full snapshot retains search outliner and sync"
      full_snapshot_retains_search_outliner_and_sync;
    case "patch identities" patch_identities;
    case "active route becomes outliner surface"
      active_route_becomes_outliner_surface;
    case "rich markup and cross block youtube target"
      rich_markup_and_cross_block_youtube_target;
    case "asset status and deduplicated trailing tags"
      asset_status_and_deduplicated_trailing_tags;
    case "related page navigation and breadcrumb identity"
      related_page_navigation_and_breadcrumb_identity;
    case "sidebar pages and related rows" sidebar_pages_and_related_rows;
    case "rich flashcard cloze and answers" rich_flashcard_cloze_and_answers;
    case "legacy flashcard cloze" legacy_flashcard_cloze;
    case "graph catalog flags" graph_catalog_flags;
    case "task status icons" task_status_icons;
    case "row splice bounds and content" row_splice_bounds_and_content;
    case "bounded block replacements hydrate content only"
      bounded_block_replacements_hydrate_content_only;
  ]
