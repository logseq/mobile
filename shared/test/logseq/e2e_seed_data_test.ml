open Test_util

module Seed = E2e_seed_data
module Cli = E2e_seed_cli
module Journal = Journal
module Graph = Graph_read
module Markup = Markup
module Cards = Flashcards
module Codec = Storage_codec
module Store = Graph_store
module Ds = Datascript

let contains_sub hay needle =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay then false
    else if String.sub hay i n = needle then true
    else go (i + 1)
  in
  String.length needle = 0 || go 0

let join space parts = String.concat space parts

let command_line_validation_preserves_modes_and_exit_codes () =
  check_eq (Cli.parse_args [ "seed"; "graph.sqlite" ])
    (Ok ("graph.sqlite", Cli.Default));
  List.iter
    (fun (flag, mode) ->
      check_eq (Cli.parse_args [ "seed"; "graph.sqlite"; flag ])
        (Ok ("graph.sqlite", mode)))
    [
      ("--inspect", Cli.Inspect);
      ("--header-navigation", Cli.Header_navigation);
      ("--composer", Cli.Composer);
      ("--outliner", Cli.Outliner);
      ("--fixture", Cli.Fixture);
      ("--performance", Cli.Performance);
    ];
  List.iter
    (fun args -> check_eq (Cli.parse_args args) (Error (2, Cli.usage)))
    [
      [];
      [ "seed" ];
      [ "seed"; "graph.sqlite"; "--inspect"; "extra" ];
    ];
  check_eq (Cli.parse_args [ "seed"; "graph.sqlite"; "--unknown" ])
    (Error (2, "unknown seed mode: --unknown"));
  check_eq
    (Cli.run [ "seed"; "/nonexistent/graph.sqlite"; "--unknown" ])
    (2, "unknown seed mode: --unknown")

let expect_ok ?(msg = "expected Ok") result =
  match result with Ok value -> value | Error message -> fail (msg ^ ": " ^ message)

let schema : Ds.schema =
  let one = Codec.default_schema_attr in
  let text = { one with Ds.value_type = Some Ds.StringType } in
  let number = { one with Ds.value_type = Some Ds.NumberType } in
  let ref_ = { one with Ds.value_type = Some Ds.RefType; indexed = true } in
  let many_ref = { ref_ with Ds.cardinality = Ds.Many } in
  [
    ( "block/uuid",
      {
        one with
        Ds.unique = Some Ds.Identity;
        value_type = Some Ds.UuidType;
        indexed = true;
      } );
    ( "block/name",
      { text with Ds.unique = Some Ds.Identity; indexed = true } );
    ("block/title", text);
    ("block/page", ref_);
    ("block/parent", ref_);
    ("block/link", ref_);
    ("block/order", text);
    ("block/refs", many_ref);
    ("block/tags", many_ref);
    ("logseq.property.class/extends", many_ref);
    ("block/journal-day", { number with Ds.indexed = true });
    ("block/created-at", number);
    ("block/updated-at", number);
    ("logseq.property/built-in?", one);
    ( "db/ident",
      {
        one with
        Ds.unique = Some Ds.Identity;
        value_type = Some Ds.KeywordType;
        indexed = true;
      } );
  ]

let plain value = Ok value

let visible db = Graph.blocks plain 7 db

let exists db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some _ -> true
  | None -> false

let command_line_fixture_persists_and_can_be_inspected_and_reseeded () =
  let path = Filename.temp_file "logseq-seed" ".sqlite" in
  Sys.remove path;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Graph_sqlite.prepare_staging path;
      ignore
        (Ds.store
           ~storage:(Store.storage path)
           (Ds.conn_db (Ds.create_conn ~schema ())));
      List.iter
        (fun mode ->
          let code, message = Cli.run [ "seed"; path; mode ] in
          check_eq code 0;
          check ~msg:message
            (contains_sub message "journals=8 visible-blocks=18");
          let db = expect_ok (Store.restore_db path) in
          check_eq (Graph.journal_page_count db) 8;
          check_eq (List.length (visible db)) 18)
        [ "--fixture"; "--inspect"; "--fixture" ])

let standard_fixture_links_tags_rich_blocks_and_cards () =
  let conn = Ds.create_conn ~schema () in
  expect_ok (Seed.seed conn) |> ignore;
  let db = Ds.conn_db conn in
  let blocks = visible db in
  let source =
    match
      List.find_opt (fun (b : Cache_model.block) -> b.uuid = Seed.source_uuid)
        blocks
    with
    | Some block -> block
    | None -> fail "missing link source"
  in
  let nodes = Markup.parse source.references source.tags source.title in
  check_eq (Graph.journal_page_count db) 8;
  check_eq
    (List.map
       (fun (e : Cache_model.entity_summary) -> e.uuid)
       (Graph.sidebar_pages plain db).favorites)
    [ Seed.page_uuid 7 ];
  check_eq (List.length blocks) 18;
  check
    (not
       (List.exists
          (fun (b : Cache_model.block) -> b.uuid = Seed.older_block_uuid)
          blocks));
  check_eq (List.length source.references) 2;
  check_eq
    (List.sort compare
       (List.map
          (fun (e : Cache_model.entity_summary) -> (e.uuid, e.title))
          source.tags))
    [ (Seed.tag_uuid, "E2E Project"); (Seed.trailing_tag_uuid, "E2E Trailing") ];
  check
    (contains_sub
       (join " " (List.map Markup.debug_string nodes))
       "(");
  check_eq
    (List.filter_map
       (fun node -> match node with Markup.Markup_tag_ref (uuid, _) -> Some uuid | _ -> None)
       nodes)
    [ Seed.tag_uuid ];
  check
    (List.exists
       (fun (b : Cache_model.block) -> b.title = "E2E Child Tag Object")
       (Graph.objects_for_tag plain db Seed.tag_uuid));
  let due = Cards.due_cards db 2000000100000 in
  check_eq (List.length due) 1;
  let card = List.hd due in
  check_eq card.block.uuid "e2e00000-0000-4000-8000-000000000020";
  check_eq card.block.title "The capital of France is {{cloze Paris}}";
  check_eq
    (List.map (fun (b : Cache_model.block) -> b.title) card.children)
    [ "Paris is the answer" ]

let outliner_reset_is_idempotent () =
  let conn = Ds.create_conn ~schema () in
  for _ = 1 to 2 do
    ignore (expect_ok (Seed.seed_outliner conn 1787893600000))
  done;
  let db = Ds.conn_db conn in
  check_eq (Graph.journal_page_count db) 1;
  check (exists db Seed.outliner_block_uuid);
  check
    (List.exists
       (fun (e : Cache_model.entity_summary) -> e.uuid = Seed.outliner_tag_uuid)
       (Graph.tag_pages plain db));
  check_eq (List.length (visible db)) 1

let standard_reset_is_idempotent () =
  let conn = Ds.create_conn ~schema () in
  for _ = 1 to 2 do
    ignore (expect_ok (Seed.seed_fixture conn))
  done;
  check_eq (Graph.journal_page_count (Ds.conn_db conn)) 8;
  check_eq (List.length (visible (Ds.conn_db conn))) 18

let performance_reset_retains_one_hundred_journals () =
  let conn = Ds.create_conn ~schema () in
  for _ = 1 to 2 do
    ignore (expect_ok (Seed.seed_performance conn 1788000000000))
  done;
  check_eq (Graph.journal_page_count (Ds.conn_db conn)) 100;
  check_eq (List.length (visible (Ds.conn_db conn))) 56

let performance_fixture_supports_insertion_between_adjacent_blocks () =
  let conn = Ds.create_conn ~schema () in
  ignore (expect_ok (Seed.seed_performance_sized conn 1788000000000 1 500));
  let blocks = visible (Ds.conn_db conn) in
  check_eq (List.length blocks) 500;
  let rec adjacent = function
    | first :: (second :: _ as rest) ->
      let order = expect_ok (Fractional_order.between first.Cache_model.order second.Cache_model.order) in
      check (Some order > first.order && Some order < second.order);
      adjacent rest
    | _ -> ()
  in
  adjacent blocks

let header_navigation_has_fixed_date_and_title () =
  let conn = Ds.create_conn ~schema () in
  ignore (expect_ok (Seed.seed_header_navigation conn));
  let db = Ds.conn_db conn in
  let blocks = visible db in
  check_eq (Graph.journal_page_count db) 1;
  check_eq (List.length blocks) 1;
  check_eq (List.hd blocks).journal (Some ("Aug 24th, 2026", 20260824));
  check_eq (List.hd blocks).title "E2E Header Navigation"

let entity id attrs : Ds.tx_op =
  Ds.Entity { db_id = id; attrs }

let composer_reset_preserves_built_ins_and_removes_user_content () =
  let conn = Ds.create_conn ~schema () in
  let built_in_page = "00000002-0000-4000-8000-000000000001" in
  let built_in_child = "00000004-0000-4000-8000-000000000001" in
  ignore (Ds.transact_conn conn
    [
      entity (Some (Ds.Temp_id "built-in-page"))
        [
          ("block/uuid", Ds.One_value (Ds.Uuid built_in_page));
          ("block/title", Ds.One_value (Ds.String "Built in"));
          ("logseq.property/built-in?", Ds.One_value (Ds.Bool true));
        ];
      entity None
        [
          ("block/uuid", Ds.One_value (Ds.Uuid built_in_child));
          ("block/title", Ds.One_value (Ds.String "Built-in child"));
          ( "block/page",
            Ds.One_value (Ds.Ref_to (Ds.Temp_id "built-in-page")) );
          ( "block/parent",
            Ds.One_value (Ds.Ref_to (Ds.Temp_id "built-in-page")) );
          ("block/order", Ds.One_value (Ds.String "a0"));
          ("logseq.property/built-in?", Ds.One_value (Ds.Bool true));
        ];
      entity (Some (Ds.Temp_id "stale-page"))
        [
          ("block/uuid", Ds.One_value (Ds.Uuid "e2e-stale-page"));
          ("block/name", Ds.One_value (Ds.String "stale journal"));
          ("block/title", Ds.One_value (Ds.String "Stale Journal"));
          ("block/journal-day", Ds.One_value (Ds.Int64 20260827L));
        ];
      entity None
        [
          ("block/uuid", Ds.One_value (Ds.Uuid "e2e-stale-block"));
          ( "block/title",
            Ds.One_value (Ds.String "Stale composer traffic") );
          ( "block/page",
            Ds.One_value (Ds.Ref_to (Ds.Temp_id "stale-page")) );
          ( "block/parent",
            Ds.One_value (Ds.Ref_to (Ds.Temp_id "stale-page")) );
          ("block/order", Ds.One_value (Ds.String "a0"));
        ];
    ]);
  for _ = 1 to 2 do
    ignore (expect_ok (Seed.seed_composer conn 1787893600000))
  done;
  let db = Ds.conn_db conn in
  check (exists db built_in_page);
  check (exists db built_in_child);
  check (not (exists db "e2e-stale-page"));
  check (not (exists db "e2e-stale-block"));
  check_eq (Graph.journal_page_count db) 1;
  check_eq
    (List.map (fun (b : Cache_model.block) -> b.title) (visible db))
    [ "E2E Composer Fixture" ]

let journal_title_ordinal_boundaries () =
  List.iter
    (fun (day, title) -> check_eq (Journal.day_title day) title)
    [
      (20260101, "Jan 1st, 2026");
      (20260202, "Feb 2nd, 2026");
      (20260303, "Mar 3rd, 2026");
      (20260404, "Apr 4th, 2026");
      (20260511, "May 11th, 2026");
      (20260612, "Jun 12th, 2026");
      (20260713, "Jul 13th, 2026");
      (20260821, "Aug 21st, 2026");
      (20260922, "Sep 22nd, 2026");
      (20261023, "Oct 23rd, 2026");
      (20261130, "Nov 30th, 2026");
      (20261231, "Dec 31st, 2026");
    ]

let cases =
  [
    case "command line validation preserves modes and exit codes"
      command_line_validation_preserves_modes_and_exit_codes;
    case "command line fixture persists and can be inspected and reseeded"
      command_line_fixture_persists_and_can_be_inspected_and_reseeded;
    case "standard fixture links tags rich blocks and cards"
      standard_fixture_links_tags_rich_blocks_and_cards;
    case "outliner reset is idempotent" outliner_reset_is_idempotent;
    case "standard reset is idempotent" standard_reset_is_idempotent;
    case "performance reset retains one hundred journals"
      performance_reset_retains_one_hundred_journals;
    case "performance fixture supports insertion between adjacent blocks"
      performance_fixture_supports_insertion_between_adjacent_blocks;
    case "header navigation has fixed date and title"
      header_navigation_has_fixed_date_and_title;
    case "composer reset preserves built-ins and removes user content"
      composer_reset_preserves_built_ins_and_removes_user_content;
    case "journal title ordinal boundaries" journal_title_ordinal_boundaries;
  ]
