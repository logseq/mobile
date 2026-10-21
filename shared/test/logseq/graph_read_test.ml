open Test_util

module Read = Graph_read
module Projection = Graph_projection
module Model = Cache_model
module Storage = Storage_codec
module Transit = Transit_core.Json
module Ds = Datascript

let one = Storage.default_schema_attr
let string_attr = { one with Ds.value_type = Some Ds.StringType }
let ref_attr = { one with Ds.value_type = Some Ds.RefType }
let instant_attr = { one with Ds.value_type = Some Ds.InstantType }
let many_ref = { ref_attr with Ds.cardinality = Ds.Many; indexed = true }

let schema : (string * Ds.schema_attr) list =
  [
    ( "block/uuid",
      {
        one with
        Ds.value_type = Some Ds.UuidType;
        unique = Some Ds.Identity;
        indexed = true;
      } );
    ( "block/name",
      { string_attr with Ds.unique = Some Ds.Identity; indexed = true } );
    ("block/title", string_attr);
    ("block/page", ref_attr);
    ("block/parent", ref_attr);
    ("block/link", ref_attr);
    ("block/order", string_attr);
    ("block/created-at", instant_attr);
    ("block/updated-at", instant_attr);
    ("block/journal-day", one);
    ("block/refs", many_ref);
    ("block/tags", many_ref);
    ("logseq.property.class/extends", many_ref);
    ("logseq.property/hide?", one);
    ("logseq.property/deleted-at", instant_attr);
    ("logseq.property/view-for", ref_attr);
    ("logseq.property/created-from-property", ref_attr);
    ("block/closed-value-property", ref_attr);
    ("logseq.property.class/hide-from-node", one);
    ("logseq.property/built-in?", one);
    ( "db/ident",
      {
        one with
        Ds.value_type = Some Ds.KeywordType;
        unique = Some Ds.Identity;
        indexed = true;
      } );
  ]

let schema_entry name = List.assoc name schema

let new_conn attributes overrides =
  let picked =
    [ "block/uuid"; "block/name"; "block/title" ]
    @ attributes
    |> List.sort_uniq compare
    |> List.filter (fun name -> not (List.mem_assoc name overrides))
    |> List.map (fun name -> (name, schema_entry name))
  in
  Ds.create_conn ~schema:(picked @ overrides) ()

let field name value = (name, Ds.One_value value)

let refs name ids =
  ( name,
    Ds.Many_values
      (List.map (fun id -> Ds.Ref_to (Ds.Temp_id id)) ids) )

let entity_input id attributes : Ds.tx_op =
  Ds.Entity { db_id = Some id; attrs = attributes }

let entity id title attributes =
  entity_input (Ds.Temp_id id)
    (field "block/uuid" (Ds.Uuid id) :: field "block/title" (Ds.String title)
     :: attributes)

let page id name title attributes =
  entity id title (field "block/name" (Ds.String name) :: attributes)

let journal id title day =
  page id id title [ field "block/journal-day" (Ds.Int64 (Int64.of_int day)) ]

let block id title page parent created attributes =
  entity id title
    (field "block/page" (Ds.Ref_to (Ds.Temp_id page))
    :: field "block/parent" (Ds.Ref_to (Ds.Temp_id parent))
    :: field "block/created-at" (Ds.Instant (Int64.of_int created))
    :: attributes)

let transact conn entities = ignore (Ds.transact_conn conn entities)

let add conn uuid attr value =
  transact conn
    [ Ds.Add (Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid), attr, value) ]

let eid db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> eid
  | None -> fail ("missing entity: " ^ uuid)

let wire_id uuid = Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid uuid ]

let wire_entity uuid _attr _value = wire_id uuid

let change _t upserts deleted = upserts @ deleted

let uuids blocks =
  List.map (fun (b : Model.block) -> b.uuid) blocks

let summary_uuids values =
  List.map (fun (e : Model.entity_summary) -> e.uuid) values

let summaries values =
  List.sort compare
    (List.map (fun (e : Model.entity_summary) -> (e.uuid, e.title)) values)

let find_block uuid blocks =
  match
    List.find_opt (fun (b : Model.block) -> b.uuid = uuid) blocks
  with
  | Some block -> block
  | None -> fail ("missing projected block: " ^ uuid)

let plain value = Ok value

let incremental_projection_refreshes_dependencies_and_evicts_recycled_journals
    () =
  let conn =
    new_conn
      [
        "block/page";
        "block/parent";
        "block/created-at";
        "block/journal-day";
        "logseq.property/deleted-at";
      ]
      []
  in
  let page_id = "028f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let first_id = "028f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let second_id = "028f7850-c6aa-7da0-8b3f-6dbb64aa4eca" in
  let decrypted = ref 0 in
  let fail_flag = ref false in
  let decrypt title =
    if !fail_flag then failwith "projection decryption failed";
    incr decrypted;
    Ok title
  in
  transact conn
    [
      journal page_id "Journal" 20260816;
      block first_id "First" page_id page_id 1 [];
      block second_id "Second" page_id page_id 2 [];
    ];
  let current = Projection.create decrypt (Ds.conn_db conn) in
  fail_flag := true;
  check
    (match Projection.rebuild current (Ds.conn_db conn) with
     | exception Failure message -> message = "projection decryption failed"
     | _ -> false);
  check_eq (Projection.blocks current) [];
  fail_flag := false;
  Projection.rebuild current (Ds.conn_db conn);
  decrypted := 0;
  add conn first_id "block/title" (Ds.String "First updated");
  Projection.update current (Ds.conn_db conn)
    (change 2
       [
         wire_entity first_id "block/title"
           (Transit.String "First updated");
       ]
       []);
  check (!decrypted <= 2);
  check_eq
    (List.map (fun (b : Model.block) -> b.title) (Projection.blocks current))
    [ "First updated"; "Second" ];
  decrypted := 0;
  add conn page_id "block/title" (Ds.String "Journal updated");
  Projection.update current (Ds.conn_db conn)
    (change 3
       [
         wire_entity page_id "block/title"
           (Transit.String "Journal updated");
       ]
       []);
  check (!decrypted <= 4);
  check_eq
    (List.map (fun (b : Model.block) -> b.journal) (Projection.blocks current))
    [ Some ("Journal updated", 20260816); Some ("Journal updated", 20260816) ];
  transact conn
    [ Ds.RetractEntity (Ds.Entity_id (eid (Ds.conn_db conn) first_id)) ];
  Projection.update current (Ds.conn_db conn) (change 4 [] [ wire_id first_id ]);
  check_eq (uuids (Projection.blocks current)) [ second_id ];
  let next_page = "028f7850-c6aa-7da0-8b3f-6dbb64aa4ecb" in
  let next_block = "028f7850-c6aa-7da0-8b3f-6dbb64aa4ecc" in
  transact conn
    [
      journal next_page "Next journal" 20260817;
      block next_block "Next block" next_page next_page 3 [];
    ];
  Projection.update current (Ds.conn_db conn)
    (change 5
       [
         wire_entity next_page "block/journal-day"
           (Transit.Int 20260817);
       ]
       []);
  check_eq
    (Read.recent_journal_page_ids 1 (Ds.conn_db conn))
    [ eid (Ds.conn_db conn) next_page ];
  check_eq (Read.journal_page_count (Ds.conn_db conn)) 2;
  add conn next_page "logseq.property/deleted-at" (Ds.Instant 6L);
  let db = Ds.conn_db conn in
  check_eq (Read.recent_journal_page_ids 7 db) [ eid db page_id ];
  check
    (not
       (List.exists
          (fun (b : Model.block) -> b.page_id = next_page)
          (Read.blocks plain 7 db)));
  check_eq (Read.journal_page_count db) 1;
  check_eq (Read.journal_page_uuid db 20260817) None;
  Projection.update current (Ds.conn_db conn)
    (change 6
       [
         wire_entity next_page "logseq.property/deleted-at"
           (Transit.Date (Int64.of_int 6));
       ]
       []);
  check_eq (uuids (Projection.blocks current)) [ second_id ]

let node_navigation_and_related_blocks_respect_visibility_and_breadcrumbs () =
  let conn =
    new_conn
      [
        "block/page";
        "block/parent";
        "block/tags";
        "block/refs";
        "block/created-at";
        "logseq.property/hide?";
        "logseq.property/deleted-at";
        "logseq.property/view-for";
      ]
      []
  in
  transact conn
    [
      page "node-page" "node-page" "Node page" [];
      page "tag" "project" "Project" [];
      block "parent-block" "Parent block" "node-page" "node-page" 1 [];
      block "referenced-block" "Referenced block" "node-page" "node-page" 1 [];
      block "object" "Tagged object" "node-page" "parent-block" 2
        [ refs "block/tags" [ "tag" ] ];
      block "linked-reference" "Linked reference" "node-page" "node-page" 3
        [ refs "block/refs" [ "node-page" ] ];
      block "hidden-tagged-object" "Hidden tagged object" "node-page"
        "node-page" 4
        [
          refs "block/tags" [ "tag" ];
          field "logseq.property/hide?" (Ds.Bool true);
        ];
      block "view-linked-reference" "View linked reference" "node-page"
        "node-page" 5
        [
          refs "block/refs" [ "node-page" ];
          field "logseq.property/view-for" (Ds.Ref_to (Ds.Temp_id "tag"));
        ];
      block "recycled-linked-reference" "Recycled linked reference"
        "node-page" "node-page" 6
        [
          refs "block/refs" [ "node-page" ];
          field "logseq.property/deleted-at" (Ds.Instant 6L);
        ];
      entity "hidden-parent" "Hidden parent"
        [
          field "block/page" (Ds.Ref_to (Ds.Temp_id "node-page"));
          field "block/parent" (Ds.Ref_to (Ds.Temp_id "node-page"));
          field "logseq.property/hide?" (Ds.Bool true);
        ];
      entity "hidden-child" "Hidden child"
        [
          field "block/page" (Ds.Ref_to (Ds.Temp_id "node-page"));
          field "block/parent" (Ds.Ref_to (Ds.Temp_id "hidden-parent"));
        ];
    ];
  let db = Ds.conn_db conn in
  (match Read.node_destination plain db "node-page" with
   | Some (page, is_page) ->
     check_eq page.uuid "node-page";
     check_eq page.title "Node page";
     check_eq is_page false
   | None -> check false);
  (match Read.node_destination plain db "referenced-block" with
   | Some (page, is_page) ->
     check_eq page.uuid "node-page";
     check_eq is_page true
   | None -> check false);
  List.iter
    (fun uuid -> check_eq (Read.node_destination plain db uuid) None)
    [ "hidden-parent"; "hidden-child" ];
  let objects = Read.objects_for_tag plain db "tag" in
  let references = Read.references_for_node plain db "node-page" in
  check_eq (uuids objects) [ "object" ];
  check_eq
    (List.map (fun (b : Model.block) -> b.title) objects)
    [ "Tagged object" ];
  check_eq
    (List.map
       (fun (e : Model.entity_summary) -> e.title)
       (List.hd objects).breadcrumbs)
    [ "Node page"; "Parent block" ];
  check_eq (uuids references) [ "linked-reference" ];
  check_eq
    (List.map (fun (b : Model.block) -> b.title) references)
    [ "Linked reference" ];
  check_eq
    (List.map
       (fun (e : Model.entity_summary) -> e.title)
       (List.hd references).breadcrumbs)
    [ "Node page" ]

let journals_stay_grouped_newest_first_in_outliner_order () =
  let conn =
    new_conn
      [
        "block/page";
        "block/parent";
        "block/order";
        "block/created-at";
        "block/journal-day";
      ]
      []
  in
  transact conn
    [
      journal "older-page" "Older" 20260827;
      journal "newer-page" "Newer" 20260828;
      block "older-first" "Older first" "older-page" "older-page" 10
        [ field "block/order" (Ds.String "a0") ];
      block "newer-second" "Newer second" "newer-page" "newer-page" 20
        [ field "block/order" (Ds.String "a1") ];
      block "older-second" "Older second" "older-page" "older-page" 30
        [ field "block/order" (Ds.String "a1") ];
      block "newer-first" "Newer first" "newer-page" "newer-page" 40
        [ field "block/order" (Ds.String "a0") ];
    ];
  check_eq
    (uuids (Read.blocks plain 2 (Ds.conn_db conn)))
    [ "newer-first"; "newer-second"; "older-first"; "older-second" ]

let transitive_class_cycles_include_tagged_pages_and_classify_assets () =
  let conn =
    new_conn
      [
        "block/page";
        "block/parent";
        "block/tags";
        "logseq.property.class/extends";
        "block/created-at";
        "db/ident";
      ]
      []
  in
  transact conn
    [
      entity "tag-class" "Tag"
        [ field "db/ident" (Ds.Keyword "logseq.class/Tag") ];
      entity "asset-class" "Asset"
        [ field "db/ident" (Ds.Keyword "logseq.class/Asset") ];
      entity "property-class" "Property"
        [ field "db/ident" (Ds.Keyword "logseq.class/Property") ];
      page "status-property" "status" "Status"
        [ refs "block/tags" [ "property-class" ] ];
      page "page" "page" "Page" [];
      page "parent-tag" "parent tag" "Parent tag"
        [
          refs "block/tags" [ "tag-class" ];
          refs "logseq.property.class/extends" [ "grandchild-tag" ];
        ];
      page "child-tag" "child tag" "Child tag"
        [
          refs "block/tags" [ "tag-class" ];
          refs "logseq.property.class/extends" [ "parent-tag" ];
        ];
      page "grandchild-tag" "grandchild tag" "Grandchild tag"
        [
          refs "block/tags" [ "tag-class" ];
          refs "logseq.property.class/extends" [ "child-tag" ];
        ];
      block "tagged-object" "Tagged through a descendant" "page" "page" 1
        [ refs "block/tags" [ "grandchild-tag" ] ];
      page "tagged-page" "tagged page" "Tagged page"
        [
          refs "block/tags" [ "grandchild-tag" ];
          field "block/created-at" (Ds.Instant 3L);
        ];
      page "asset-child" "asset child" "Asset child"
        [ refs "logseq.property.class/extends" [ "asset-class" ] ];
      block "asset-object" "Asset" "page" "page" 2
        [ refs "block/tags" [ "asset-child" ] ];
    ];
  let db = Ds.conn_db conn in
  let objects = Read.objects_for_tag plain db "parent-tag" in
  check (Read.node_is_tag db "child-tag");
  check (Read.node_is_property db "status-property");
  check (not (Read.node_is_property db "tagged-page"));
  check_eq (uuids objects) [ "tagged-object"; "tagged-page" ];
  check_eq (List.nth objects 1).page_id "tagged-page";
  check_eq (List.nth objects 1).parent_id None;
  check
    (find_block "asset-object" (Read.blocks_for_page plain db "page")).is_asset

let graph_blocks_preserve_identities_instants_order_and_decrypt_journal_titles
    () =
  let conn =
    new_conn
      [
        "block/page";
        "block/parent";
        "block/order";
        "block/created-at";
        "block/updated-at";
        "logseq.property/hide?";
        "block/journal-day";
      ]
      []
  in
  let page_id = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let block_id = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  transact conn
    [
      journal page_id "Page" 20260815;
      block block_id "Desktop seed" page_id page_id 1776000000000
        [
          field "block/order" (Ds.String "a1");
          field "block/updated-at" (Ds.Instant 1776000000001L);
        ];
    ];
  let db = Ds.conn_db conn in
  let blocks = Read.blocks plain 7 db in
  let block = List.hd blocks in
  check_eq (Read.journal_page_uuid db 20260815) (Some page_id);
  check_eq (Read.journal_page_uuid db 20260816) None;
  check_eq (uuids blocks) [ block_id ];
  check_eq block.title "Desktop seed";
  check_eq block.page_id page_id;
  check_eq block.order (Some "a1");
  check_eq block.created_at 1776000000000;
  check_eq block.journal (Some ("Page", 20260815));
  add conn block_id "block/title" (Ds.String "cipher-block");
  add conn page_id "block/title" (Ds.String "cipher-page");
  let decrypt value =
    Ok
      (match value with
       | "cipher-block" -> "Decrypted block"
       | "cipher-page" -> "Decrypted journal"
       | _ -> value)
  in
  let blocks = Read.blocks decrypt 7 (Ds.conn_db conn) in
  check_eq
    (List.map (fun (b : Model.block) -> b.title) blocks)
    [ "Decrypted block" ];
  check_eq
    (List.map (fun (b : Model.block) -> b.journal) blocks)
    [ Some ("Decrypted journal", 20260815) ]

let reference_target_renames_refresh_projections_and_public_tags_stay_visible
    () =
  let conn =
    new_conn
      [
        "block/page";
        "block/parent";
        "block/created-at";
        "block/journal-day";
        "block/refs";
        "block/tags";
        "logseq.property.class/hide-from-node";
        "db/ident";
      ]
      [ ("block/page", one); ("block/parent", one) ]
  in
  transact conn
    [
      entity "tag-class" "Tag"
        [ field "db/ident" (Ds.Keyword "logseq.class/Tag") ];
      journal "journal" "Journal" 20260817;
      page "page-target" "page target" "Page target" [];
      entity "block-target" "Block target"
        [
          field "block/page" (Ds.Ref_to (Ds.Temp_id "journal"));
          field "block/parent" (Ds.Ref_to (Ds.Temp_id "journal"));
        ];
      page "tag-target" "project" "Project"
        [ refs "block/tags" [ "tag-class" ] ];
      page "public-built-in-tag" "card" "Card"
        [
          refs "block/tags" [ "tag-class" ];
          field "db/ident" (Ds.Keyword "logseq.class/Card");
        ];
      page "internal-tag" "task" "Task"
        [
          refs "block/tags" [ "tag-class" ];
          field "db/ident" (Ds.Keyword "logseq.class/Task");
        ];
      block "source" "Source" "journal" "journal" 1
        [
          refs "block/refs" [ "page-target"; "block-target" ];
          refs "block/tags"
            [ "tag-target"; "public-built-in-tag"; "internal-tag" ];
        ];
    ];
  let db = Ds.conn_db conn in
  let source = find_block "source" (Read.blocks plain 7 db) in
  let current = Projection.create plain db in
  check_eq
    (summaries (Read.tag_pages plain db))
    [
      ("internal-tag", "Task");
      ("public-built-in-tag", "Card");
      ("tag-target", "Project");
    ];
  check_eq (summaries source.references)
    [ ("block-target", "Block target"); ("page-target", "Page target") ];
  check_eq (summaries source.tags)
    [ ("public-built-in-tag", "Card"); ("tag-target", "Project") ];
  add conn "page-target" "block/title" (Ds.String "Renamed page");
  Projection.update current (Ds.conn_db conn)
    (change 2
       [
         wire_entity "page-target" "block/title"
           (Transit.String "Renamed page");
       ]
       []);
  check_eq
    (summaries
       (find_block "source" (Projection.blocks current)).references)
    [ ("block-target", "Block target"); ("page-target", "Renamed page") ]

let sidebar_favorites_preserve_order_and_exclude_hidden_built_in_and_favorite_recents
    () =
  let conn =
    new_conn
      [
        "block/page";
        "block/parent";
        "block/link";
        "block/order";
        "block/created-at";
        "block/updated-at";
      ]
      []
  in
  transact conn
    [
      page "favorites-page" "$$$favorites" "Favorites" [];
      page "page-alpha" "alpha" "Alpha"
        [ field "block/updated-at" (Ds.Instant 200L) ];
      page "page-beta" "beta" "Beta"
        [ field "block/updated-at" (Ds.Instant 300L) ];
      page "page-hidden" "hidden" "Hidden"
        [
          field "block/updated-at" (Ds.Instant 400L);
          field "logseq.property/hide?" (Ds.Bool true);
        ];
      page "page-seeded-recent" "seeded-recent" "Seeded recent" [];
      page "page-built-in" "built-in-page" "Built-in page"
        [
          field "block/updated-at" (Ds.Instant 500L);
          field "logseq.property/built-in?" (Ds.Bool true);
        ];
      entity "favorite-alpha" ""
        [
          field "block/page" (Ds.Ref_to (Ds.Temp_id "favorites-page"));
          field "block/link" (Ds.Ref_to (Ds.Temp_id "page-alpha"));
          field "block/order" (Ds.String "b");
        ];
      entity "favorite-beta" ""
        [
          field "block/page" (Ds.Ref_to (Ds.Temp_id "favorites-page"));
          field "block/link" (Ds.Ref_to (Ds.Temp_id "page-beta"));
          field "block/order" (Ds.String "a");
        ];
      entity "alpha-block" "Alpha content"
        [
          field "block/page" (Ds.Ref_to (Ds.Temp_id "page-alpha"));
          field "block/parent" (Ds.Ref_to (Ds.Temp_id "page-alpha"));
          field "block/created-at" (Ds.Instant 100L);
          field "block/updated-at" (Ds.Instant 100L);
        ];
    ];
  let db = Ds.conn_db conn in
  let sidebar = Read.sidebar_pages plain db in
  check_eq (summary_uuids sidebar.favorites) [ "page-beta"; "page-alpha" ];
  check_eq (summary_uuids sidebar.recent_pages) [ "page-seeded-recent" ];
  check
    (not
       (List.exists
          (fun (e : Model.entity_summary) -> e.uuid = "favorites-page")
          sidebar.recent_pages));
  check_eq
    (uuids (Read.blocks_for_page plain db "page-alpha"))
    [ "alpha-block" ]

let thousand_journal_graphs_only_materialize_the_requested_window () =
  let conn =
    new_conn
      [ "block/page"; "block/parent"; "block/created-at"; "block/journal-day" ]
      []
  in
  let decrypted = ref 0 in
  let decrypt value =
    incr decrypted;
    Ok value
  in
  transact conn
    (List.init 1000 (fun index ->
         let page_id = Printf.sprintf "large-page-%d" index in
         [
           journal page_id (Printf.sprintf "Journal %d" index) (2000000 + index);
           block
             (Printf.sprintf "large-block-%d" index)
             (Printf.sprintf "Block %d" index)
             page_id page_id index [];
         ])
     |> List.concat);
  let db = Ds.conn_db conn in
  let visible = Read.blocks decrypt 7 db in
  check_eq (List.length visible) 7;
  check_eq !decrypted 14;
  check_eq (Read.journal_page_count db) 1000;
  check_eq (uuids visible)
    (List.init 7 (fun i -> Printf.sprintf "large-block-%d" (999 - i)))

let restored_raw_numeric_references_remain_navigable () =
  let conn =
    new_conn
      [ "block/page"; "block/parent"; "block/created-at"; "block/journal-day" ]
      [ ("block/page", one); ("block/parent", one) ]
  in
  let raw e a v =
    Ds.Raw_datom { Ds.e; a; v; tx = 0; added = true }
  in
  let db =
    Ds.db_with
      [
        raw 1 "block/uuid" (Ds.Uuid "raw-page");
        raw 1 "block/name" (Ds.String "raw-page");
        raw 1 "block/title" (Ds.String "Raw journal");
        raw 1 "block/journal-day" (Ds.Int64 20260817L);
        raw 2 "block/uuid" (Ds.Uuid "raw-block");
        raw 2 "block/title" (Ds.String "Restored block");
        raw 2 "block/page" (Ds.Int64 1L);
        raw 2 "block/parent" (Ds.Int64 1L);
        raw 2 "block/created-at" (Ds.Instant 1L);
      ]
      (Ds.conn_db conn)
  in
  let blocks = Read.blocks plain 7 db in
  check_eq (uuids blocks) [ "raw-block" ];
  let block = List.hd blocks in
  check_eq block.page_id "raw-page";
  check_eq block.parent_id (Some "raw-page");
  check_eq block.journal (Some ("Raw journal", 20260817))

let title_normalization_resolves_unique_names_and_shares_new_tags_across_titles
    () =
  let conn =
    new_conn
      [
        "block/page";
        "block/parent";
        "block/refs";
        "block/tags";
        "block/created-at";
        "db/ident";
      ]
      [ ("block/name", { string_attr with Ds.indexed = true }) ]
  in
  transact conn
    [
      entity "tag-class" "Tag"
        [ field "db/ident" (Ds.Keyword "logseq.class/Tag") ];
      page "project-tag-uuid" "project" "Project"
        [ refs "block/tags" [ "tag-class" ] ];
      page "roadmap-page-uuid" "roadmap" "Roadmap" [];
      page "dup-a-uuid" "dup" "Dup" [];
      page "dup-b-uuid" "dup" "Dup" [];
      entity "note-uuid" "Note"
        [ refs "block/refs" [ "roadmap-page-uuid" ] ];
    ];
  let db = Ds.conn_db conn in
  let normalize title =
    Read.normalize_title_text (fun _ -> None) db "note-uuid" title
  in
  List.iter
    (fun (title, expected) -> check_eq (normalize title) expected)
    [
      ( "Ship [[Roadmap]] as #project and #[[Project]]",
        "Ship [[roadmap-page-uuid]] as #[[project-tag-uuid]] and #[[project-tag-uuid]]" );
      ("todo #PROJECT.", "todo #[[project-tag-uuid]].");
      ("see [[Dup]] and #nothing", "see [[Dup]] and #nothing");
      ("#roadmap stays", "#roadmap stays");
      ("kept [[roadmap-page-uuid]]", "kept [[roadmap-page-uuid]]");
    ];
  let counter = ref 0 in
  let fresh () =
    incr counter;
    Printf.sprintf "fresh-%d" !counter
  in
  let titles, created =
    Read.normalize_titles_creating_tags db fresh "note-uuid"
      [ "start #foobar"; "end #FooBar and #project" ]
  in
  let unchanged, none_created =
    Read.normalize_titles_creating_tags db fresh "note-uuid"
      [ "plain #project" ]
  in
  check_eq titles
    [ "start #[[fresh-1]]"; "end #[[fresh-1]] and #[[project-tag-uuid]]" ];
  check_eq created [ ("fresh-1", "foobar") ];
  check_eq unchanged [ "plain #[[project-tag-uuid]]" ];
  check_eq none_created []

let recent_page eid title attributes =
  entity_input (Ds.Entity_id eid)
    (field "block/uuid" (Ds.Uuid (Printf.sprintf "recent-%d" eid))
    :: field "block/name" (Ds.String (Printf.sprintf "recent-%d" eid))
    :: field "block/title" (Ds.String title)
    :: field "block/updated-at" (Ds.Instant (Int64.of_int eid))
    :: attributes)

let recent_window_fills_past_hidden_and_blank_pages_without_decrypting_older_pages
    () =
  let conn = Ds.create_conn () in
  let decrypted = ref [] in
  let decrypt title =
    decrypted := title :: !decrypted;
    Ok title
  in
  transact conn
    (List.init 100 (fun i -> recent_page (i + 1) (string_of_int (i + 1)) [])
    @ [
        recent_page 101 "Hidden"
          [ field "logseq.property/hide?" (Ds.Bool true) ];
        recent_page 102 "Built-in"
          [ field "logseq.property/built-in?" (Ds.Bool true) ];
        recent_page 103 "Deleted"
          [ field "logseq.property/deleted-at" (Ds.Instant 1L) ];
        recent_page 104 "  " [];
        recent_page 105 "Hidden child"
          [ field "block/parent" (Ds.Ref 101) ];
      ]);
  check_eq
    (summary_uuids (Read.sidebar_pages decrypt (Ds.conn_db conn)).recent_pages)
    (List.init 15 (fun i -> Printf.sprintf "recent-%d" (100 - i)));
  check
    (not
       (List.exists (fun title -> title = "1" || title = "85") !decrypted));
  check_eq (Read.sidebar_pages plain (Ds.empty_db ())).recent_pages []

let built_in_tag_filtering_and_recent_assignment_order_match_logseq () =
  let conn =
    new_conn [ "block/tags"; "db/ident" ]
      [
        ( "block/uuid",
          { one with Ds.unique = Some Ds.Identity; indexed = true } );
        ( "db/ident",
          { one with Ds.unique = Some Ds.Identity; indexed = true } );
        ("block/name", one);
        ("block/title", one);
      ]
  in
  transact conn
    (List.map
       (fun (id, name, ident) ->
         [
           Ds.Add (Ds.Entity_id id, "block/uuid", Ds.Uuid name);
           Ds.Add
             ( Ds.Entity_id id,
               "block/name",
               Ds.String (String.lowercase_ascii name) );
           Ds.Add (Ds.Entity_id id, "block/title", Ds.String name);
           Ds.Add (Ds.Entity_id id, "db/ident", Ds.Keyword ident);
           Ds.Add (Ds.Entity_id id, "block/tags", Ds.Ref 1);
         ])
       [
         (1, "Tag", "logseq.class/Tag");
         (2, "Root", "logseq.class/Root");
         (3, "Journal", "logseq.class/Journal");
         (4, "Card", "logseq.class/Card");
         (5, "Task", "logseq.class/Task");
         (6, "Alpha", "user.class/alpha");
         (7, "Zeta", "user.class/zeta");
         (8, "Asset", "logseq.class/Asset");
         (9, "Page", "logseq.class/Page");
         (10, "Property", "logseq.class/Property");
         (11, "Whiteboard", "logseq.class/Whiteboard");
         (12, "Pdf", "logseq.class/Pdf-annotation");
         (13, "Comment", "logseq.class/Comment");
         (14, "Comments", "logseq.class/Comments");
       ]
     |> List.concat);
  transact conn
    [
      Ds.Add (Ds.Entity_id 20, "block/uuid", Ds.Uuid "older-use");
      Ds.Add (Ds.Entity_id 20, "block/tags", Ds.Ref 6);
    ];
  transact conn
    [
      Ds.Add (Ds.Entity_id 21, "block/uuid", Ds.Uuid "newer-use");
      Ds.Add (Ds.Entity_id 21, "block/tags", Ds.Ref 7);
    ];
  let db = Ds.conn_db conn in
  let recent =
    List.map
      (fun (e : Model.entity_summary) -> e.title)
      (Read.sidebar_pages plain db).recent_pages
  in
  let tags =
    List.map
      (fun (e : Model.entity_summary) -> e.title)
      (Read.tag_pages plain db)
  in
  check_eq (List.sort compare recent) [ "Alpha"; "Zeta" ];
  check_eq (List.sort compare tags) [ "Alpha"; "Card"; "Task"; "Zeta" ];
  check_eq
    (match tags with a :: b :: _ -> [ a; b ] | _ -> [])
    [ "Zeta"; "Alpha" ]

let page_navigation_reads_only_the_requested_reference_range () =
  let conn = new_conn [ "block/page"; "block/parent"; "block/refs" ] [] in
  transact conn
    ([ page "target" "target" "Target" [];
       page "elsewhere" "elsewhere" "Elsewhere" [];
       block "visible" "Visible" "target" "target" 1
         [ refs "block/refs" [ "target" ] ] ]
     @ List.init 8192 (fun index ->
         let uuid = "unrelated-" ^ string_of_int index in
         block uuid "Unrelated" "elsewhere" "elsewhere" index
           [ refs "block/refs" [ "elsewhere" ] ]));
  let storage = Ds.memory_storage () in
  ignore (Ds.store ~storage (Ds.conn_db conn));
  List.iter
    (fun (label, load) ->
       let reads = ref 0 in
       let measured =
         { storage with Ds.storage_restore =
             (fun address -> incr reads; storage.storage_restore address) }
       in
       let db = Option.get (Ds.restore measured) in
       reads := 0;
       let blocks = load plain db "target" in
       check_eq ~msg:(label ^ " returns only the selected page's blocks")
         (uuids blocks) [ "visible" ];
       check ~msg:(Printf.sprintf "%s reads a bounded index range: %d storage reads" label !reads)
         (!reads < 24))
    [ "page", Read.blocks_for_page; "references", Read.references_for_node ]

let large_pages_decrypt_their_shared_journal_metadata_once () =
  let conn = new_conn ["block/page"; "block/parent"; "block/created-at"; "block/journal-day"] [] in
  let page_id = "e2e30000-0000-4000-8000-000000000200" in
  transact conn (journal page_id "Shared journal" 20261019 ::
    List.init 10_000 (fun index ->
      block (Printf.sprintf "e2e30000-0000-4000-9000-%012d" index)
        "Block" page_id page_id 1 []));
  let page_reads = ref 0 in
  let decrypt title =
    if title = "Shared journal" then incr page_reads;
    Ok title
  in
  let blocks = Read.blocks_for_page decrypt (Ds.conn_db conn) page_id in
  check_eq (List.length blocks) 10_000;
  check_eq ~msg:"the same page metadata must not be queried and decrypted for every row"
    !page_reads 1;
  check (List.for_all (fun (block : Model.block) ->
    block.page_id = page_id && block.journal = Some ("Shared journal", 20261019)) blocks)

let window_conn () =
  new_conn ["block/page"; "block/parent"; "block/order"; "block/created-at";
    "logseq.property/hide?"; "logseq.property/deleted-at"; "logseq.property/view-for"]
    ["block/page", { ref_attr with Ds.indexed = true };
     "block/parent", { ref_attr with Ds.indexed = true }]

let window_uuids (window : Read.page_window) =
  List.map (fun (row : Read.page_window_row) -> row.block.uuid) window.rows

let parent_window_skips_collapsed_and_hidden_subtrees () =
  let conn = window_conn () in
  let ordered id parent order =
    block id id "window-page" parent 1 [field "block/order" (Ds.String order)] in
  transact conn [
    page "window-page" "window-page" "Page" [];
    ordered "second" "window-page" "a1";
    ordered "first" "window-page" "a0";
    ordered "never-hydrate-collapsed-child" "first" "a0";
    ordered "second-child" "second" "a0";
    ordered "last" "window-page" "a3";
    block "hidden" "never-hydrate-hidden" "window-page" "window-page" 1
      [field "block/order" (Ds.String "a2"); field "logseq.property/hide?" (Ds.Bool true)];
    ordered "never-hydrate-hidden-child" "hidden" "a0";
  ];
  let decrypted = ref [] in
  let decrypt title =
    if String.starts_with ~prefix:"never-hydrate" title then
      fail "collapsed and hidden descendants must not read titles";
    decrypted := title :: !decrypted;
    Ok title in
  let reader = Read.page_reader ~collapsed:["first"] (Ds.conn_db conn) "window-page" in
  let result = Read.read_page_window decrypt reader in
  check_eq (window_uuids result) ["first"; "second"; "second-child"; "last"];
  check_eq (List.map (fun (row : Read.page_window_row) -> row.depth) result.rows) [0; 0; 1; 0];
  check_eq (List.map (fun (row : Read.page_window_row) -> row.has_children) result.rows) [true; true; false; false];
  check_eq (List.map (fun (row : Read.page_window_row) -> row.is_collapsed) result.rows) [true; false; false; false];
  check_eq (List.rev !decrypted) ["first"; "second"; "second-child"; "last"];
  check_eq result.next_offset None

let property_value_subtrees_are_not_outline_content () =
  let conn = new_conn ["logseq.property/created-from-property"; "block/closed-value-property"; "block/journal-day"] [] in
  transact conn [
    page "property-page" "property-page" "Page" [field "block/journal-day" (Ds.Int64 20261019L)];
    entity "property" "Property" [];
    block "visible" "Visible" "property-page" "property-page" 1 [];
    block "value" "Property value" "property-page" "property-page" 0
      [field "logseq.property/created-from-property" (Ds.Ref_to (Ds.Temp_id "property"))];
    block "closed-value" "Choice value" "property-page" "property-page" 4
      [field "block/closed-value-property" (Ds.Ref_to (Ds.Temp_id "property"))];
    block "closed-value-child" "Nested choice content" "property-page" "closed-value" 5 [];
    block "value-child" "Nested property content" "property-page" "value" 3 [];
  ];
  let db = Ds.conn_db conn in
  check_eq ~msg:"whole-page reads exclude property value subtrees"
    (List.map (fun (block : Model.block) -> block.uuid) (Read.blocks_for_page plain db "property-page"))
    ["visible"];
  check_eq ~msg:"journal limits apply after property values are excluded"
    (List.map (fun (block : Model.block) -> block.uuid) (Read.blocks ~block_limit:1 plain 2 db))
    ["visible"];
  check_eq ~msg:"window reads share the same content filtering"
    (window_uuids (Read.read_page_window plain (Read.page_reader db "property-page")))
    ["visible"]

let parent_window_hydrates_only_32_rows_and_continues_without_gaps () =
  let conn = window_conn () in
  let id index = Printf.sprintf "window-%05d" index in
  transact conn (page "window-page" "window-page" "Page" [] ::
    List.init 10_000 (fun index ->
      block (id index) (id index) "window-page" "window-page" 1
        [field "block/order" (Ds.String (Printf.sprintf "a%06d" (9_999 - index)))]));
  let hydrated = ref [] in
  let decrypt title = hydrated := title :: !hydrated; Ok title in
  let reader = Read.page_reader (Ds.conn_db conn) "window-page" in
  check_eq ~msg:"creating a reader never hydrates block contents" !hydrated [];
  let first = Read.read_page_window decrypt reader in
  check_eq (window_uuids first) (List.init 32 (fun index -> id (9_999 - index)));
  check_eq ~msg:"continuation detection does not hydrate a 33rd block" (List.length !hydrated) 32;
  check_eq first.next_offset (Some 32);
  hydrated := [];
  let second = Read.read_page_window ~offset:32 decrypt reader in
  check_eq (window_uuids second) (List.init 32 (fun index -> id (9_967 - index)));
  check_eq (List.length !hydrated) 32;
  check_eq second.next_offset (Some 64);
  hydrated := [];
  let last = Read.read_page_window ~offset:9_984 decrypt reader in
  check_eq (window_uuids last) (List.init 16 (fun index -> id (15 - index)));
  check_eq ~msg:"jumping skips metadata without hydrating intervening blocks" (List.length !hydrated) 16;
  check_eq last.next_offset None;
  check_eq (window_uuids (Read.read_page_window ~offset:32 plain reader)) (window_uuids second)

let parent_window_preserves_ties_and_raw_reference_compatibility () =
  let conn = window_conn () in
  let raw e a v = Ds.Raw_datom { Ds.e; a; v; tx = 0; added = true } in
  let db = Ds.db_with [
    raw 1 "block/uuid" (Ds.Uuid "raw-window");
    raw 1 "block/name" (Ds.String "raw-window");
    raw 1 "block/title" (Ds.String "Page");
    raw 2 "block/uuid" (Ds.Uuid "later"); raw 2 "block/title" (Ds.String "Later");
    raw 2 "block/page" (Ds.Int64 1L); raw 2 "block/parent" (Ds.Int64 1L);
    raw 2 "block/order" (Ds.String "a0"); raw 2 "block/created-at" (Ds.Instant 2L);
    raw 3 "block/uuid" (Ds.Uuid "first"); raw 3 "block/title" (Ds.String "First");
    raw 3 "block/page" (Ds.Int64 1L); raw 3 "block/parent" (Ds.Int64 1L);
    raw 3 "block/order" (Ds.String "a0"); raw 3 "block/created-at" (Ds.Instant 1L);
    raw 4 "block/uuid" (Ds.Uuid "unordered"); raw 4 "block/title" (Ds.String "Unordered");
    raw 4 "block/page" (Ds.Int64 1L); raw 4 "block/parent" (Ds.Int64 1L);
  ] (Ds.conn_db conn) in
  let result = Read.read_page_window plain (Read.page_reader db "raw-window") in
  check_eq (window_uuids result) ["first"; "later"; "unordered"];
  check_eq (Read.read_page_window plain (Read.page_reader db "missing")).rows [];
  check_eq (Read.read_page_window ~limit:0 (fun _ -> fail "zero limit must not hydrate")
    (Read.page_reader db "raw-window")).rows []

let parent_window_does_not_scan_unused_entity_properties () =
  let conn = window_conn () in
  transact conn [page "window-page" "window-page" "Page" [];
    block "window-block" "Visible" "window-page" "window-page" 1
      [field "block/order" (Ds.String "a0")]];
  transact conn (List.init 10_000 (fun index ->
    Ds.Add (Ds.Lookup_ref ("block/uuid", Ds.Uuid "window-block"),
      Printf.sprintf "user.property/unused-%05d" index, Ds.String "Unused")));
  let storage = Ds.memory_storage () in
  ignore (Ds.store ~storage (Ds.conn_db conn));
  let reads = ref 0 in
  let counted = { storage with Ds.storage_restore = (fun address ->
    incr reads; storage.storage_restore address) } in
  let db = match Ds.restore counted with Some db -> db | None -> fail "missing restored db" in
  reads := 0;
  let result = Read.read_page_window plain (Read.page_reader db "window-page") in
  check_eq (window_uuids result) ["window-block"];
  check ~msg:"displaying one row must not scan 10k unrelated custom properties" (!reads < 100)

let priority_survives_graph_projection_and_cache () =
  let conn = new_conn ["block/page"; "block/parent"; "block/created-at"; "db/ident"]
    ["logseq.property/priority", ref_attr] in
  transact conn [page "page" "page" "Page" [];
    entity "high" "High" [field "db/ident" (Ds.Keyword "logseq.property/priority.high")];
    block "task" "Task" "page" "page" 1
      [field "logseq.property/priority" (Ds.Ref_to (Ds.Temp_id "high"))]];
  let blocks = Read.blocks_for_page plain (Ds.conn_db conn) "page" in
  let verify block =
    check_eq ~msg:"priority keeps master's builtin identity"
      (Yojson.Basic.Util.member "ident" (Yojson.Basic.Util.member "priority" (Rpc.block_json block)))
      (`String "logseq.property/priority.high") in
  verify (List.hd blocks);
  let cache = Model.create None in
  Model.upsert_blocks cache blocks 1;
  verify (Option.get (Model.read_block cache "task"));
  Model.upsert_blocks cache [{ (List.hd blocks) with priority = None }] 2;
  check_eq ~msg:"clearing priority removes its cached icon"
    (Yojson.Basic.Util.member "priority" (Rpc.block_json (Option.get (Model.read_block cache "task")))) `Null

let builtin_library_is_hidden_without_hiding_ordinary_pages () =
  let conn = new_conn ["block/page"; "block/parent"; "block/link"; "block/order";
    "block/updated-at"; "logseq.property/built-in?"] [] in
  transact conn [
    page "library" "library" "Library" [field "logseq.property/built-in?" (Ds.Bool true)];
    page "ordinary" "ordinary library" "Library" [];
    page "child" "project" "Project" [field "block/parent" (Ds.Ref_to (Ds.Temp_id "library"))];
    page "favorites" "$$$favorites" "Favorites" [];
    entity "library-favorite" "" [field "block/page" (Ds.Ref_to (Ds.Temp_id "favorites"));
      field "block/link" (Ds.Ref_to (Ds.Temp_id "library")); field "block/order" (Ds.String "a0")];
    entity "ordinary-favorite" "" [field "block/page" (Ds.Ref_to (Ds.Temp_id "favorites"));
      field "block/link" (Ds.Ref_to (Ds.Temp_id "ordinary")); field "block/order" (Ds.String "a1")]
  ];
  let db = Ds.conn_db conn in
  let sidebar = Read.sidebar_pages plain db in
  check_eq ~msg:"Library never appears in Favorites" (summary_uuids sidebar.favorites) ["ordinary"];
  check ~msg:"Library never appears in Recent" (not (List.mem "library" (summary_uuids sidebar.recent_pages)));
  check ~msg:"ordinary pages under Library stay visible" (List.mem "child" (summary_uuids sidebar.recent_pages));
  check_eq ~msg:"Library cannot be opened for mobile operations" (Read.node_destination plain db "library") None;
  check ~msg:"ordinary same-title pages remain navigable" (Read.node_destination plain db "ordinary" <> None);
  let path = Filename.temp_file "logseq-library-search" ".sqlite" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    let index = Search_index.create path in
    Search_index.refresh index db;
    let hits, _ = Search_index.search_hits_page ~offset:0 ~limit:20 index db "Library" in
    check_eq ~msg:"SQLite search excludes built-in Library but keeps ordinary matches"
      (List.map (fun (hit : Search_index.indexed_search_hit) -> hit.uuid) hits) ["ordinary"])

let cyclic_block_references_have_finite_rendered_projections () =
  let conn = new_conn ["block/page"; "block/parent"; "block/order"; "block/refs"] [] in
  let ids = ["10000000-0000-4000-8000-000000000001";
    "10000000-0000-4000-8000-000000000002"; "10000000-0000-4000-8000-000000000003"] in
  let check_cycle cycle =
    let nodes = List.mapi (fun index id ->
      let next = List.nth cycle ((index + 1) mod List.length cycle) in
      entity id ("[[" ^ next ^ "]]") [
        field "block/page" (Ds.Ref_to (Ds.Temp_id "page"));
        field "block/parent" (Ds.Ref_to (Ds.Temp_id "page"));
        field "block/order" (Ds.String ("a" ^ string_of_int index)); refs "block/refs" [next]]) cycle in
    transact conn (page "page" "notes" "Notes" [] :: nodes);
    let db = Ds.conn_db conn in
    let blocks = Read.blocks_for_page plain db "page" in
    List.iter (fun (block : Model.block) ->
      let response = Rpc_encode.block_json block |> Yojson.Basic.to_string in
      check ~msg:"cyclic refs serialize as finite clickable labels" (String.length response < 10000);
      check ~msg:"each ref retains its target UUID" (String_kit.includes ~sub:"nodeReference" response);
      let related = Read.references_for_node plain db block.uuid in
      check ~msg:"backlinks stay finite" (List.length related <= List.length cycle)) blocks
  in
  List.iter check_cycle [[List.hd ids]; [List.nth ids 0; List.nth ids 1]; ids]

let cases =
  [ case "builtin Library is hidden without hiding ordinary pages" builtin_library_is_hidden_without_hiding_ordinary_pages;
    case "cyclic block references have finite rendered projections" cyclic_block_references_have_finite_rendered_projections;
    case "priority survives graph projection and cache" priority_survives_graph_projection_and_cache;
    case "property value subtrees are not outline content" property_value_subtrees_are_not_outline_content;
    case "parent windows skip collapsed and hidden subtrees" parent_window_skips_collapsed_and_hidden_subtrees;
    case "parent windows hydrate 32 rows and continue without gaps" parent_window_hydrates_only_32_rows_and_continues_without_gaps;
    case "parent windows preserve ordering ties and raw references" parent_window_preserves_ties_and_raw_reference_compatibility;
    case "parent windows do not scan unused entity properties" parent_window_does_not_scan_unused_entity_properties;
    case "page navigation reads only the requested reference range"
      page_navigation_reads_only_the_requested_reference_range;
    case
      "incremental projection refreshes dependencies and evicts recycled journals"
      incremental_projection_refreshes_dependencies_and_evicts_recycled_journals;
    case
      "node navigation and related blocks respect visibility and breadcrumbs"
      node_navigation_and_related_blocks_respect_visibility_and_breadcrumbs;
    case "journals stay grouped newest first in outliner order"
      journals_stay_grouped_newest_first_in_outliner_order;
    case "transitive class cycles include tagged pages and classify assets"
      transitive_class_cycles_include_tagged_pages_and_classify_assets;
    case
      "graph blocks preserve identities instants order and decrypt journal titles"
      graph_blocks_preserve_identities_instants_order_and_decrypt_journal_titles;
    case
      "reference target renames refresh projections and public tags stay visible"
      reference_target_renames_refresh_projections_and_public_tags_stay_visible;
    case
      "sidebar favorites preserve order and exclude hidden built-in and favorite recents"
      sidebar_favorites_preserve_order_and_exclude_hidden_built_in_and_favorite_recents;
    case
      "thousand journal graphs only materialize the requested window"
      thousand_journal_graphs_only_materialize_the_requested_window;
    case "restored raw numeric references remain navigable"
      restored_raw_numeric_references_remain_navigable;
    case
      "title normalization resolves unique names and shares new tags across titles"
      title_normalization_resolves_unique_names_and_shares_new_tags_across_titles;
    case
      "recent window fills past hidden and blank pages without decrypting older pages"
      recent_window_fills_past_hidden_and_blank_pages_without_decrypting_older_pages;
    case "built-in tag filtering and recent assignment order match logseq"
      built_in_tag_filtering_and_recent_assignment_order_match_logseq;
    case "10k page blocks share journal metadata hydration"
      large_pages_decrypt_their_shared_journal_metadata_once;
  ]
