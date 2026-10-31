open Test_util

module Ds = Datascript
module Search = Search_index
module Storage = Storage_codec

let one = Storage.default_schema_attr

let schema =
  [
    ( "block/uuid"
    , { one with
        Ds.unique = Some Ds.Identity;
        indexed = true;
        value_type = Some Ds.UuidType;
      } );
    ("block/name", { one with Ds.value_type = Some Ds.StringType });
    ("block/title", { one with Ds.value_type = Some Ds.StringType });
    ("block/page", { one with Ds.value_type = Some Ds.RefType });
    ("block/parent", { one with Ds.value_type = Some Ds.RefType });
    ("block/journal-day", one);
    ("logseq.property/built-in?", one);
    ("logseq.property/hide?", one);
  ]

let page_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec1"

let block_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec2"

let ref_block_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec3"

let journal_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec4"

let hidden_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec5"

let cjk_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec6"

let add eid attr value = Ds.Add (Ds.Entity_id eid, attr, value)

let seeded_conn () =
  let conn = Ds.create_conn ~schema () in
  ignore
    (Ds.transact_conn conn
       [
         add 1 "block/uuid" (Ds.Uuid page_uuid);
         add 1 "block/name" (Ds.String "movies");
         add 1 "block/title" (Ds.String "Movies");
         add 2 "block/uuid" (Ds.Uuid block_uuid);
         add 2 "block/title" (Ds.String "watch 4k movies tonight");
         add 2 "block/page" (Ds.Ref 1);
         add 3 "block/uuid" (Ds.Uuid ref_block_uuid);
         add 3 "block/title" (Ds.String ("[[" ^ page_uuid ^ "]] marathon plan"));
         add 3 "block/page" (Ds.Ref 1);
         add 4 "block/uuid" (Ds.Uuid journal_uuid);
         add 4 "block/name" (Ds.String "aug 16th, 2026");
         add 4 "block/title" (Ds.String "Aug 16th, 2026");
         add 4 "block/journal-day" (Ds.Int64 20260816L);
         add 5 "block/uuid" (Ds.Uuid hidden_uuid);
         add 5 "block/name" (Ds.String "secret");
         add 5 "block/title" (Ds.String "Secret movies page");
         add 5 "logseq.property/hide?" (Ds.Bool true);
         add 6 "block/uuid" (Ds.Uuid cjk_uuid);
         add 6 "block/title" (Ds.String "晚上看电影");
         add 6 "block/page" (Ds.Ref 1);
       ]);
  conn

let with_index f =
  let root = Filename.temp_file "logseq-search" "" in
  let directory = Filename.concat root "search" in
  let path = Filename.concat directory "db.sqlite" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun candidate ->
          if Sys.file_exists candidate then Sys.remove candidate)
        [
          path;
          path ^ "-wal";
          path ^ "-shm";
          path ^ "-journal";
        ];
      if Sys.file_exists directory then Unix.rmdir directory;
      Unix.rmdir root)
    (fun () -> f (Search.create path))

let results index query = Search.search 100 index query

let graph_search_preserves_fts_matches_for_long_queries () = with_index (fun index ->
  let db = Ds.conn_db (seeded_conn ()) in
  Search.refresh index db;
  check ~msg:"contiguous FTS matches remain searchable" (results index "movie" <> []);
  List.iter (fun query ->
    check_eq ~msg:"long search does not add subsequence matching" (results index query) [];
    check_eq (Search.search_hits_page ~offset:0 ~limit:20 index db query) ([], false)) ["mve"];
  let indexes = Graph_sqlite.with_search_db index.path (fun connection ->
    Graph_sqlite.query connection
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'blocks' AND sql IS NOT NULL"
      [] (fun row -> Sqlite3.column_text row 0)) in
  check_eq ~msg:"FTS search needs no additional title B-tree index" indexes [])

let short_queries_search_pages_blocks_and_literal_symbols () = with_index (fun index ->
  let db = Ds.conn_db (seeded_conn ()) in
  Search.refresh index db;
  List.iter (fun (query, uuid) ->
    let hits, _ = Search.search_hits_page ~offset:0 ~limit:20 index db query in
    check ~msg:("short query returns its matching page or block: " ^ query)
      (List.exists (fun (hit : Search.indexed_search_hit) -> hit.uuid = uuid) hits))
    ["m", page_uuid; "MO", page_uuid; "4k", block_uuid; "电", cjk_uuid; "电影", cjk_uuid];
  let hidden, _ = Search.search_hits_page ~offset:0 ~limit:20 index db "se" in
  check_eq ~msg:"short queries keep hidden content excluded" hidden [];
  Search.search_upsert index.path ["symbols", "50% _ \\ \" 😀 é", page_uuid];
  List.iter (fun query ->
    let hits, _ = Search.search_hits_page ~offset:0 ~limit:20 index db query in
    check_eq ~msg:("short queries match symbols literally: " ^ query)
      (List.map (fun (hit : Search.indexed_search_hit) -> hit.uuid) hits) ["symbols"])
    ["%"; "_"; "\\"; "\""; "😀"; "é"];
  List.iter (fun query -> check_eq (Search.search_hits_page ~offset:0 ~limit:20 index db query) ([], false))
    [""; "  "; "#"];
  Search.search_upsert index.path (List.init 45 (fun i -> string_of_int i, "中", page_uuid));
  let ids offset = let hits, more = Search.search_hits_page ~offset ~limit:20 index db "中" in
    List.map (fun (hit : Search.indexed_search_hit) -> hit.uuid) hits, more in
  let first, more = ids 0 in
  check more; check_eq (List.length first) 20;
  let second, more = ids 20 in
  check more; check_eq (List.length second) 20;
  let last, more = ids 40 in
  check (not more); check_eq (List.length last) 5;
  check_eq ~msg:"short-query pages do not overlap" (List.length (List.sort_uniq String.compare (first @ second @ last))) 45;
  check_eq ~msg:"short-query pagination is stable" (ids 0) (first, true))

let search_limits_matches_before_reading_unneeded_ranks () = with_index (fun index ->
  let db = Ds.conn_db (seeded_conn ()) in
  Search.search_upsert index.path [
    "first", "A long introduction before the bounded needle result", page_uuid;
    "second", "needle", page_uuid;
    "third", "needle", page_uuid];
  let first, more = Search.search_hits_page ~offset:0 ~limit:1 index db "needle" in
  check_eq ~msg:"the first MATCH window is independent of ranks outside it"
    (List.map (fun (hit : Search.indexed_search_hit) -> hit.uuid) first) ["first"];
  check more;
  let next, more = Search.search_hits_page ~offset:1 ~limit:1 index db "needle" in
  check_eq (List.map (fun (hit : Search.indexed_search_hit) -> hit.uuid) next) ["second"];
  check more)

let find_result index query uuid =
  List.find_opt
    (fun (result : Search.search_result) -> result.uuid = uuid)
    (results index query)

let match_input_preserves_logseq_boolean_and_phrase_rules () =
  List.iter
    (fun (query, expected) -> check_eq expected (Search.get_match_input query))
    [
      ("movie", "movie");
      ("left and right", "left AND right");
      ("block/title", "\"block/title\"*");
      ("left and ", "\"left AND \"*");
      ("say \"hello\"", "\"say \"\"hello\"\"\"*");
      ("movies\tAND\t", "\"movies\tAND\t\"*");
      ("movies\nOR\n", "\"movies\nOR\n\"*");
      ("movies\rNOT\r", "\"movies\rNOT\r\"*");
      ("movies AND\nmarathon", "movies AND\nmarathon");
      ("movies OR\nmarathon NOT", "\"movies OR\nmarathon NOT\"*");
    ]

let incomplete_queries_do_not_break_search_or_later_valid_queries () =
  with_index (fun index ->
    let db = Ds.conn_db (seeded_conn ()) in
    Search.refresh index db;
    List.iter
      (fun query ->
        ignore (results index query);
        ignore (Search.search_hits_page ~offset:0 ~limit:20 index db query);
        check ~msg:("Search must recover after " ^ query)
          (find_result index "movies" page_uuid <> None))
      [ "\""; "[["; "movies AND"; "movies\tAND"; "movies\nOR";
        "AND movies"; "movies OR ("; "movies NOT -"; "movies : OR title";
        "movies AND OR movies"; "movies AND (movies"; "movies\000";
        "电影"; "🙂"; "https://example.com/a?b=c" ])

let fuzzy_scores_and_utf8_segmentation_preserve_search_semantics () =
  check (Search.fuzzy_score "mov" "movies" > Search.fuzzy_score "mov" "my old vase");
  check (Search.fuzzy_score "mov" "task" < 1.0);
  check_eq 1018.0 (Search.fuzzy_score "abc" "abc");
  check_eq 1012.0 (Search.fuzzy_score "" "");
  let cjk = "电" in
  let emoji = "😀" in
  let text = "a" ^ cjk ^ emoji in
  check_eq 3 (Search.utf8_length text);
  check_eq [ "a"; cjk; emoji ] (Search.utf8_chars text)

let candidates_are_deduplicated_limited_and_idempotently_refreshed () =
  with_index (fun index ->
    let db = Ds.conn_db (seeded_conn ()) in
    Search.refresh index db;
    let found = results index "movies" in
    let ids = List.map (fun (r : Search.search_result) -> r.uuid) found in
    check (found <> []);
    check_eq (List.length ids)
      (List.length (List.sort_uniq String.compare ids));
    List.iter
      (fun limit ->
        check_eq [] (Search.search limit index "movies"))
      [ 0; -1 ];
    check_eq [] (results index " \t\n");
    check_eq
      (match found with
       | first :: _ -> [ first ]
       | [] -> [])
      (Search.search 1 index "movies");
    check_eq []
      (Search.query_rows index
         "select id, page, title from missing_table" []);
    Search.refresh index db;
    check_eq found (results index "movies"))

let persisted_search_ranks_pages_resolves_references_and_refreshes_changes () =
  with_index (fun index ->
    let conn = seeded_conn () in
    Search.refresh index (Ds.conn_db conn);
    let found = results index "movies" in
    check_eq (Some page_uuid)
      (match found with
       | (first : Search.search_result) :: _ -> Some first.uuid
       | [] -> None);
    check_eq (Some true)
      (match found with
       | first :: _ -> Some first.is_page
       | [] -> None);
    List.iter
      (fun query -> check (find_result index query block_uuid <> None))
      [ "movies"; "ovie"; "4k movies" ];
    check (find_result index "晚上看" cjk_uuid <> None);
    check_eq (Some "[[Movies]] marathon plan")
      (match find_result index "Movies marathon" ref_block_uuid with
       | Some (hit : Search.search_result) -> Some hit.title
       | None -> None);
    check (find_result index "20260816" journal_uuid <> None);
    check_eq None (find_result index "Secret" hidden_uuid);
    check_eq
      (results index "movies")
      (results (Search.create index.path) "movies");
    ignore
      (Ds.transact_conn conn
         [
           Ds.Add
             ( Ds.Lookup_ref ("block/uuid", Ds.Uuid block_uuid)
             , "block/title"
             , Ds.String "listen to jazz records" );
         ]);
    Search.refresh index (Ds.conn_db conn);
    check_eq None (find_result index "4k movies" block_uuid);
    check (find_result index "jazz" block_uuid <> None);
    ignore
      (Ds.transact_conn conn
         [
           Ds.RetractEntity (Ds.Lookup_ref ("block/uuid", Ds.Uuid block_uuid));
         ]);
    Search.refresh index (Ds.conn_db conn);
    check_eq None (find_result index "jazz" block_uuid))

let sqlite_pages_are_stable_bounded_and_not_capped_at_one_hundred () =
  with_index (fun index ->
    let db = Ds.conn_db (seeded_conn ()) in
    Search.refresh index db;
    Search.search_upsert index.path (List.init 145 (fun i ->
      let id = Printf.sprintf "paged-%03d" i in id, "Paged needle", id));
    let first, more = Search.search_hits_page ~offset:0 ~limit:20 index db "Paged needle" in
    check_eq (List.length first) 20;
    check more;
    let rec all offset acc =
      let page, more = Search.search_hits_page ~offset ~limit:20 index db "Paged needle" in
      check (List.length page <= 20);
      let acc = List.rev_append page acc in
      if more then all (offset + List.length page) acc else List.rev acc in
    let hits = all 0 [] in
    check_eq (List.length hits) 145;
    let ids = List.map (fun (hit : Search.indexed_search_hit) -> hit.uuid) hits in
    check_eq (List.length (List.sort_uniq String.compare ids)) 145;
    check_eq (List.map (fun (hit : Search.indexed_search_hit) -> hit.uuid) first)
      (List.filteri (fun i _ -> i < 20) ids);
    List.iter (fun query ->
      let page, _ = Search.search_hits_page ~offset:0 ~limit:20 index db query in
      check ~msg:("paged search preserves matching for " ^ query) (page <> []))
      ["movies"; "ovie"; "4k movies"; "晚上看"; "[[Movies]]"; "movies AND marathon"];
    check_eq ([], false) (Search.search_hits_page ~offset:0 ~limit:20 index db "  ");
    check_eq ([], false) (Search.search_hits_page ~offset:0 ~limit:0 index db "movies");
    check_eq ([], false) (Search.search_hits_page ~offset:200 ~limit:20 index db "Paged needle"))

let builtin_content_tags_are_searchable () =
  with_index (fun index ->
    let db = match Graph_bootstrap.database "test" false (fun x -> Ok x) with
      | Ok db -> db | Error message -> fail message in
    Search.refresh index db;
    List.iter (fun query ->
      let hits = Search.search_hits 100 index db ("#" ^ query) in
      check ~msg:("Built-in content tag missing: " ^ query)
        (List.exists (fun (hit : Search.indexed_search_hit) -> String.lowercase_ascii hit.title = query) hits)
    ) ["code"; "math"; "quote"];
    check ~msg:"Internal property definitions must remain hidden"
      (not (List.exists (fun (hit : Search.indexed_search_hit) -> hit.title = "Node title")
        (Search.search_hits 100 index db "Node title"))))

let cases =
  [
    case "graph search preserves FTS matches for long queries" graph_search_preserves_fts_matches_for_long_queries;
    case "short queries search pages blocks and literal symbols" short_queries_search_pages_blocks_and_literal_symbols;
    case "built-in content tags are searchable" builtin_content_tags_are_searchable;
    case "incomplete queries do not break search or later valid queries"
      incomplete_queries_do_not_break_search_or_later_valid_queries;
    case "search bounds candidate work before ranking" search_limits_matches_before_reading_unneeded_ranks;
    case "sqlite pages are stable bounded and not capped at one hundred" sqlite_pages_are_stable_bounded_and_not_capped_at_one_hundred;
    case "match input preserves logseq boolean and phrase rules"
      match_input_preserves_logseq_boolean_and_phrase_rules;
    case "fuzzy scores and utf8 segmentation preserve search semantics"
      fuzzy_scores_and_utf8_segmentation_preserve_search_semantics;
    case "candidates are deduplicated limited and idempotently refreshed"
      candidates_are_deduplicated_limited_and_idempotently_refreshed;
    case "persisted search ranks pages resolves references and refreshes changes"
      persisted_search_ranks_pages_resolves_references_and_refreshes_changes;
  ]
