open Test_util

module Read = Graph_read
module Outliner = Outliner
module Projection = Pending_projection
module Ops = Pending_ops
module Storage = Storage_codec
module Store = Graph_store
module Sqlite_store = Graph_sqlite
module Json = Yojson.Basic
module Ds = Datascript

let one = { Storage.default_schema_attr with Ds.indexed = true }
let string_attr = { one with Ds.value_type = Some Ds.StringType }
let ref_attr = { one with Ds.value_type = Some Ds.RefType }
let number_attr = { one with Ds.value_type = Some Ds.NumberType }
let many_ref = { ref_attr with Ds.cardinality = Ds.Many }

let schema : (string * Ds.schema_attr) list =
  [
    ( "block/uuid",
      {
        one with
        Ds.value_type = Some Ds.UuidType;
        unique = Some Ds.Identity;
      } );
    ( "db/ident",
      {
        one with
        Ds.value_type = Some Ds.KeywordType;
        unique = Some Ds.Identity;
      } );
    ("block/title", string_attr);
    ("block/name", string_attr);
    ("block/order", string_attr);
    ("block/page", ref_attr);
    ("block/parent", ref_attr);
    ("block/link", ref_attr);
    ("block/refs", many_ref);
    ("block/tags", many_ref);
    ("block/journal-day", number_attr);
    ("logseq.property/built-in?", one);
    ("logseq.property/hide?", one);
    ( "logseq.property/deleted-at",
      { one with Ds.value_type = Some Ds.InstantType } );
    ("logseq.property.recycle/original-parent", ref_attr);
    ("logseq.property.recycle/original-page", ref_attr);
    ("logseq.property.recycle/original-order", string_attr);
    ("logseq.property/status", ref_attr);
    ("logseq.property.class/extends", many_ref);
    ("logseq.property.asset/type", string_attr);
    ("logseq.property.asset/size", number_attr);
    ("logseq.property.asset/checksum", string_attr);
    ("logseq.property.asset/remote-metadata", Storage.default_schema_attr);
    ("logseq.property.fsrs/state", Storage.default_schema_attr);
    ("logseq.property.fsrs/due", number_attr);
    ("user.property/effort", number_attr);
    ("user.property/label", string_attr);
    ("user.property/enabled", one);
  ]

let add id attr value = Ds.Add (Ds.Entity_id id, attr, value)
let with_tx db tx = Ds.db_with tx db
let empty_schema_db () = Ds.empty_db ~schema ()
let empty_db_with ?(schema = schema) () = Ds.empty_db ~schema ()

let base_db () =
  with_tx (empty_db_with ())
    [
      add 1 "block/uuid" (Ds.Uuid "page");
      add 1 "block/title" (Ds.String "Page");
      add 1 "block/name" (Ds.String "page");
      add 2 "block/uuid" (Ds.Uuid "project");
      add 2 "block/title" (Ds.String "Project");
      add 2 "block/name" (Ds.String "project");
      add 2 "block/tags" (Ds.Ref 4);
      add 3 "block/uuid" (Ds.Uuid "old-ref");
      add 3 "block/title" (Ds.String "Old ref");
      add 3 "block/name" (Ds.String "old ref");
      add 4 "db/ident" (Ds.Keyword "logseq.class/Tag");
      add 6 "db/ident" (Ds.Keyword "logseq.class/Root");
      add 7 "db/ident" (Ds.Keyword "logseq.class/Asset");
      add 5 "block/uuid" (Ds.Uuid "non-inline-tag");
      add 5 "block/title" (Ds.String "Non-inline");
      add 5 "block/name" (Ds.String "non-inline");
      add 5 "block/tags" (Ds.Ref 4);
      add 10 "block/uuid" (Ds.Uuid "block");
      add 10 "block/title" (Ds.String "Old");
      add 10 "block/page" (Ds.Ref 1);
      add 10 "block/parent" (Ds.Ref 1);
      add 10 "block/order" (Ds.String "a0");
      add 10 "block/refs" (Ds.Ref 3);
      add 10 "block/tags" (Ds.Ref 5);
    ]

let value db uuid attr = Projection.one_value db (Projection.lookup uuid) attr

let title db uuid =
  match value db uuid "block/title" with
  | Some (Ds.String text) -> text
  | _ -> fail ("missing title: " ^ uuid)

let operation id intent : Ops.pending_operation =
  { operation_id = id; base_t = 42; state = Ops.Queued; intent }

let save_title uuid before after =
  Ops.Save_title { Ops.uuid; expected_title = before; title = after }

let property uuid attr expected value =
  Ops.Set_property { Ops.uuid; attr; expected; value }

let insert uuid title parent order =
  Ops.Insert_block
    {
      Ops.uuid;
      title;
      page_uuid = "page";
      parent_uuid = parent;
      order;
      created_at = 100;
    }

let move uuid parent order =
  Ops.Move_block
    { Ops.uuid; page_uuid = "page"; parent_uuid = parent; order }

let delete_blocks uuids = Ops.Delete_blocks { Ops.uuids }

let apply_intent db intent =
  match Projection.compile db intent with
  | Ok tx -> with_tx db tx
  | Error message -> fail message

let conflicted snapshot id =
  List.exists
    (fun (key, state) ->
      key = id
      &&
      match state with
      | Ops.Conflicted _ -> true
      | _ -> false)
    snapshot.Projection.statuses

let title_replay_updates_references_without_mutating_authoritative_db () =
  let db = base_db () in
  let snapshot =
    Projection.build 42 db
      [ operation "title" (save_title "block" "Old" "New [[Project]]") ]
  in
  let projected = snapshot.db in
  check_eq (title projected "block") "New [[Project]]";
  check (Projection.has_ref projected 10 "block/refs" 2);
  check (not (Projection.has_ref projected 10 "block/refs" 3));
  check_eq (title db "block") "Old";
  check (Projection.has_ref db 10 "block/refs" 3);
  check_eq snapshot.statuses [ ("title", Ops.Applied) ]

let title_replay_uses_markdown_references () =
  let db = base_db () in
  List.iter
    (fun source ->
      let projected = apply_intent db (save_title "block" "Old" source) in
      check_eq (title projected "block") source;
      check (not (Projection.has_ref projected 10 "block/refs" 2));
      check (not (Projection.has_ref projected 10 "block/tags" 2));
      check (Projection.has_ref projected 10 "block/tags" 5))
    [
      "[#project [[Project]]](https://example.com/#[[project]])";
      "`#[[project]] [[Project]]`";
      "```md\n#[[project]] [[Project]]\n```";
      "before\n~~~md\n#[[project]] [[Project]]\n~~~\nafter";
      "\\#project \\[[Project]]";
    ];
  let projected = apply_intent db
    (save_title "block" "Old" "`[[old-ref]]` #[[project]] **[[Page]]**") in
  check (Projection.has_ref projected 10 "block/refs" 2);
  check (Projection.has_ref projected 10 "block/refs" 1);
  check (Projection.has_ref projected 10 "block/tags" 2);
  check (not (Projection.has_ref projected 10 "block/refs" 3));
  let tagged = apply_intent db (save_title "block" "Old" "#[[project]]") in
  let quoted = apply_intent tagged
    (save_title "block" "#[[project]]" "`#[[project]]`") in
  check (not (Projection.has_ref quoted 10 "block/tags" 2))

let inline_tag_replacement_preserves_independent_tags () =
  let db = base_db () in
  let tagged = apply_intent db (save_title "block" "Old" "New #[[project]]") in
  let plain =
    apply_intent tagged (save_title "block" "New #[[project]]" "Plain")
  in
  check (Projection.has_ref tagged 10 "block/tags" 2);
  check (Projection.has_ref tagged 10 "block/tags" 5);
  check (not (Projection.has_ref plain 10 "block/tags" 2));
  check (Projection.has_ref plain 10 "block/tags" 5)

let replay_is_ordered_and_rebase_conflicts_preserve_remote_data () =
  let db = base_db () in
  let first_op = operation "first" (save_title "block" "Old" "First") in
  let second_op = operation "second" (save_title "block" "First" "Second") in
  let snapshot = Projection.build 42 db [ first_op; second_op ] in
  let remote = with_tx db [ add 10 "block/title" (Ds.String "Remote") ] in
  let rebased = Projection.build 43 remote [ first_op ] in
  check_eq (title snapshot.db "block") "Second";
  check_eq snapshot.statuses
    [ ("first", Ops.Applied); ("second", Ops.Applied) ];
  check_eq (title rebased.db "block") "Remote";
  check (conflicted rebased "first")

let properties_replay_with_compare_and_set_and_retraction () =
  let db =
    with_tx (base_db ())
      [
        add 10 "user.property/label" (Ds.String "Old label");
        add 10 "user.property/enabled" (Ds.Bool false);
      ]
  in
  let snapshot =
    Projection.build 42 db
      [
        operation "label"
          (property "block" "user.property/label"
             (Some (Ops.String_value "Old label"))
             (Some (Ops.String_value "New label")));
        operation "enabled"
          (property "block" "user.property/enabled"
             (Some (Ops.Bool_value false))
             (Some (Ops.Bool_value true)));
        operation "retract"
          (property "block" "user.property/label"
             (Some (Ops.String_value "New label"))
             None);
      ]
  in
  let projected = snapshot.db in
  check_eq (value projected "block" "user.property/label") None;
  check_eq
    (value projected "block" "user.property/enabled")
    (Some (Ds.Bool true));
  check_eq (value db "block" "user.property/label") (Some (Ds.String "Old label"));
  check
    (match
       Projection.compile projected
         (property "block" "user.property/enabled"
            (Some (Ops.Bool_value false))
            None)
     with
     | Error _ -> true
     | _ -> false)

let insertion_followed_by_move_uses_the_projected_database () =
  let db = base_db () in
  let snapshot =
    Projection.build 42 db
      [
        operation "insert"
          (insert "inserted" "Inserted [[Project]]" "block" "a1");
        operation "move" (move "inserted" "page" "a2");
      ]
  in
  let projected = snapshot.db in
  check_eq (title projected "inserted") "Inserted [[Project]]";
  check_eq (value projected "inserted" "block/parent") (Some (Ds.Ref 1));
  check_eq (value projected "inserted" "block/order") (Some (Ds.String "a2"));
  check
    (match Ds.entid projected "block/uuid" (Ds.Uuid "inserted") with
     | Some eid -> Projection.has_ref projected eid "block/refs" 2
     | None -> false);
  check_eq (Ds.entid db "block/uuid" (Ds.Uuid "inserted")) None

let recursive_delete_does_not_change_authoritative_entities () =
  let db = apply_intent (base_db ()) (insert "child" "Child" "block" "a0") in
  let snapshot =
    Projection.build 42 db [ operation "delete" (delete_blocks [ "block" ]) ]
  in
  List.iter
    (fun uuid ->
      check_eq (Ds.entid snapshot.db "block/uuid" (Ds.Uuid uuid)) None;
      check (Option.is_some (Ds.entid db "block/uuid" (Ds.Uuid uuid))))
    [ "block"; "child" ]

let invalid_targets_and_cycles_become_conflicts () =
  let db = base_db () in
  List.iter
    (fun intent ->
      let snapshot =
        Projection.build 42 db [ operation "invalid" intent ]
      in
      check (conflicted snapshot "invalid");
      check_eq (title snapshot.db "block") "Old";
      check_eq (title snapshot.db "page") "Page")
    [
      property "missing" "block/title" None
        (Some (Ops.String_value "Must not transact"));
      move "block" "block" "a0";
      insert "orphan" "Orphan" "missing" "a0";
      delete_blocks [ "page" ];
      delete_blocks [ "missing" ];
      save_title "block" "Wrong" "New";
      save_title "missing" "" "New";
      insert "block" "Duplicate" "page" "a1";
      move "block" "missing" "a1";
      Ops.Move_blocks { Ops.moves = [] };
    ]

let reference_properties_compare_stable_identities () =
  let db = base_db () in
  let snapshot =
    Projection.build 42 db
      [
        operation "status"
          (property "block" "logseq.property/status" None
             (Some (Ops.Ref_uuid "project")));
      ]
  in
  let projected = snapshot.db in
  let conflict =
    Projection.build 42 projected
      [
        operation "stale"
          (property "block" "logseq.property/status"
             (Some (Ops.Ref_uuid "old-ref"))
             None);
      ]
  in
  check_eq
    (value projected "block" "logseq.property/status")
    (Some (Ds.Ref 2));
  check (conflicted conflict "stale")

let split_and_merge_are_atomic_and_reparent_children () =
  let db = base_db () in
  let split =
    Ops.Split_block
      {
        Ops.uuid = "block";
        expected_title = "Old";
        before = "O";
        after = "ld";
        new_uuid = "split";
        new_order = "a1";
        created_at = 100;
      }
  in
  let snapshot = Projection.build 42 db [ operation "split" split ] in
  let split_db = snapshot.db in
  check_eq (title split_db "block") "O";
  check_eq (title split_db "split") "ld";
  check (Projection.satisfied split_db split);
  check_eq (title db "block") "Old";
  check_eq (Ds.entid db "block/uuid" (Ds.Uuid "split")) None;
  let with_child = apply_intent split_db (insert "child" "Child" "split" "a0") in
  let merge_intent =
    Ops.Merge_backward
      {
        Ops.uuid = "split";
        expected_title = "ld";
        title = "ld";
        previous_uuid = "block";
        expected_previous_title = "O";
        merged_title = None;
      }
  in
  let merged =
    (Projection.build 42 with_child [ operation "merge" merge_intent ]).db
  in
  check_eq (title merged "block") "Old";
  check_eq (Ds.entid merged "block/uuid" (Ds.Uuid "split")) None;
  check_eq (value merged "child" "block/parent") (Some (Ds.Ref 10));
  check
    (Option.is_some (Ds.entid with_child "block/uuid" (Ds.Uuid "split")));
  let linked =
    apply_intent db
      (Ops.Split_block
         {
           Ops.uuid = "block";
           expected_title = "Old";
           before = "O";
           after = "[[Project]]";
           new_uuid = "linked";
           new_order = "a1";
           created_at = 100;
         })
  in
  check
    (match Ds.entid linked "block/uuid" (Ds.Uuid "linked") with
     | Some eid -> Projection.has_ref linked eid "block/refs" 2
     | None -> false)

let flashcard_property_batch_is_atomic () =
  let db = base_db () in
  let state =
    Ops.Map_value
      [
        ("state", Ops.Keyword_value "learning");
        ("stability", Ops.Float_value 0.4);
        ("reps", Ops.Int_value 1);
      ]
  in
  let intent =
    Ops.Set_properties
      {
        Ops.uuid = "block";
        changes =
          [
            {
              Ops.attr = "logseq.property.fsrs/state";
              expected = None;
              value = Some state;
            };
            {
              Ops.attr = "logseq.property.fsrs/due";
              expected = None;
              value = Some (Ops.Int_value 1776000060000);
            };
          ];
      }
  in
  let projected = apply_intent db intent in
  let remote = with_tx db [ add 10 "logseq.property.fsrs/due" (Ds.Int64 99L) ] in
  check (Projection.satisfied projected intent);
  check
    (Projection.semantic_value_equal projected
       (value projected "block" "logseq.property.fsrs/state")
       (Some state));
  check_eq
    (value projected "block" "logseq.property.fsrs/due")
    (Some (Ds.Int64 1776000060000L));
  check
    (match Projection.compile remote intent with
     | Error _ -> true
     | _ -> false);
  check_eq (value remote "block" "logseq.property.fsrs/state") None

let asset_projection_keeps_upload_metadata_and_built_in_class () =
  let intent =
    Ops.Create_asset
      {
        Ops.uuid = "asset";
        title = "photo.png";
        page_uuid = "page";
        parent_uuid = "block";
        order = "a1";
        created_at = 100;
        asset_type = "png";
        asset_size = 2048;
        asset_checksum = "abc123";
        transcript = None;
      }
  in
  let db = apply_intent (base_db ()) intent in
  check (Projection.satisfied db intent);
  check_eq (title db "asset") "photo.png";
  check
    (match Ds.entid db "block/uuid" (Ds.Uuid "asset") with
     | Some eid -> Projection.has_ref db eid "block/tags" 7
     | None -> false);
  check_eq
    (value db "asset" "logseq.property.asset/type")
    (Some (Ds.String "png"));
  check_eq
    (value db "asset" "logseq.property.asset/size")
    (Some (Ds.Int64 2048L));
  check_eq
    (value db "asset" "logseq.property.asset/checksum")
    (Some (Ds.String "abc123"));
  check
    (match value db "asset" "logseq.property.asset/remote-metadata" with
     | Some (Ds.Map entries) ->
       List.exists
         (fun entry ->
           entry = (Ds.Keyword "checksum", Ds.String "abc123"))
         entries
       && List.exists
            (fun entry -> entry = (Ds.Keyword "type", Ds.String "png"))
            entries
     | _ -> false)

let with_store f =
  let path = Filename.temp_file "logseq-pending-projection" ".sqlite" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun file -> if Sys.file_exists file then Sys.remove file)
        [ path; Store.staging_path path ])
    (fun () ->
      Sqlite_store.prepare_staging path;
      f path)

let pending_storage_preserves_legacy_wire_format_and_state_transitions () =
  with_store (fun path ->
      let op =
        operation "op-persisted" (save_title "block" "Old" "Offline")
      in
      let payload =
        "{\"type\":\"save-title\",\"uuid\":\"block\",\"expectedTitle\":\"Old\",\"title\":\"Offline\"}"
      in
      Ops.store_raw path "op-persisted" 42 "queued" payload;
      check_eq (Ops.list path) [ op ];
      Ops.save path { op with state = Ops.Accepted 43 };
      check_eq (Ops.list_raw path)
        [ ("op-persisted", 42, "accepted:43", payload) ];
      List.iter
        (fun state ->
          Ops.set_state path "op-persisted" state;
          check_eq (Ops.list path) [ { op with state } ])
        [ Ops.Retryable; Ops.Submitted ];
      Ops.confirm path [ "op-persisted"; "unknown" ];
      check_eq (Ops.list path) [])

let pending_storage_upsert_preserves_insertion_order () =
  with_store (fun path ->
      let intents =
        [
          save_title "block" "Old" "你好 [[Project]]";
          property "block" "user.property/effort"
            (Some (Ops.Int_value 1))
            (Some (Ops.Int_value 2));
          insert "new" "New" "block" "a0";
          move "new" "page" "a1";
          Ops.Move_blocks
            {
              Ops.moves =
                [
                  {
                    Ops.uuid = "new";
                    page_uuid = "page";
                    parent_uuid = "block";
                    order = "a1";
                  };
                ];
            };
          Ops.Split_block
            {
              Ops.uuid = "block";
              expected_title = "Old";
              before = "O";
              after = "ld";
              new_uuid = "split";
              new_order = "a2";
              created_at = 8;
            };
          Ops.Merge_backward
            {
              Ops.uuid = "split";
              expected_title = "ld";
              title = "ld";
              previous_uuid = "block";
              expected_previous_title = "O";
              merged_title = None;
            };
          delete_blocks [ "block"; "new" ];
          Ops.Set_favorite
            {
              Ops.page_uuid = "project";
              favorite_uuid = "favorite-project";
              favorite = true;
              order = "a0";
              created_at = 9;
            };
          Ops.Delete_page
            { Ops.page_uuid = "project"; order = "a1"; deleted_at = 10 };
        ]
      in
      let operations =
        List.mapi
          (fun index intent ->
            operation (Printf.sprintf "op-%d" index) intent)
          intents
      in
      List.iter (Ops.save path) operations;
      check_eq (Ops.list path) operations;
      let replacement =
        {
          (List.hd operations) with
          state = Ops.Retryable;
          intent = save_title "block" "Old" "Replacement";
        }
      in
      Ops.save path replacement;
      check_eq
        (Ops.list path)
        (replacement :: List.tl operations))

let cursor_advance_does_not_confirm_unidentified_operations () =
  with_store (fun path ->
      let first_op =
        {
          (operation "first" (save_title "block" "Old" "First"))
          with
          state = Ops.Accepted 43;
        }
      in
      let second_op =
        {
          (operation "second" (save_title "block" "First" "Second"))
          with
          state = Ops.Submitted;
        }
      in
      List.iter (Ops.save path) [ first_op; second_op ];
      Ops.confirm path [];
      check_eq (Ops.list path) [ first_op; second_op ];
      Ops.confirm path [ "first"; "unknown" ];
      check_eq (Ops.list path) [ second_op ])

let snapshot_replacement_preserves_pending_operations () =
  with_store (fun path ->
      let op =
        operation "survives-snapshot" (save_title "block" "Old" "Offline")
      in
      Ops.save path op;
      check_ok (Store.begin_import path);
      check_ok (Store.activate path);
      check_eq (Ops.list path) [ op ])

let favorite_and_unfavorite_update_the_sidebar () =
  let db =
    with_tx (base_db ())
      [
        add 20 "block/uuid" (Ds.Uuid "favorites-page");
        add 20 "block/title" (Ds.String "Favorites");
        add 20 "block/name" (Ds.String "$$$favorites");
      ]
  in
  let favorite : Ops.pending_favorite =
    {
      page_uuid = "project";
      favorite_uuid = "favorite-project";
      favorite = true;
      order = "a0";
      created_at = 100;
    }
  in
  let on = Ops.Set_favorite favorite in
  let off = Ops.Set_favorite { favorite with favorite = false } in
  let favorited = apply_intent db on in
  let unfavorited = apply_intent favorited off in
  check (Projection.satisfied favorited on);
  check_eq
    (List.map
       (fun (e : Cache_model.entity_summary) -> e.uuid)
       (Read.sidebar_pages (fun title -> Ok title) favorited).favorites)
    [ "project" ];
  check (Projection.satisfied unfavorited off);
  check_eq
    (Read.sidebar_pages (fun title -> Ok title) unfavorited).favorites
    []

let recycling_pages_hides_descendants_and_preserves_original_location () =
  let db =
    with_tx (base_db ())
      [
        add 1 "block/parent" (Ds.Ref 6);
        add 1 "block/order" (Ds.String "a1");
        add 30 "block/uuid" (Ds.Uuid "recycle-page");
        add 30 "block/title" (Ds.String "Recycle");
        add 30 "block/name" (Ds.String "recycle");
        add 30 "logseq.property/built-in?" (Ds.Bool true);
        add 30 "logseq.property/hide?" (Ds.Bool true);
      ]
  in
  let intent =
    Ops.Delete_page
      { Ops.page_uuid = "page"; order = "a0"; deleted_at = 100 }
  in
  let recycled = apply_intent db intent in
  check (Projection.satisfied recycled intent);
  check
    (not
       (List.exists
          (fun (e : Cache_model.entity_summary) -> e.uuid = "page")
          (Read.sidebar_pages (fun title -> Ok title) recycled).recent_pages));
  List.iter
    (fun uuid ->
      check_eq
        (Read.node_destination (fun value -> Ok value) recycled uuid)
        None)
    [ "page"; "block" ];
  check_eq
    (value recycled "page" "logseq.property.recycle/original-parent")
    (Some (Ds.Ref 6));
  check_eq
    (value recycled "page" "logseq.property.recycle/original-page")
    (Some (Ds.Ref 1));
  check_eq
    (value recycled "page" "logseq.property.recycle/original-order")
    (Some (Ds.String "a1"));
  check_eq (title recycled "page") "Page"

let new_tags_can_be_referenced_by_later_pending_edits () =
  let db = base_db () in
  let intent =
    Ops.Create_tag
      { Ops.uuid = "new-tag"; title = "Foobar"; created_at = 99 }
  in
  let snapshot =
    Projection.build 42 db
      [
        operation "create" intent;
        operation "save" (save_title "block" "Old" "New #[[new-tag]]");
      ]
  in
  let projected = snapshot.db in
  check_eq (title projected "new-tag") "Foobar";
  check
    (match Ds.entid projected "block/uuid" (Ds.Uuid "new-tag") with
     | Some eid ->
       Projection.has_ref projected eid "block/tags" 4
       && Projection.has_ref projected eid "logseq.property.class/extends" 6
       && Projection.has_ref projected 10 "block/tags" eid
     | None -> false);
  check
    (match value projected "new-tag" "db/ident" with
     | Some (Ds.Keyword ident) ->
       String.starts_with ~prefix:"user.class/" ident
     | _ -> false);
  check_eq (Projection.compile projected intent) (Ok []);
  check
    (match Projection.compile (empty_db_with ()) intent with
     | Error _ -> true
     | _ -> false);
  check (Projection.satisfied projected intent);
  check (not (Projection.satisfied db intent))

let journal_intent =
  Ops.Create_journal
    {
      Ops.page_uuid = "today-page";
      block_uuid = "today-block";
      title = "Aug 22nd, 2026";
      journal_day = 20260822;
      created_at = 99;
    }

let partial_journal_creation_restores_the_missing_first_block () =
  let journal_schema =
    List.map
      (fun (name, attr) ->
        if name = "block/journal-day" then
          (name, { number_attr with Ds.unique = Some Ds.Identity })
        else (name, attr))
      schema
  in
  let db =
    with_tx
      (empty_db_with ~schema:journal_schema ())
      [
        add 20 "block/uuid" (Ds.Uuid "today-page");
        add 20 "block/title" (Ds.String "Aug 22nd, 2026");
        add 20 "block/name" (Ds.String "aug 22nd, 2026");
        add 20 "block/journal-day" (Ds.Int64 20260822L);
      ]
  in
  let snapshot =
    Projection.build 1 db
      [ { (operation "journal" journal_intent) with Ops.base_t = 0 } ]
  in
  check
    (Option.is_some
       (Ds.entid db "block/journal-day" (Ds.Int64 20260822L)));
  check_eq (Ds.entid db "block/uuid" (Ds.Uuid "today-block")) None;
  check (not (Projection.satisfied db journal_intent));
  check
    (Option.is_some
       (Ds.entid snapshot.db "block/uuid" (Ds.Uuid "today-block")));
  check (Projection.satisfied snapshot.db journal_intent)

let journals_use_the_canonical_journal_class () =
  let db =
    with_tx (empty_db_with ())
      [ add 1 "db/ident" (Ds.Keyword "logseq.class/Journal") ]
  in
  let projected =
    (Projection.build 1 db
       [ { (operation "journal" journal_intent) with Ops.base_t = 0 } ])
      .db
  in
  check
    (match Ds.entid projected "block/uuid" (Ds.Uuid "today-page") with
     | Some eid -> Projection.has_ref projected eid "block/tags" 1
     | None -> false)

let ordinary_page_creation_is_visible_and_survives_restart () =
  let intent =
    Ops.intent_of_json
      (Json.from_string
         "{\"type\":\"create-page\",\"uuid\":\"new-page\",\"title\":\"New Page\",\"createdAt\":7}")
  in
  let op = operation "create-page" intent in
  let projected = (Projection.build 42 (base_db ()) [ op ]).db in
  check_eq (title projected "new-page") "New Page";
  check
    (match Ds.entid projected "block/uuid" (Ds.Uuid "new-page") with
     | Some eid -> not (Projection.has_ref projected eid "block/tags" 4)
     | None -> false);
  check
    (List.exists
       (fun (e : Cache_model.entity_summary) -> e.uuid = "new-page")
       (Read.sidebar_pages (fun title -> Ok title) projected).recent_pages);
  with_store (fun path ->
      Ops.save path op;
      check_eq (Ops.list path) [ op ])

let semantic_equality_preserves_nested_values_and_reference_identities () =
  let db =
    with_tx (base_db ()) [ add 50 "db/ident" (Ds.Keyword "status.todo") ]
  in
  let nested =
    Ops.Map_value [ ("nested", Ops.Map_value [ ("value", Ops.Int_value 1) ]) ]
  in
  List.iter
    (fun (actual, expected) ->
      check (Projection.semantic_value_equal db (Some actual) (Some expected)))
    [
      (Ds.Instant 42L, Ops.Instant_value 42);
      (Ds.Float 1.0, Ops.Float_value 1.0);
      (Ds.Int64 1L, Ops.Float_value 1.0);
      (Ds.Int64 8L, Ops.Int_value 8);
      (Ds.Bool true, Ops.Bool_value true);
      (Ds.Ref 50, Ops.Ref_ident "status.todo");
      (Ds.Int64 50L, Ops.Ref_ident "status.todo");
      ( Ds.Map
          [
            ( Ds.Keyword "nested",
              Ds.Map [ (Ds.Keyword "value", Ds.Int64 1L) ] );
          ],
        nested );
    ];
  List.iter
    (fun actual ->
      check
        (not
           (Projection.semantic_value_equal db (Some actual) (Some nested))))
    [
      Ds.Map [];
      Ds.Map
        [
          ( Ds.String "nested",
            Ds.Map [ (Ds.Keyword "value", Ds.Int64 1L) ] );
        ];
      Ds.Map
        [
          ( Ds.Keyword "nested",
            Ds.Map [ (Ds.Keyword "value", Ds.Int64 2L) ] );
        ];
    ]

let lookup_and_title_helpers_reject_incomplete_data () =
  let db = base_db () in
  let without_tag =
    with_tx (empty_db_with ())
      [
        add 1 "block/uuid" (Ds.Uuid "project");
        add 1 "block/name" (Ds.String "project");
      ]
  in
  check_eq (Projection.page_names "[[]] [[Project]] [[") [ "Project" ];
  check_eq (Projection.page_names "plain") [];
  check_eq (Projection.inline_tag_names "#[[]] #[[unfinished") [];
  check_eq (Projection.tag_eids_for_title without_tag "#[[project]]") [];
  check_eq (value db "missing" "block/title") None;
  check_eq (value db "block" "block/refs") None;
  check_eq (Projection.uuid_for_eid db 999) None;
  List.iter
    (fun uuid -> check_eq (Projection.outliner_block db uuid) None)
    [ "missing"; "project" ];
  check_eq
    (Projection.title_tx db "new-title-target" "New")
    [
      Ds.Add
        (Projection.lookup "new-title-target", "block/title", Ds.String "New");
    ];
  check_eq
    (Projection.outliner_mutation_tx db
       (Outliner.Delete { Outliner.uuid = "missing" }))
    []

let inline_tagged_insertion_emits_one_entity_transaction () =
  let db = base_db () in
  let intent = insert "inline-tagged-insert" "New #[[project]]" "page" "a1" in
  check
    (match Projection.compile db intent with
     | Ok [ Ds.Entity entity ] ->
       List.exists (fun (attr, _) -> attr = "block/tags") entity.Ds.attrs
     | _ -> false);
  let projected = apply_intent db intent in
  check
    (match Ds.entid projected "block/uuid" (Ds.Uuid "inline-tagged-insert") with
     | Some eid -> Projection.has_ref projected eid "block/tags" 2
     | None -> false)

let raw id attr value =
  Ds.Raw_datom { Ds.e = id; a = attr; v = value; tx = 0; added = true }

let malformed_structural_references_are_not_editable () =
  let db =
    with_tx (base_db ())
      [
        add 41 "block/title" (Ds.String "No UUID");
        add 40 "block/uuid" (Ds.Uuid "dangling");
        add 40 "block/title" (Ds.String "Dangling");
        add 40 "block/page" (Ds.Ref 41);
        add 40 "block/parent" (Ds.Ref 1);
        add 40 "block/order" (Ds.String "a9");
        add 42 "block/uuid" (Ds.Uuid "malformed-ref");
        add 42 "block/title" (Ds.String "Malformed ref");
        raw 42 "block/page" (Ds.String "not-a-ref");
        add 42 "block/parent" (Ds.Ref 1);
        add 42 "block/order" (Ds.String "b0");
      ]
  in
  List.iter
    (fun uuid -> check_eq (Projection.outliner_block db uuid) None)
    [ "dangling"; "malformed-ref" ]

let raw_numeric_references_support_editing_and_recursive_deletion () =
  let db =
    with_tx (empty_db_with ())
      [
        raw 1 "block/uuid" (Ds.Uuid "raw-page");
        raw 1 "block/name" (Ds.String "raw-page");
        raw 1 "block/title" (Ds.String "Raw page");
        raw 10 "block/uuid" (Ds.Uuid "raw-parent");
        raw 10 "block/title" (Ds.String "Parent");
        raw 10 "block/page" (Ds.Int64 1L);
        raw 10 "block/parent" (Ds.Int64 1L);
        raw 10 "block/order" (Ds.String "a0");
        raw 11 "block/uuid" (Ds.Uuid "raw-child");
        raw 11 "block/title" (Ds.String "Child");
        raw 11 "block/page" (Ds.Int64 1L);
        raw 11 "block/parent" (Ds.Int64 10L);
        raw 11 "block/order" (Ds.String "a0");
      ]
  in
  let deleted = apply_intent db (delete_blocks [ "raw-parent" ]) in
  check
    (Projection.semantic_value_equal db
       (value db "raw-child" "block/parent")
       (Some (Ops.Ref_uuid "raw-parent")));
  (match Projection.outliner_block db "raw-child" with
   | Some block ->
     check_eq block.Outliner.page_uuid "raw-page";
     check_eq block.Outliner.parent_uuid "raw-parent"
   | None -> check false);
  List.iter
    (fun uuid -> check_eq (Ds.entid deleted "block/uuid" (Ds.Uuid uuid)) None)
    [ "raw-parent"; "raw-child" ]

let batch_moves_project_all_structural_updates () =
  let db =
    apply_intent
      (apply_intent (base_db ()) (insert "second" "Second" "page" "a1"))
      (insert "target" "Target" "page" "a2")
  in
  let intent =
    Ops.Move_blocks
      {
        Ops.moves =
          [
            {
              Ops.uuid = "block";
              page_uuid = "page";
              parent_uuid = "target";
              order = "a0";
            };
            {
              Ops.uuid = "second";
              page_uuid = "page";
              parent_uuid = "target";
              order = "a1";
            };
          ];
      }
  in
  let snapshot = Projection.build 42 db [ operation "batch" intent ] in
  check_eq snapshot.statuses [ ("batch", Ops.Applied) ];
  check (Projection.satisfied snapshot.db intent);
  List.iter
    (fun uuid ->
      check
        (Projection.semantic_value_equal snapshot.db
           (value snapshot.db uuid "block/parent")
           (Some (Ops.Ref_uuid "target"))))
    [ "block"; "second" ]

let built_in_status_properties_resolve_identities () =
  let db =
    with_tx (base_db ())
      [
        add 20 "db/ident" (Ds.Keyword "logseq.property/status.todo");
        add 20 "block/title" (Ds.String "Todo");
        add 21 "db/ident" (Ds.Keyword "logseq.property/status.doing");
        add 21 "block/title" (Ds.String "Doing");
        add 10 "logseq.property/status" (Ds.Ref 20);
      ]
  in
  let snapshot =
    Projection.build 42 db
      [
        operation "status"
          (property "block" "logseq.property/status"
             (Some (Ops.Ref_ident "logseq.property/status.todo"))
             (Some (Ops.Ref_ident "logseq.property/status.doing")));
      ]
  in
  check_eq
    (value snapshot.db "block" "logseq.property/status")
    (Some (Ds.Ref 21));
  check_eq snapshot.statuses [ ("status", Ops.Applied) ]

let satisfaction_checks_resulting_values_and_structure () =
  let db = base_db () in
  let insertion = insert "inserted" "Inserted" "page" "a1" in
  let inserted = apply_intent db insertion in
  let current : Ops.pending_move =
    {
      uuid = "block";
      page_uuid = "page";
      parent_uuid = "page";
      order = "a0";
    }
  in
  check (Projection.satisfied db (save_title "block" "Before" "Old"));
  check (not (Projection.satisfied db (save_title "block" "Old" "Other")));
  check
    (Projection.satisfied db
       (property "block" "user.property/label" None None));
  check
    (not
       (Projection.satisfied db
          (property "block" "user.property/label" None
             (Some (Ops.String_value "value")))));
  check (Projection.satisfied inserted insertion);
  check
    (not
       (Projection.satisfied inserted
          (insert "inserted" "Inserted" "block" "a1")));
  check (Projection.satisfied db (Ops.Move_block current));
  check
    (Projection.satisfied db (Ops.Move_blocks { Ops.moves = [ current ] }));
  check
    (not (Projection.satisfied db (Ops.Move_blocks { Ops.moves = [] })));
  check
    (not
       (Projection.satisfied db
          (Ops.Move_blocks { Ops.moves = [ { current with order = "wrong" } ] })));
  check (Projection.satisfied db (delete_blocks [ "missing" ]));
  check (not (Projection.satisfied db (delete_blocks [ "block" ])));
  let split : Ops.pending_split =
    {
      uuid = "block";
      expected_title = "Old";
      before = "O";
      after = "ld";
      new_uuid = "split";
      new_order = "a1";
      created_at = 1;
    }
  in
  let split_db = apply_intent db (Ops.Split_block split) in
  let merge_intent =
    Ops.Merge_backward
      {
        Ops.uuid = "split";
        expected_title = "ld";
        title = "ld";
        previous_uuid = "block";
        expected_previous_title = "O";
        merged_title = Some "Old";
      }
  in
  check (Projection.satisfied split_db (Ops.Split_block split));
  check
    (not
       (Projection.satisfied split_db
          (Ops.Split_block { split with new_order = "wrong" })));
  check (Projection.satisfied (apply_intent split_db merge_intent) merge_intent)

let invalid_batches_missing_pages_and_missing_split_sources_are_rejected () =
  let db = base_db () in
  let valid_move : Ops.pending_move =
    {
      uuid = "block";
      page_uuid = "page";
      parent_uuid = "page";
      order = "a1";
    }
  in
  List.iter
    (fun intent ->
      check
        (match Projection.compile db intent with
         | Error _ -> true
         | _ -> false))
    [
      Ops.Insert_block
        {
          Ops.uuid = "new";
          title = "New";
          page_uuid = "missing";
          parent_uuid = "page";
          order = "a1";
          created_at = 1;
        };
      Ops.Move_blocks
        {
          Ops.moves =
            [ valid_move; { valid_move with uuid = "missing"; order = "a2" } ];
        };
      Ops.Split_block
        {
          Ops.uuid = "missing";
          expected_title = "";
          before = "";
          after = "";
          new_uuid = "new";
          new_order = "a1";
          created_at = 1;
        };
    ];
  check_eq (value db "block" "block/order") (Some (Ds.String "a0"))

let journal_deletion_and_cyclic_parent_traversal_are_rejected () =
  let journal_db =
    with_tx (base_db ())
      [
        add 30 "block/uuid" (Ds.Uuid "journal");
        add 30 "block/title" (Ds.String "Journal");
        add 30 "block/journal-day" (Ds.Int64 20260817L);
      ]
  in
  let cyclic = with_tx (base_db ()) [ add 10 "block/parent" (Ds.Ref 10) ] in
  check
    (match Projection.compile journal_db (delete_blocks [ "journal" ]) with
     | Error _ -> true
     | _ -> false);
  check
    (match Projection.compile cyclic (move "block" "block" "a0") with
     | Error _ -> true
     | _ -> false)

let projected_properties_are_queryable_without_changing_authoritative_indexes
    () =
  let db = base_db () in
  let projected =
    (Projection.build 42 db
       [
         operation "effort"
           (property "block" "user.property/effort" None
              (Some (Ops.Int_value 8)));
       ])
      .db
  in
  check
    (List.exists
       (fun _ -> true)
       (List.of_seq
          (Ds.Db.datoms projected Ds.Aevt ~a:"user.property/effort"
             ~v:(Ds.Int64 8L) ())));
  check_eq
    (List.of_seq
       (Ds.Db.datoms db Ds.Aevt ~a:"user.property/effort" ()))
    []

let built_in_tag_db () =
  with_tx (base_db ())
    (List.concat_map (fun (eid, uuid, ident) ->
       [add eid "block/uuid" (Ds.Uuid uuid);
        add eid "db/ident" (Ds.Keyword ident);
        add eid "block/title" (Ds.String uuid);
        add eid "block/name" (Ds.String uuid);
        add eid "block/tags" (Ds.Ref 4);
        add eid "logseq.property.class/hide-from-node" (Ds.Bool true)])
       [100, "math", "logseq.class/Math-block";
        101, "quote", "logseq.class/Quote-block";
        102, "code", "logseq.class/Code-block";
        103, "task", "logseq.class/Task"]
     @ [add 104 "db/ident" (Ds.Keyword "logseq.property/status.todo");
        add 104 "block/uuid" (Ds.Uuid "todo");
        add 104 "block/title" (Ds.String "Todo");
        add 105 "db/ident" (Ds.Keyword "logseq.property/status.done");
        add 105 "block/uuid" (Ds.Uuid "done");
        add 105 "block/title" (Ds.String "Done")])

let built_in_tags_initialize_behavior_and_render_through_cache () =
  List.iter (fun kind ->
    let db = apply_intent (built_in_tag_db ())
      (Ops.Add_tag {uuid = "block"; tag_uuid = kind}) in
    check_eq ~msg:(kind ^ " initializes the display property")
      (value db "block" "logseq.property.node/display-type")
      (Some (Ds.Keyword kind));
    let verify block =
      let markup = Yojson.Basic.Util.member "markup" (Rpc.block_json block)
        |> Yojson.Basic.Util.to_list in
      check_eq ~msg:(kind ^ " reaches the native markup renderer")
        (Yojson.Basic.Util.member "type" (List.hd markup))
        (`String (if kind = "code" then "codeBlock" else kind)) in
    let block = Option.get (Read.block (fun x -> Ok x) db 10) in
    verify block;
    let window = Read.read_page_window (fun x -> Ok x) (Read.page_reader db "page") in
    verify (List.hd window.rows).block;
    let cache = Cache_model.create None in
    Cache_model.upsert_blocks cache [block] 1;
    verify (Option.get (Cache_model.read_block cache "block"));
    let plain = Option.get (Read.block (fun x -> Ok x) (base_db ()) 10) in
    Cache_model.upsert_blocks cache [plain] 2;
    check_eq ~msg:"removing the display type invalidates cached markup"
      (Yojson.Basic.Util.member "type"
        (List.hd (Yojson.Basic.Util.to_list (Yojson.Basic.Util.member "markup"
          (Rpc.block_json (Option.get (Cache_model.read_block cache "block")))))))
      (`String "text"))
    ["math"; "quote"; "code"];
  let db = apply_intent (built_in_tag_db ())
    (Ops.Add_tag {uuid = "block"; tag_uuid = "task"}) in
  check_eq ~msg:"Task initializes the Todo status"
    (value db "block" "logseq.property/status") (Some (Ds.Ref 104));
  let block = Option.get (Read.block (fun x -> Ok x) db 10) in
  check_eq (Option.map (fun (status : Cache_model.status) -> status.ident) block.status)
    (Some (Some "logseq.property/status.todo"));
  let done_db = with_tx (built_in_tag_db ()) [add 10 "logseq.property/status" (Ds.Ref 105)] in
  let done_db = apply_intent done_db (Ops.Add_tag {uuid = "block"; tag_uuid = "task"}) in
  check_eq ~msg:"adding Task preserves an existing status"
    (value done_db "block" "logseq.property/status") (Some (Ds.Ref 105));
  let ordinary = apply_intent (base_db ())
    (Ops.Add_tag {uuid = "block"; tag_uuid = "project"}) in
  check_eq ~msg:"ordinary tags do not change display type"
    (value ordinary "block" "logseq.property.node/display-type") None

let inline_built_in_tags_initialize_behavior () =
  List.iter (fun (kind, attr, expected) ->
    let db = apply_intent (built_in_tag_db ())
      (save_title "block" "Old" ("Note #[[" ^ kind ^ "]]")) in
    check_eq ~msg:("inline " ^ kind ^ " initializes its behavior")
      (value db "block" attr) (Some expected))
    ["math", "logseq.property.node/display-type", Ds.Keyword "math";
     "quote", "logseq.property.node/display-type", Ds.Keyword "quote";
     "task", "logseq.property/status", Ds.Ref 104]

let existing_display_properties_and_tagged_tasks_are_rendered () =
  let original = built_in_tag_db () in
  let db = with_tx original
    [add 10 "logseq.property.node/display-type" (Ds.Keyword "math")] in
  let block = Option.get (Read.block (fun x -> Ok x) db 10) in
  let node = List.hd (Yojson.Basic.Util.to_list
    (Yojson.Basic.Util.member "markup" (Rpc.block_json block))) in
  check_eq (Yojson.Basic.Util.member "type" node) (`String "math");
  let task_db = with_tx original [add 10 "block/tags" (Ds.Ref 103)] in
  let task = Option.get (Read.block (fun x -> Ok x) task_db 10) in
  check_eq ~msg:"existing Task tags without status still expose the default control"
    (Option.map (fun (status : Cache_model.status) -> status.ident) task.status)
    (Some (Some "logseq.property/status.todo"))

let asset_transcript_survives_persistence_and_projects_atomically () =
  let intent = Ops.intent_of_json (Yojson.Basic.from_string
    {|{"type":"create-asset","uuid":"recording","title":"recording.m4a","pageUuid":"page","parentUuid":"block","order":"a2","createdAt":100,"assetType":"m4a","assetSize":12,"assetChecksum":"abc","transcript":{"uuid":"transcript","title":"Spoken note","pageUuid":"page","parentUuid":"recording","order":"a0","createdAt":100}}|}) in
  let restored = Ops.intent_of_json (Ops.intent_json intent) in
  let before = base_db () in
  let after = apply_intent before restored in
  check_eq (title after "transcript") "Spoken note";
  check_eq (title after "recording") "recording.m4a";
  check (Projection.satisfied after restored);
  check_eq (Ds.entid before "block/uuid" (Ds.Uuid "transcript")) None

let cases =
  [ case "built-in tags initialize behavior and render through cache"
      built_in_tags_initialize_behavior_and_render_through_cache;
    case "inline built-in tags initialize behavior" inline_built_in_tags_initialize_behavior;
    case "existing display properties and tagged tasks are rendered"
      existing_display_properties_and_tagged_tasks_are_rendered ] @
  [
    case "asset transcript survives persistence and projects atomically"
      asset_transcript_survives_persistence_and_projects_atomically;
    case
      "title replay updates references without mutating authoritative db"
      title_replay_updates_references_without_mutating_authoritative_db;
    case "inline tag replacement preserves independent tags"
      inline_tag_replacement_preserves_independent_tags;
    case "title replay uses Markdown references" title_replay_uses_markdown_references;
    case "replay is ordered and rebase conflicts preserve remote data"
      replay_is_ordered_and_rebase_conflicts_preserve_remote_data;
    case "properties replay with compare and set and retraction"
      properties_replay_with_compare_and_set_and_retraction;
    case "insertion followed by move uses the projected database"
      insertion_followed_by_move_uses_the_projected_database;
    case "recursive delete does not change authoritative entities"
      recursive_delete_does_not_change_authoritative_entities;
    case "invalid targets and cycles become conflicts"
      invalid_targets_and_cycles_become_conflicts;
    case "reference properties compare stable identities"
      reference_properties_compare_stable_identities;
    case "split and merge are atomic and reparent children"
      split_and_merge_are_atomic_and_reparent_children;
    case "flashcard property batch is atomic"
      flashcard_property_batch_is_atomic;
    case "asset projection keeps upload metadata and built-in class"
      asset_projection_keeps_upload_metadata_and_built_in_class;
    case
      "pending storage preserves legacy wire format and state transitions"
      pending_storage_preserves_legacy_wire_format_and_state_transitions;
    case "pending storage upsert preserves insertion order"
      pending_storage_upsert_preserves_insertion_order;
    case "cursor advance does not confirm unidentified operations"
      cursor_advance_does_not_confirm_unidentified_operations;
    case "snapshot replacement preserves pending operations"
      snapshot_replacement_preserves_pending_operations;
    case "favorite and unfavorite update the sidebar"
      favorite_and_unfavorite_update_the_sidebar;
    case
      "recycling pages hides descendants and preserves original location"
      recycling_pages_hides_descendants_and_preserves_original_location;
    case "new tags can be referenced by later pending edits"
      new_tags_can_be_referenced_by_later_pending_edits;
    case "partial journal creation restores the missing first block"
      partial_journal_creation_restores_the_missing_first_block;
    case "journals use the canonical journal class"
      journals_use_the_canonical_journal_class;
    case "ordinary page creation is visible and survives restart"
      ordinary_page_creation_is_visible_and_survives_restart;
    case "semantic equality preserves nested values and reference identities"
      semantic_equality_preserves_nested_values_and_reference_identities;
    case "lookup and title helpers reject incomplete data"
      lookup_and_title_helpers_reject_incomplete_data;
    case "inline tagged insertion emits one entity transaction"
      inline_tagged_insertion_emits_one_entity_transaction;
    case "malformed structural references are not editable"
      malformed_structural_references_are_not_editable;
    case "raw numeric references support editing and recursive deletion"
      raw_numeric_references_support_editing_and_recursive_deletion;
    case "batch moves project all structural updates"
      batch_moves_project_all_structural_updates;
    case "built-in status properties resolve identities"
      built_in_status_properties_resolve_identities;
    case "satisfaction checks resulting values and structure"
      satisfaction_checks_resulting_values_and_structure;
    case
      "invalid batches missing pages and missing split sources are rejected"
      invalid_batches_missing_pages_and_missing_split_sources_are_rejected;
    case "journal deletion and cyclic parent traversal are rejected"
      journal_deletion_and_cyclic_parent_traversal_are_rejected;
    case
      "projected properties are queryable without changing authoritative indexes"
      projected_properties_are_queryable_without_changing_authoritative_indexes;
  ]
