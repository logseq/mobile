open Test_util

module Ds = Datascript
module Pending = Pending_ops
module Projection = Pending_projection
module Search = Search_index
module Model = Cache_model
module Cards = Flashcards
module Codec = Storage_codec
module Store = Graph_store
module Runtime = Graph_runtime
module Transit = Transit_native.Transit.Json
module Value = Transit_core.Json
module Json = Yojson.Basic

let is_ok = function Ok _ -> true | Error _ -> false

let one = { Codec.default_schema_attr with Ds.indexed = true }
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
    ("block/created-at", number_attr);
    ("block/updated-at", number_attr);
    ("logseq.property/status", ref_attr);
    ("logseq.property.class/extends", many_ref);
    ("logseq.property/built-in?", one);
    ("logseq.property/hide?", one);
    ("logseq.property/deleted-at", number_attr);
    ("logseq.property.recycle/original-parent", ref_attr);
    ("logseq.property.recycle/original-page", ref_attr);
    ("logseq.property.recycle/original-order", string_attr);
    ("logseq.property.fsrs/due", one);
    ("logseq.property.fsrs/state", one);
  ]

let add id attr value = Ds.Add (Ds.Entity_id id, attr, value)

let base_db title =
  Ds.db_with
    [
      add 1 "block/uuid" (Ds.Uuid "page");
      add 1 "block/title" (Ds.String "Page");
      add 1 "block/name" (Ds.String "page");
      add 1 "block/journal-day" (Ds.Int64 20260816L);
      add 10 "block/uuid" (Ds.Uuid "block");
      add 10 "block/title" (Ds.String title);
      add 10 "block/page" (Ds.Ref 1);
      add 10 "block/parent" (Ds.Ref 1);
      add 10 "block/order" (Ds.String "a0");
      add 10 "block/created-at" (Ds.Int64 1L);
      add 10 "block/updated-at" (Ds.Int64 1L);
    ]
    (Ds.empty_db ~schema ())

let remove_if_exists path = if Sys.file_exists path then Sys.remove path

let with_store f =
  let path = Filename.temp_file "logseq-runtime" ".sqlite" in
  try
    Graph_sqlite.prepare_staging path;
    f path
  with e ->
    remove_if_exists path;
    remove_if_exists (Store.staging_path path);
    raise e

let () =
  ()

let cleanup_store path =
  remove_if_exists path;
  remove_if_exists (Store.staging_path path)

let save_title id before after : Pending.pending_operation =
  {
    operation_id = id;
    base_t = 42;
    state = Pending.Queued;
    intent =
      Pending.Save_title
        { uuid = "block"; expected_title = before; title = after };
  }

let prepares_save current op =
  match Runtime.prepare_sync current op with
  | Ok ("save-block", _) -> true
  | _ -> false

let with_runtime f =
  with_store (fun path ->
      let conn = Ds.conn_from_db (base_db "Old") in
      let current = Runtime.create path 42 conn Runtime.default_options in
      f path conn current)

let operation id intent : Pending.pending_operation =
  { operation_id = id; base_t = 42; state = Pending.Queued; intent }

let split_operation uuid before after new_uuid =
  Pending.Split_block
    {
      uuid;
      expected_title = before ^ after;
      before;
      after;
      new_uuid;
      new_order = "a1";
      created_at = 100;
    }

let title db uuid =
  match Pending.raw_title db uuid with
  | Ok value -> value
  | Error message -> failwith message

let rec wire_values input =
  let open Value in
  match input with
  | Array values | List values | Set values ->
    List.concat_map wire_values values
  | Map entries ->
    List.concat_map (fun (key, value) -> wire_values key @ wire_values value) entries
  | Tagged (_, value) -> wire_values value
  | _ -> [ input ]

(* Tests *)

let semantic_values_preserve_native_primitives () =
  let cases =
    [
      (Ds.String "text", Pending.String_value "text");
      (Ds.Int64 42L, Pending.Int_value 42);
      (Ds.Instant 1234L, Pending.Instant_value 1234);
      (Ds.Float 0.5, Pending.Float_value 0.5);
      (Ds.Bool false, Pending.Bool_value false);
      (Ds.Keyword "learning", Pending.Keyword_value "learning");
    ]
  in
  List.iter
    (fun (input, expected) ->
      check_eq (Pending.semantic_value_from_datascript input) (Ok expected))
    cases

let semantic_maps_preserve_nesting_entry_order_and_duplicate_keys () =
  let input =
    Ds.Map
      [
        ( Ds.Keyword "nested",
          Ds.Map [ (Ds.Keyword "flag", Ds.Bool true) ] );
        (Ds.Keyword "duplicate", Ds.Int64 1L);
        (Ds.Keyword "duplicate", Ds.Int64 2L);
      ]
  in
  let expected =
    Pending.Map_value
      [
        ("nested", Pending.Map_value [ ("flag", Pending.Bool_value true) ]);
        ("duplicate", Pending.Int_value 1);
        ("duplicate", Pending.Int_value 2);
      ]
  in
  check_eq (Pending.semantic_value_from_datascript input) (Ok expected)

let semantic_maps_reject_invalid_keys_and_unsupported_values () =
  check_eq
    (Pending.semantic_value_from_datascript
       (Ds.Map [ (Ds.String "invalid", Ds.Int64 1L); (Ds.Keyword "later", Ds.Int64 2L) ]))
    (Error "semantic map contains a non-keyword key");
  check_eq
    (Pending.semantic_value_from_datascript
       (Ds.Map [ (Ds.Keyword "invalid", Ds.Ref 42) ]))
    (Error "unsupported semantic value")

let projected_readers_share_offline_edits_without_changing_authoritative_data () =
  with_runtime (fun path conn current ->
      check (is_ok (Runtime.stage current (save_title "title" "Old" "Pending")));
      check_eq (title (Runtime.db current) "block") "Pending";
      check_eq (title (Ds.conn_db conn) "block") "Old";
      check_eq
        (List.map (fun b -> b.Model.title) (Runtime.blocks_for_page current "page"))
        [ "Pending" ];
      check_eq
        (List.map (fun b -> b.Model.title) (Runtime.blocks current))
        [ "Pending" ];
      check (Runtime.node_destination current "missing" = None);
      check (Runtime.objects_for_tag current "missing" = []);
      check (Runtime.tag_pages current = []);
      check (not (Runtime.node_is_tag current "missing"));
      check (Runtime.references_for_node current "missing" = []);
      check_eq
        (List.map (fun op -> op.Pending.operation_id) (Pending.list path))
        [ "title" ])

let favorites_update_sidebar_and_encode_the_link_transaction () =
  with_store (fun path ->
      let db =
        Ds.db_with
          [
            add 20 "block/uuid" (Ds.Uuid "favorites-page");
            add 20 "block/title" (Ds.String "Favorites");
            add 20 "block/name" (Ds.String "$$$favorites");
          ]
          (base_db "Old")
      in
      let current = Runtime.create path 42 (Ds.conn_from_db db) Runtime.default_options in
      check (is_ok (Runtime.set_page_favorite current "page" true "favorite" 100));
      check_eq
        (List.map
           (fun (p : Model.entity_summary) -> p.uuid)
           (Runtime.sidebar_pages current).Graph_read.favorites)
        [ "page" ];
      let operations = Runtime.pending_operations current in
      check_eq (List.length operations) 1;
      let op = List.hd operations in
      check_eq op.Pending.operation_id "favorite";
      check
        (match op.intent with
         | Pending.Set_favorite value -> value.favorite
         | _ -> false);
      check
        (match Runtime.prepare_sync current op with
         | Ok ("insert-blocks", wire) ->
           List.exists
             (fun v -> v = Value.Keyword "block/link")
             (wire_values (Transit.of_string wire))
         | _ -> false))

let page_deletion_is_optimistic_durable_and_rejects_built_ins () =
  with_store (fun path ->
      let db =
        Ds.db_with
          [
            Ds.Retract (Ds.Entity_id 1, "block/journal-day", Some (Ds.Int64 20260816L));
            add 20 "block/uuid" (Ds.Uuid "recycle-page");
            add 20 "block/title" (Ds.String "Recycle");
            add 20 "block/name" (Ds.String "recycle");
            add 20 "logseq.property/built-in?" (Ds.Bool true);
            add 20 "logseq.property/hide?" (Ds.Bool true);
          ]
          (base_db "Old")
      in
      let current = Runtime.create path 42 (Ds.conn_from_db db) Runtime.default_options in
      check ~msg:"deleting a page uses the server's numeric datetime schema"
        (is_ok (Runtime.delete_page current "page" "delete-page" 100));
      check_eq ~msg:"the deleted page retains its exact millisecond timestamp"
        (Graph_read.value (Runtime.db current) 1 "logseq.property/deleted-at") (Some (Ds.Int64 100L));
      check
        (not
           (List.exists
              (fun (p : Model.entity_summary) -> p.uuid = "page")
              (Runtime.sidebar_pages current).Graph_read.recent_pages));
      let operations = Runtime.pending_operations current in
      check_eq (List.length operations) 1;
      let op = List.hd operations in
      check_eq op.Pending.operation_id "delete-page";
      check
        (match op.intent with
         | Pending.Delete_page value -> value.page_uuid = "page"
         | _ -> false);
      check
        (match Runtime.prepare_sync current op with
         | Ok ("delete-page", _) -> true
         | _ -> false);
      check (not (is_ok (Runtime.delete_page current "recycle-page" "built-in" 101))))

let flashcard_review_is_one_atomic_millisecond_operation () =
  with_store (fun path ->
      let now = 1776000000000 in
      let db =
        Ds.db_with
          [
            add 20 "db/ident" (Ds.Keyword "logseq.class/Card");
            add 10 "block/tags" (Ds.Ref 20);
          ]
          (base_db "Remember this")
      in
      let current = Runtime.create path 42 (Ds.conn_from_db db) Runtime.default_options in
      check_eq
        (List.map
           (fun card -> card.Cards.block.Model.uuid)
           (Runtime.due_flashcards current now))
        [ "block" ];
      check (is_ok (Runtime.review_flashcard current "block" Cards.Good now "review"));
      check (Runtime.due_flashcards current now = []);
      let operations = Pending.list path in
      check_eq (List.length operations) 1;
      check
        (match (List.hd operations).Pending.intent with
         | Pending.Set_properties value ->
           let changes = value.changes in
           value.uuid = "block"
           && List.length changes = 2
           && (List.nth changes 0).attr = "logseq.property.fsrs/state"
           && (List.nth changes 1).attr = "logseq.property.fsrs/due"
           && (match (List.nth changes 1).value with
               | Some (Pending.Int_value _) -> true
               | _ -> false)
           && (match (List.nth changes 0).value with
               | Some (Pending.Map_value entries) ->
                 List.exists
                   (fun (key, value) ->
                     key = "last-repeat"
                     && match value with
                        | Pending.Int_value _ -> true
                        | _ -> false)
                   entries
               | _ -> false)
         | _ -> false))

let legacy_fsrs_instants_never_reach_the_wire_as_dates () =
  with_runtime (fun _path _conn current ->
      let op =
        operation "legacy-review"
          (Pending.Set_properties
             {
               uuid = "block";
               changes =
                 [
                   {
                     attr = "logseq.property.fsrs/state";
                     expected = None;
                     value =
                       Some
                         (Pending.Map_value
                            [
                              ( "last-repeat",
                                Pending.Instant_value 1776000000000 );
                              ("state", Pending.Keyword_value "review");
                            ]);
                   };
                   {
                     attr = "logseq.property.fsrs/due";
                     expected = None;
                     value = Some (Pending.Instant_value 1776086400000);
                   };
                 ];
             })
      in
      check (is_ok (Runtime.stage current op));
      check
        (match Runtime.prepare_sync current op with
         | Ok ("save-block", wire) ->
           not
             (List.exists
                (fun v -> match v with Value.Date _ -> true | _ -> false)
                (wire_values (Transit.of_string wire)))
         | _ -> false))

let split_preparation_is_atomic_and_leaves_authoritative_data_unchanged () =
  with_runtime (fun _path conn current ->
      let op = operation "split" (split_operation "block" "O" "ld" "new-block") in
      check
        (match Runtime.prepare_sync current op with
         | Ok ("split-block", wire) ->
           (match Transit.of_string wire with
            | Value.Array values -> List.length values >= 2
            | _ -> false)
         | _ -> false);
      check_eq (title (Ds.conn_db conn) "block") "Old")

let split_page_cache_preserves_nested_order_and_live_reference_metadata () =
  let run new_order expected = with_store (fun path ->
      let database = Ds.db_with
        [ add 11 "block/uuid" (Ds.Uuid "child");
          add 11 "block/title" (Ds.String "Child");
          add 11 "block/page" (Ds.Ref 1); add 11 "block/parent" (Ds.Ref 10);
          add 11 "block/order" (Ds.String "a0"); add 11 "block/refs" (Ds.Ref 10);
          add 12 "block/uuid" (Ds.Uuid "sibling");
          add 12 "block/title" (Ds.String "Sibling");
          add 12 "block/page" (Ds.Ref 1); add 12 "block/parent" (Ds.Ref 1);
          add 12 "block/order" (Ds.String "a2"); add 12 "logseq.property/status" (Ds.Ref 10);
          add 2 "block/uuid" (Ds.Uuid "other-page");
          add 2 "block/title" (Ds.String "Other page"); add 2 "block/name" (Ds.String "other page");
          add 20 "block/uuid" (Ds.Uuid "other-reference");
          add 20 "block/title" (Ds.String "Other reference");
          add 20 "block/page" (Ds.Ref 2); add 20 "block/parent" (Ds.Ref 2);
          add 20 "block/order" (Ds.String "a0"); add 20 "block/refs" (Ds.Ref 10) ]
        (base_db "Old") in
      let current = Runtime.create path 42 (Ds.conn_from_db database) Runtime.default_options in
      ignore (Runtime.blocks_for_page current "page");
      ignore (Runtime.blocks_for_page current "other-page");
      check_ok (Runtime.stage current (operation "split-cache" (Pending.Split_block {
        uuid = "block"; expected_title = "Old"; before = "O"; after = "ld";
        new_uuid = "new-block"; new_order; created_at = 100 })));
      let verify page =
        check_eq (Runtime.blocks_for_page current page)
          (Graph_read.blocks_for_page (fun value -> Ok value) (Runtime.db current) page) in
      verify "page"; verify "other-page";
      check_eq (List.map (fun b -> b.Model.uuid) (Runtime.blocks_for_page current "page"))
        expected;
      check_ok (Runtime.stage current (save_title "after-split" "O" "Edited"));
      verify "page"; verify "other-page") in
  run "a1" [ "block"; "child"; "new-block"; "sibling" ];
  run "a3" [ "block"; "child"; "sibling"; "new-block" ]

let consecutive_empty_splits_and_merges_use_the_latest_projection () =
  with_runtime (fun _path _conn current ->
      let operations =
        [
          operation "split-1" (split_operation "block" "Old" "" "empty-1");
          operation "split-2"
            (Pending.Split_block
               {
                 uuid = "empty-1";
                 expected_title = "";
                 before = "";
                 after = "";
                 new_uuid = "empty-2";
                 new_order = "a2";
                 created_at = 101;
               });
          operation "merge-1"
            (Pending.Merge_backward
               {
                 uuid = "empty-2";
                 expected_title = "";
                 title = "";
                 previous_uuid = "empty-1";
                 expected_previous_title = "";
                 merged_title = None;
               });
          operation "merge-2"
            (Pending.Merge_backward
               {
                 uuid = "empty-1";
                 expected_title = "";
                 title = "";
                 previous_uuid = "block";
                 expected_previous_title = "Old";
                 merged_title = None;
               });
        ]
      in
      List.iter (fun op -> check (is_ok (Runtime.stage current op))) operations;
      check_eq
        (List.map (fun b -> b.Model.uuid) (Runtime.blocks_for_page current "page"))
        [ "block" ])

let remote_title_changes_preserve_recorded_overlay () =
  with_runtime (fun path conn current ->
      check_ok (Runtime.stage current (save_title "title" "Old" "Pending"));
      ignore (Ds.reset_conn conn (base_db "Remote"));
      Runtime.rebase current 43 [] [];
      check_eq (title (Ds.conn_db conn) "block") "Remote";
      check_eq (title (Runtime.db current) "block") "Pending";
      check (Pending.list path <> []))

let cursor_advance_rebases_offline_edits_and_their_structural_dependencies () =
  with_runtime (fun path conn current ->
      let split =
        operation "split" (split_operation "block" "O" "ld" "dependent-new")
      in
      let edit =
        operation "edit"
          (Pending.Save_title
             { uuid = "dependent-new"; expected_title = "ld"; title = "Edited" })
      in
      check (is_ok (Runtime.stage current split));
      check (is_ok (Runtime.stage current edit));
      ignore (Ds.reset_conn conn (base_db "Old"));
      Runtime.rebase current 43 [] [];
      check_eq (title (Runtime.db current) "dependent-new") "Edited";
      let persisted = Pending.list path in
      check_eq (List.length persisted) 2;
      check
        (List.for_all
           (fun op -> op.Pending.base_t = 43 && op.state = Pending.Queued)
           persisted))

let recorded_deletions_replay_after_remote_progress () =
  with_store (fun path ->
      let uuid = "00000000-0000-4000-8000-000000000002" in
      let base title = Ds.db_with [ add 10 "block/uuid" (Ds.Uuid uuid) ] (base_db title) in
      let conn = Ds.conn_from_db (base "Old") in
      let current = Runtime.create path 42 conn Runtime.default_options in
      check_ok (Runtime.stage current
        (operation "delete" (Pending.Delete_blocks { uuids = [ uuid ] })));
      ignore (Ds.reset_conn conn (base "Remote update"));
      Runtime.rebase current 43 [] [];
      check_eq (List.length (Pending.list path)) 1;
      check_eq (Ds.entid (Runtime.db current) "block/uuid" (Ds.Uuid uuid)) None;
      check_eq (title (Ds.conn_db conn) uuid) "Remote update")

let confirmation_uses_journal_identity_and_keeps_server_corrections () =
  List.iter (fun remote ->
      with_runtime (fun path conn current ->
          check_ok (Runtime.stage current (save_title "title" "Old" "Pending"));
          ignore (Ds.reset_conn conn (base_db remote));
          Runtime.rebase current 43 [ "title" ] [];
          check_eq (Pending.list path) [];
          check_eq (title (Runtime.db current) "block") remote))
    [ "Pending"; "Server correction" ]

let rebase_replays_valid_applied_operations_and_persists_invalid_conflicts () =
  with_runtime (fun path conn _current ->
      List.iter
        (Pending.save path)
        [
          {
            (save_title "conflicted" "Old" "Ignored") with
            state = Pending.Conflicted "known";
          };
          { (save_title "applied" "Old" "Applied") with state = Pending.Applied };
          {
            (save_title "bad-applied" "Wrong" "Bad") with
            state = Pending.Applied;
          };
        ];
      ignore (Ds.reset_conn conn (base_db "Old"));
      Runtime.rebase _current 42 [] [];
      check_eq (title (Runtime.db _current) "block") "Applied";
      check
        (List.exists
           (fun op ->
             op.Pending.operation_id = "bad-applied"
             && match op.state with Pending.Conflicted _ -> true | _ -> false)
           (Pending.list path)))

let retryable_and_submitted_edits_replay_in_order () =
  with_runtime (fun path conn current ->
      List.iter
        (Pending.save path)
        [
          { (save_title "retryable" "Old" "Retry") with state = Pending.Retryable };
          {
            (save_title "submitted" "Retry" "Submit") with
            state = Pending.Submitted;
          };
        ];
      ignore (Ds.reset_conn conn (base_db "Old"));
      Runtime.rebase current 42 [] [];
      check_eq (title (Runtime.db current) "block") "Submit")

let dependent_edits_can_sync_on_an_accepted_projection () =
  with_store (fun path ->
      let current =
        Runtime.create path 42 (Ds.conn_from_db (base_db "Old"))
          Runtime.default_options
      in
      let first_op = save_title "accepted-title" "Old" "First" in
      let second_op = save_title "next-title" "First" "Second" in
      check (is_ok (Runtime.stage current first_op));
      check
        (is_ok
           (Runtime.stage current
              { first_op with state = Pending.Accepted 43 }));
      check (is_ok (Runtime.stage current second_op));
      check (prepares_save current second_op))

let stale_completions_cannot_roll_back_persisted_cursors () =
  with_store (fun path ->
      let current =
        Runtime.create path 42 (Ds.conn_from_db (base_db "Old"))
          Runtime.default_options
      in
      let first_op = save_title "in-flight-title" "Old" "First" in
      let second_op = save_title "queued-during-flight" "First" "Second" in
      check (is_ok (Runtime.stage current first_op));
      check (is_ok (Runtime.stage current second_op));
      check
        (is_ok
           (Runtime.stage current { first_op with state = Pending.Accepted 43 }));
      Runtime.rebase current 43 [] [];
      check (prepares_save current second_op);
      check
        (is_ok
           (Runtime.stage current { second_op with state = Pending.Retryable }));
      check
        (List.exists
           (fun op ->
             op.Pending.operation_id = "queued-during-flight"
             && op.base_t = 43 && op.state = Pending.Retryable)
           (Pending.list path)))

let reopen_rebases_safe_retries_and_conflicts_stale_deletions () =
  with_store (fun path ->
      Pending.save path
        {
          (save_title "retry-after-reopen" "Old" "New") with
          state = Pending.Retryable;
        };
      let current =
        Runtime.create_base path 43 (Ds.conn_from_db (base_db "Old"))
          Runtime.default_options
      in
      let persisted = Pending.list path in
      check_eq (List.length persisted) 1;
      let op = List.hd persisted in
      check_eq op.Pending.base_t 43;
      check_eq op.state Pending.Queued;
      check (prepares_save current op));
  with_store (fun path ->
      Pending.save path
        {
          operation_id = "unsafe-delete-after-reopen";
          base_t = 42;
          state = Pending.Retryable;
          intent = Pending.Delete_blocks { uuids = [ "block" ] };
        };
      ignore
        (Runtime.create_base path 43 (Ds.conn_from_db (base_db "Old"))
           Runtime.default_options);
      let persisted = Pending.list path in
      check_eq (List.length persisted) 1;
      let op = List.hd persisted in
      check_eq op.Pending.base_t 42;
      check
        (match op.state with Pending.Conflicted _ -> true | _ -> false))

let rebase_policy_keeps_stale_deletions_unsafe () =
  check
    (not
       (Pending.safe_to_rebase
          (Pending.Delete_blocks { uuids = [ "block" ] })));
  List.iter
    (fun intent -> check (Pending.safe_to_rebase intent))
    [
      Pending.Save_title
        { uuid = "block"; expected_title = "Old"; title = "New" };
      Pending.Set_property
        { uuid = "block"; attr = "block/title"; expected = None; value = None };
      Pending.Insert_block
        {
          uuid = "new";
          title = "";
          page_uuid = "page";
          parent_uuid = "page";
          order = "a1";
          created_at = 1;
        };
      Pending.Move_block
        { uuid = "block"; page_uuid = "page"; parent_uuid = "page"; order = "a0" };
      Pending.Move_blocks { moves = [] };
      Pending.Split_block
        {
          uuid = "block";
          expected_title = "Old";
          before = "";
          after = "Old";
          new_uuid = "new";
          new_order = "a1";
          created_at = 1;
        };
      Pending.Merge_backward
        {
          uuid = "block";
          expected_title = "Old";
          title = "Old";
          previous_uuid = "page";
          expected_previous_title = "Page";
          merged_title = None;
        };
    ]

let split_confirmation_requires_evidence_of_submission () =
  let db = base_db "Changed later" in
  let intent =
    Pending.Split_block
      {
        uuid = "other";
        expected_title = "Old";
        before = "O";
        after = "ld";
        new_uuid = "block";
        new_order = "a1";
        created_at = 1;
      }
  in
  let op : Pending.pending_operation =
    { operation_id = "split"; base_t = 41; state = Pending.Queued; intent }
  in
  List.iter
    (fun (state, expected) ->
      check_eq
        (Pending.committed_despite_later_changes 42 db { op with state })
        expected)
    [
      (Pending.Queued, false);
      (Pending.Retryable, false);
      (Pending.Applied, false);
      (Pending.Accepted 43, false);
      (Pending.Accepted 42, true);
      (Pending.Submitted, true);
      (Pending.Conflicted "split block UUID already exists", true);
      (Pending.Conflicted "another conflict", false);
    ];
  check
    (not
       (Pending.committed_despite_later_changes 42
          (Ds.empty_db ~schema ())
          { op with state = Pending.Submitted }))

let existing_inserts_remain_confirmed_after_later_title_changes () =
  let intent =
    Pending.Insert_block
      {
        uuid = "block";
        title = "Original";
        page_uuid = "page";
        parent_uuid = "page";
        order = "a0";
        created_at = 1;
      }
  in
  let op : Pending.pending_operation =
    { operation_id = "insert"; base_t = 41; state = Pending.Queued; intent }
  in
  check
    (Pending.committed_despite_later_changes 42 (base_db "Changed later") op);
  check
    (not
       (Pending.committed_despite_later_changes 42 (Ds.empty_db ~schema ()) op))

let with_search_runtime db f =
  with_store (fun path ->
      let search_path = Filename.temp_file "logseq-runtime-search" ".sqlite" in
      let conn = Ds.conn_from_db db in
      try
        let current =
          Runtime.create path 42 conn
            {
              Runtime.default_options with
              search_index_path = Some search_path;
            }
        in
        f search_path conn current;
        remove_if_exists search_path;
        remove_if_exists (search_path ^ "-shm");
        remove_if_exists (search_path ^ "-wal")
      with e ->
        remove_if_exists search_path;
        remove_if_exists (search_path ^ "-shm");
        remove_if_exists (search_path ^ "-wal");
        raise e)

let persisted_search_reopens_without_a_full_graph_refresh () =
  with_search_runtime (base_db "Old") (fun search_path _conn current ->
    let stored = Ds.store ~storage:(Store.storage current.path) (base_db "Old") in
    let conn = Ds.conn_from_db stored in
    let options = { Runtime.default_options with search_index_path = Some search_path } in
    let current = Runtime.create current.path 42 conn options in
    ignore (Runtime.search current "Old");
    check (is_ok (Runtime.stage current (save_title "persist-search" "Old" "Pending")));
    let reopen () = Runtime.create current.path 42
      (match Store.restore_conn current.path with Ok conn -> conn | Error e -> failwith e) options in
    let reopened = reopen () in
    check ~msg:"a valid persisted index is immediately reusable after restart"
      (Runtime.state reopened).search_index_is_fresh;
    check ~msg:"pending edits remain searchable after restart"
      (List.exists (fun hit -> hit.Search.uuid = "block") (Runtime.search reopened "Pending"));
    ignore (Ds.transact_conn conn [add 10 "block/title" (Ds.String "Remote")]);
    let changed = reopen () in
    check ~msg:"a changed storage tail invalidates the persisted index"
      (not (Runtime.state changed).search_index_is_fresh);
    ignore (Runtime.search changed "Pending");
    check (Runtime.state changed).search_index_is_fresh;
    let clean = reopen () in
    check (Runtime.state clean).search_index_is_fresh)

let incomplete_search_index_is_not_reused_after_restart () =
  with_search_runtime (base_db "Old") (fun search_path _conn current ->
    let stored = Ds.store ~storage:(Store.storage current.path) (base_db "Old") in
    let options = { Runtime.default_options with search_index_path = Some search_path } in
    let current = Runtime.create current.path 42 (Ds.conn_from_db stored) options in
    ignore (Runtime.search current "Old");
    Graph_sqlite.with_search_db search_path (fun connection ->
      ignore (Sqlite3.exec connection
        "CREATE TRIGGER reject_search_update BEFORE INSERT ON blocks BEGIN SELECT RAISE(ABORT, 'interrupted index update'); END"));
    check (is_ok (Runtime.stage current (save_title "failed-index" "Old" "Pending")));
    let conn = match Store.restore_conn current.path with Ok conn -> conn | Error e -> failwith e in
    let reopened = Runtime.create current.path 42 conn options in
    check ~msg:"an interrupted index update cannot be marked reusable"
      (not (Runtime.state reopened).search_index_is_fresh);
    Graph_sqlite.with_search_db search_path (fun connection ->
      ignore (Sqlite3.exec connection "DROP TRIGGER reject_search_update"));
    check (List.exists (fun hit -> hit.Search.uuid = "block") (Runtime.search reopened "Pending")))

let search_index_incrementally_follows_edits_and_splits () =
  with_search_runtime (base_db "Old") (fun _search_path _conn current ->
      ignore (Runtime.search current "Old");
      check (Runtime.state current).search_index_is_fresh;
      check
        (is_ok (Runtime.stage current (save_title "search-title" "Old" "Pending")));
      check (Runtime.state current).search_index_is_fresh;
      check
        (List.exists
           (fun hit -> hit.Search_index.uuid = "block")
           (Runtime.search current "Pending"));
      let split =
        operation "search-split"
          (Pending.Split_block
             {
               uuid = "block";
               expected_title = "Pending";
               before = "Head";
               after = "Tail";
               new_uuid = "search-new";
               new_order = "a1";
               created_at = 100;
             })
      in
      check (is_ok (Runtime.stage current split));
      check (Runtime.state current).search_index_is_fresh;
      check
        (List.exists
           (fun hit -> hit.Search_index.uuid = "search-new")
           (Runtime.search current "Tail")))

let unavailable_search_index_preserves_projection_and_recovers () =
  List.iter
    (fun action ->
      with_search_runtime (base_db "Old") (fun search_path conn current ->
          ignore (Runtime.search current "Old");
          check (Runtime.state current).search_index_is_fresh;
          let backup = search_path ^ ".backup" in
          Sys.rename search_path backup;
          (try
             Unix.mkdir search_path 0o700;
             (try
                (match action with
                 | `Stage ->
                   check
                     (is_ok
                        (Runtime.stage current
                           (save_title "search-outage" "Old" "Changed")))
                 | `Rebase ->
                   ignore
                     (Ds.transact_conn conn
                        [ add 10 "block/title" (Ds.String "Changed") ]);
                   Runtime.rebase current 43 [] [ "block" ]);
                check_eq (title (Runtime.db current) "block") "Changed";
                check (not (Runtime.state current).search_index_is_fresh);
                check (Runtime.search current "Changed" = [])
              with e ->
                Unix.rmdir search_path;
                raise e);
             Unix.rmdir search_path
           with e ->
             Sys.rename backup search_path;
             raise e);
          Sys.rename backup search_path;
          check
            (List.exists
               (fun hit -> hit.Search_index.uuid = "block")
               (Runtime.search current "Changed"));
          check (Runtime.state current).search_index_is_fresh))
    [ `Stage; `Rebase ]

let remote_search_refresh_preserves_unrelated_index_rows () =
  with_search_runtime (base_db "Old") (fun search_path conn current ->
      ignore (Runtime.search current "Old");
      Search.search_upsert search_path
        [ ("search-sentinel", "incremental sentinel", "search-sentinel") ];
      ignore
        (Ds.transact_conn conn [ add 10 "block/title" (Ds.String "Remote") ]);
      Runtime.rebase current 43 [] [ "block" ];
      check
        (List.exists
           (fun hit -> hit.Search_index.uuid = "block")
           (Runtime.search current "Remote"));
      check
        (match current.Runtime.search_index with
         | Some index ->
           List.exists
             (fun (hit : Search.search_result) -> hit.uuid = "search-sentinel")
             (Search.search (fun _ -> false) 100 index "incremental sentinel")
         | None -> false))

let referenced_page_renames_reindex_the_page_and_its_referrers () =
  let db =
    Ds.db_with
      [
        add 2 "block/uuid" (Ds.Uuid "target");
        add 2 "block/title" (Ds.String "Target");
        add 2 "block/name" (Ds.String "target");
        add 10 "block/refs" (Ds.Ref 2);
      ]
      (base_db "[[target]]")
  in
  with_search_runtime db (fun _search_path _conn current ->
      ignore (Runtime.search current "Target");
      let rename =
        operation "rename"
          (Pending.Save_title
             { uuid = "target"; expected_title = "Target"; title = "Renamed" })
      in
      check (is_ok (Runtime.stage current rename));
      check (Runtime.state current).search_index_is_fresh;
      let hits = Runtime.search current "Renamed" in
      List.iter
        (fun uuid ->
          check
            (List.exists (fun hit -> hit.Search_index.uuid = uuid) hits))
        [ "target"; "block" ])

let encrypted_runtime path conn =
  Runtime.create path 42 conn
    {
      Runtime.default_options with
      encrypt_title = (fun value -> Ok ("enc:" ^ value));
    }

let encrypted_sync_keeps_projection_and_pending_storage_plaintext () =
  with_store (fun path ->
      let conn = Ds.conn_from_db (base_db "Old") in
      let current = encrypted_runtime path conn in
      let op = save_title "encrypted-title" "Old" "Pending" in
      check
        (match Runtime.prepare_sync current op with
         | Ok ("save-block", wire) ->
           let values = wire_values (Transit.of_string wire) in
           List.exists (fun v -> v = Value.String "enc:Pending") values
           && not
                (List.exists
                   (fun v -> v = Value.String "Old" || v = Value.String "Pending")
                   values)
         | _ -> false);
      check (is_ok (Runtime.stage current op));
      check_eq (title (Runtime.db current) "block") "Pending";
      check_eq
        (List.map (fun b -> b.Model.title) (Runtime.blocks current))
        [ "Pending" ];
      let stored = Pending.list path in
      check_eq (List.length stored) 1;
      check
        (match (List.hd stored).Pending.intent with
         | Pending.Save_title value ->
           value.expected_title = "Old" && value.title = "Pending"
         | _ -> false))

let encrypted_merge_encrypts_the_completed_title_once () =
  with_store (fun path ->
      let db =
        Ds.db_with
          [
            add 11 "block/uuid" (Ds.Uuid "previous");
            add 11 "block/title" (Ds.String "Hello");
            add 11 "block/page" (Ds.Ref 1);
            add 11 "block/parent" (Ds.Ref 1);
            add 11 "block/order" (Ds.String "Zz");
            add 11 "block/created-at" (Ds.Int64 0L);
            add 11 "block/updated-at" (Ds.Int64 0L);
          ]
          (base_db "Old")
      in
      let current = encrypted_runtime path (Ds.conn_from_db db) in
      let op =
        operation "encrypted-merge"
          (Pending.Merge_backward
             {
               uuid = "block";
               expected_title = "Old";
               title = " World";
               previous_uuid = "previous";
               expected_previous_title = "Hello";
               merged_title = None;
             })
      in
      check
        (match Runtime.prepare_sync current op with
         | Ok ("merge-blocks", wire) ->
           List.exists
             (fun v -> v = Value.String "enc:Hello World")
             (wire_values (Transit.of_string wire))
         | _ -> false);
      check (is_ok (Runtime.stage current op));
      check_eq (title (Runtime.db current) "previous") "Hello World";
      check (Ds.entid (Runtime.db current) "block/uuid" (Ds.Uuid "block") = None))

let journal_window_grows_by_two_pages_per_request () =
  with_store (fun path ->
      let tx =
        List.concat_map
          (fun index ->
            let page = index + 1 in
            let block = index + 101 in
            [
              add page "block/uuid" (Ds.Uuid (Printf.sprintf "page-%d" index));
              add page "block/title" (Ds.String (Printf.sprintf "Page %d" index));
              add page "block/name" (Ds.String (Printf.sprintf "page-%d" index));
              add page "block/journal-day" (Ds.Int64 (Int64.of_int (20260801 + index)));
              add block "block/uuid" (Ds.Uuid (Printf.sprintf "block-%d" index));
              add block "block/title" (Ds.String (Printf.sprintf "Block %d" index));
              add block "block/page" (Ds.Ref page);
              add block "block/parent" (Ds.Ref page);
              add block "block/created-at" (Ds.Int64 (Int64.of_int index));
            ])
          (List.init 8 (fun i -> i))
      in
      let db = Ds.db_with tx (Ds.empty_db ~schema ()) in
      let current =
        Runtime.create path 42 (Ds.conn_from_db db) Runtime.default_options
      in
      check_eq (List.length (Runtime.blocks current)) 1;
      check (Runtime.has_older_journals current);
      List.iter
        (fun expected ->
          Runtime.load_older_journals current;
          check_eq (List.length (Runtime.blocks current)) expected;
          check (Runtime.has_older_journals current))
        [ 3; 5 ])

let journal_window_excludes_future_days_before_pagination () =
  let today = Model.journal_day_for_ms (int_of_float (Unix.gettimeofday () *. 1000.)) in
  List.iter (fun days -> with_store (fun path ->
      let tx = List.concat_map (fun (index, day) ->
        let page = index + 1 and block = index + 101 in
        let id = string_of_int day in
        [ add page "block/uuid" (Ds.Uuid ("page-" ^ id));
          add page "block/title" (Ds.String id);
          add page "block/name" (Ds.String id);
          add page "block/journal-day" (Ds.Int64 (Int64.of_int day));
          add block "block/uuid" (Ds.Uuid ("block-" ^ id));
          add block "block/title" (Ds.String id);
          add block "block/page" (Ds.Ref page);
          add block "block/parent" (Ds.Ref page);
          add block "block/created-at" (Ds.Int64 0L) ])
        (List.mapi (fun i day -> i, day) days) in
      let db = Ds.db_with tx (Ds.empty_db ~schema ()) in
      let current = Runtime.create path 42 (Ds.conn_from_db db) Runtime.default_options in
      let visible_days () = Runtime.blocks current |> List.filter_map
        (fun (block : Model.block) -> Option.map snd block.journal) in
      let eligible = List.filter (fun day -> day <= today) days in
      check_eq ~msg:"future journals do not occupy the initial page" (visible_days ())
        (match eligible with [] -> [] | day :: _ -> [day]);
      check_eq ~msg:"only eligible journals count toward older pages"
        (Runtime.has_older_journals current) (List.length eligible > 1);
      Runtime.load_older_journals current;
      check_eq ~msg:"pagination excludes future journals and includes today" (visible_days ()) eligible;
      check (not (Runtime.has_older_journals current));
      check_eq ~msg:"future journals remain accessible by opening their page"
        (List.length (Runtime.blocks_for_page current "page-99991231")) 1))
    [[99991231; today; 20000102; 20000101]; [99991231]]

let submitted_echoes_and_accepted_cursors_confirm_only_visible_results () =
  with_runtime (fun path conn current ->
      check
        (is_ok
           (Runtime.stage current
              { (save_title "echo" "Old" "Pending") with state = Pending.Submitted }));
      ignore (Ds.reset_conn conn (base_db "Pending"));
      Runtime.rebase current 43 [ "echo" ] [];
      check (Pending.list path = []);
      check_eq (title (Runtime.db current) "block") "Pending");
  with_runtime (fun path conn current ->
      check
        (is_ok
           (Runtime.stage current
              {
                (save_title "accepted" "Old" "Pending") with
                state = Pending.Accepted 44;
              }));
      ignore (Ds.reset_conn conn (base_db "Old"));
      Runtime.rebase current 43 [] [];
      check_eq (title (Runtime.db current) "block") "Pending";
      check_eq
        (List.map (fun op -> op.Pending.operation_id) (Pending.list path))
        [ "accepted" ];
      ignore (Ds.reset_conn conn (base_db "Pending"));
      Runtime.rebase current 44 [] [];
      check (Pending.list path = []);
      check_eq (title (Runtime.db current) "block") "Pending")

let transport_state_updates_do_not_replay_unrelated_late_rows () =
  with_runtime (fun path _conn current ->
      let op = save_title "state-only" "Old" "Pending" in
      check (is_ok (Runtime.stage current op));
      Pending.save path (save_title "unrelated" "Old" "Other");
      check
        (is_ok
           (Runtime.stage current { op with state = Pending.Accepted 44 }));
      check
        (List.exists
           (fun persisted ->
             persisted.Pending.operation_id = "state-only"
             && persisted.state = Pending.Accepted 44)
           (Pending.list path)))

let invalid_operations_never_reach_persistence_or_projection () =
  with_runtime (fun path _conn current ->
      let op =
        operation "invalid"
          (Pending.Move_block
             {
               uuid = "block";
               page_uuid = "page";
               parent_uuid = "block";
               order = "a0";
             })
      in
      check (not (is_ok (Runtime.stage current op)));
      check (Pending.list path = []);
      check_eq (title (Runtime.db current) "block") "Old")

let only_transport_recoverable_states_enter_the_send_queue () =
  with_runtime (fun path _conn current ->
      List.iter
        (fun (id, state) ->
          Pending.save path { (save_title id "Old" id) with state })
        [
          ("queued", Pending.Queued);
          ("retryable", Pending.Retryable);
          ("submitted", Pending.Submitted);
          ("accepted", Pending.Accepted 44);
          ("applied", Pending.Applied);
          ("conflicted", Pending.Conflicted "server changed");
        ];
      check_eq
        (List.map
           (fun op -> op.Pending.operation_id)
           (Runtime.pending_operations current))
        [ "queued"; "retryable"; "submitted" ])

let staging_five_hundred_offline_edits_stays_bounded () =
  with_runtime (fun _path _conn current ->
      let started = Unix.gettimeofday () in
      let rec loop index previous =
        if index <= 500 then (
          let next_title = Printf.sprintf "Offline %d" index in
          check
            (is_ok
               (Runtime.stage current
                  (save_title (Printf.sprintf "incremental-%d" index) previous
                     next_title)));
          loop (index + 1) next_title)
      in
      loop 1 "Old";
      let elapsed = Unix.gettimeofday () -. started in
      check (elapsed < 5.0);
      check_eq (title (Runtime.db current) "block") "Offline 500")

let today () =
  Model.journal_day_for_ms
    (int_of_float (Unix.gettimeofday () *. 1000.0))

let today_journal_is_canonical_atomic_and_not_duplicated_on_reopen () =
  with_store (fun path ->
      let conn = Ds.conn_from_db (Ds.empty_db ~schema ()) in
      let day = today () in
      let current =
        Runtime.create path 42 conn
          { Runtime.default_options with auto_create_today = true }
      in
      let expected =
        Printf.sprintf "00000001-%04d-%04d-0000-000000000000" (day / 10000)
          (day mod 10000)
      in
      check_eq (Runtime.journal_page_uuid current day) (Some expected);
      check_eq
        (List.map (fun b -> b.Model.title)
           (Runtime.blocks_for_page current expected))
        [ "" ];
      check_eq (List.length (Runtime.pending_operations current)) 1;
      let reopened =
        Runtime.create path 42 conn
          { Runtime.default_options with auto_create_today = true }
      in
      check_eq (List.length (Runtime.pending_operations reopened)) 1;
      check_eq
        (List.length (Runtime.blocks_for_page reopened expected))
        1)

let authoritative_today_journal_is_not_recreated () =
  with_store (fun path ->
      let day = today () in
      let db =
        Ds.db_with
          [
            add 1 "block/uuid" (Ds.Uuid "existing-today");
            add 1 "block/title" (Ds.String "Today");
            add 1 "block/name" (Ds.String "today");
            add 1 "block/journal-day" (Ds.Int64 (Int64.of_int day));
          ]
          (Ds.empty_db ~schema ())
      in
      let current =
        Runtime.create path 42 (Ds.conn_from_db db)
          { Runtime.default_options with auto_create_today = true }
      in
      check_eq (Runtime.journal_page_uuid current day) (Some "existing-today");
      check_eq ~msg:"viewing an empty journal never creates persisted filler"
        (Runtime.blocks_for_page current "existing-today") [];
      ignore (Runtime.blocks current);
      check_eq ~msg:"repeated reads preserve the authoritative empty page"
        (Runtime.pending_operations current) [])

let journal_reads_fill_a_missing_today_once () =
  List.iter (fun auto_create_today -> with_store (fun path ->
    let runtime = Runtime.create_base path 42 (Ds.conn_from_db (Ds.empty_db ~schema ()))
      {Runtime.default_options with auto_create_today} in
    check_eq (Runtime.journal_page_uuid runtime (today ())) None;
    ignore (Runtime.blocks runtime);
    if auto_create_today then begin
      check ~msg:"a long-lived graph read creates the missing local day"
        (Runtime.journal_page_uuid runtime (today ()) <> None);
      let count = List.length (Runtime.pending_operations runtime) in
      check_eq count 1;
      ignore (Runtime.blocks runtime);
      check_eq ~msg:"refresh and graph restoration do not duplicate the journal"
        (List.length (Runtime.pending_operations runtime)) count
    end else check_eq (Runtime.pending_operations runtime) [])) [true; false]

let accepted_journal_discards_its_entire_overlay () =
  with_store (fun path ->
      let conn = Ds.conn_from_db (Ds.empty_db ~schema ()) in
      let current =
        Runtime.create path 42 conn
          { Runtime.default_options with auto_create_today = true }
      in
      let operations = Pending.list path in
      check_eq (List.length operations) 1;
      let op = List.hd operations in
      check
        (is_ok
           (Runtime.stage current { op with state = Pending.Accepted 43 }));
      check
        (match op.Pending.intent with
         | Pending.Create_journal value ->
           let db =
             Ds.db_with
               [
                 add 1 "block/uuid" (Ds.Uuid value.page_uuid);
                 add 1 "block/title" (Ds.String value.title);
                 add 1 "block/name" (Ds.String value.title);
                 add 1 "block/journal-day" (Ds.Int64 (Int64.of_int value.journal_day));
               ]
               (Ds.empty_db ~schema ())
           in
           ignore (Ds.reset_conn conn db);
           Runtime.rebase current 43 [] [];
           Pending.list path = []
           && Runtime.blocks_for_page current value.page_uuid = []
         | _ -> false))

let persisted_offline_pages_reopen_for_every_transport_state () =
  List.iter
    (fun state ->
      with_runtime (fun path conn _current ->
          let payload =
            "{\"type\":\"create-page\",\"uuid\":\"offline-page\",\"title\":\"Offline \
             Page\",\"createdAt\":7}"
          in
          Pending.store_raw path "offline-page" 42 state payload;
          let current =
            Runtime.create path 43 conn Runtime.default_options
          in
          let stored = Pending.list path in
          check (Runtime.blocks current <> []);
          check_eq (title (Runtime.db current) "offline-page") "Offline Page";
          check_eq (List.length stored) 1;
          let op = List.hd stored in
          check_eq (Pending.intent_json op.Pending.intent) (Json.from_string payload);
          if state = "accepted:44" then
            check (Runtime.pending_operations current = [])
          else check (prepares_save current op);
          ignore
            (Ds.transact_conn conn
               [
                 add 20 "block/uuid" (Ds.Uuid "offline-page");
                 add 20 "block/title" (Ds.String "Server Page");
                 add 20 "block/name" (Ds.String "server page");
               ]);
          Pending.save path { op with state = Pending.Accepted 44 };
          let reopened =
            Runtime.create path 44 conn Runtime.default_options
          in
          check (Pending.list path = []);
          check_eq (title (Runtime.db reopened) "offline-page") "Server Page"))
    [ "queued"; "retryable"; "submitted"; "accepted:44" ]

let sidebar_cache_reuses_unchanged_reads_and_invalidates_on_rebase () =
  with_runtime (fun path conn current ->
      let initial = Runtime.sidebar_pages current in
      Gc.full_major ();
      let before = Gc.allocated_bytes () in
      for _ = 1 to 100 do
        ignore (Runtime.sidebar_pages current)
      done;
      check (Gc.allocated_bytes () -. before < 50000.0);
      ignore
        (Ds.transact_conn conn
           [ add 1 "block/title" (Ds.String "Remote title") ]);
      Runtime.rebase current 43 [] [];
      let remote = Runtime.sidebar_pages current in
      check (initial <> remote);
      check
        (List.exists
           (fun (p : Model.entity_summary) -> p.title = "Remote title")
           remote.Graph_read.recent_pages);
      Pending.save path
        {
          (operation "page-title"
             (Pending.Save_title
                {
                  uuid = "page";
                  expected_title = "Remote title";
                  title = "Local title";
                }))
          with
          base_t = 43;
        };
      Runtime.rebase current 43 [] [];
      check
        (List.exists
           (fun (p : Model.entity_summary) -> p.title = "Local title")
           (Runtime.sidebar_pages current).Graph_read.recent_pages);
      Pending.remove path "page-title";
      Runtime.rebase current 43 [] [];
      check (Runtime.sidebar_pages current = remote))

let startup_persists_stale_conflicts_and_restores_valid_edits () =
  with_store (fun path ->
      List.iter (Pending.save path)
        [
          save_title "stale" "Remote title" "Stale local edit";
          save_title "valid" "Old" "Valid local edit";
        ];
      let current =
        Runtime.create path 42 (Ds.conn_from_db (base_db "Old"))
          Runtime.default_options
      in
      check_eq
        (List.map
           (fun op -> op.Pending.operation_id)
           (Runtime.pending_operations current))
        [ "valid" ];
      check_eq (title (Runtime.db current) "block") "Valid local edit";
      check
        (List.exists
           (fun op ->
             op.Pending.operation_id = "stale"
             && match op.state with Pending.Conflicted _ -> true | _ -> false)
           (Pending.list path)))

let startup_split_confirmation_distinguishes_submission_from_collision () =
  List.iter
    (fun (state, cursor, confirmed) ->
      with_store (fun path ->
          let db =
            Ds.db_with
              [
                add 11 "block/uuid" (Ds.Uuid "already-created");
                add 11 "block/title" (Ds.String "Edited later");
                add 11 "block/page" (Ds.Ref 1);
                add 11 "block/parent" (Ds.Ref 1);
                add 11 "block/order" (Ds.String "a2");
                add 11 "block/created-at" (Ds.Int64 2L);
                add 11 "block/updated-at" (Ds.Int64 3L);
              ]
              (base_db "Old")
          in
          let op =
            {
              (operation "committed-split"
                 (split_operation "block" "Old" "" "already-created"))
              with
              state;
            }
          in
          Pending.save path op;
          ignore
            (Runtime.create path cursor (Ds.conn_from_db db)
               Runtime.default_options);
          let stored = Pending.list path in
          check_eq (stored = []) confirmed;
          (match state with
           | Pending.Queued | Pending.Retryable ->
             check
               (match (List.hd stored).Pending.state with
                | Pending.Conflicted _ -> true
                | _ -> false)
           | _ -> ());
          match state with
          | Pending.Conflicted "source block changed" ->
            check_eq (List.hd stored).Pending.state state
          | _ -> ()))
    [
      (Pending.Conflicted "split block UUID already exists", 43, false);
      (Pending.Submitted, 43, false);
      (Pending.Accepted 44, 43, false);
      (Pending.Accepted 44, 44, true);
      (Pending.Queued, 43, false);
      (Pending.Retryable, 43, false);
      (Pending.Conflicted "source block changed", 43, false);
    ]

let measure_allocation f =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  let result = f () in
  (result, Gc.allocated_bytes () -. before)

let startup_constructs_the_pending_projection_only_once () =
  with_runtime (fun path conn _current ->
      let operations =
        List.init 30 (fun index ->
            save_title
              (Printf.sprintf "restore-%d" index)
              (if index = 0 then "Old" else string_of_int (index - 1))
              (string_of_int index))
      in
      List.iter (Pending.save path) operations;
      let expected, projection_bytes =
        measure_allocation (fun () ->
            Projection.build 42 (Ds.conn_db conn) operations)
      in
      let current, restore_bytes =
        measure_allocation (fun () ->
            Runtime.create path 42 conn Runtime.default_options)
      in
      check_eq
        (title expected.Projection.db "block")
        (title (Runtime.db current) "block");
      check_eq
        (Runtime.operation_statuses current)
        expected.statuses;
      check_eq (title (Ds.conn_db conn) "block") "Old";
      check_eq (Pending.list path) operations;
      ignore (restore_bytes, projection_bytes);
      let reopened = Runtime.create path 42 conn Runtime.default_options in
      check_eq (title (Runtime.db reopened) "block") "29")

let insert_operation id =
  operation id
    (Pending.Insert_block
       {
         uuid = "new";
         title = "Local title";
         page_uuid = "page";
         parent_uuid = "page";
         order = "a1";
         created_at = 100;
       })

let authoritative_insert_echo_accepts_server_normalized_fields () =
  with_runtime (fun path conn current ->
      check (is_ok (Runtime.stage current (insert_operation "insert-echo")));
      ignore
        (Ds.reset_conn conn
           (Ds.db_with
              [
                add 20 "block/uuid" (Ds.Uuid "new");
                add 20 "block/title" (Ds.String "Server-normalized title");
                add 20 "block/page" (Ds.Ref 1);
                add 20 "block/parent" (Ds.Ref 1);
                add 20 "block/order" (Ds.String "a2");
              ]
              (base_db "Old")));
      Runtime.rebase current 43 [ "insert-echo" ] [];
      check (Pending.list path = []);
      check_eq (title (Runtime.db current) "new") "Server-normalized title")

let unrelated_server_progress_preserves_and_rebases_offline_inserts () =
  with_runtime (fun path conn current ->
      let op = insert_operation "offline-insert" in
      check
        (match Runtime.prepare_sync current op with
         | Ok ("insert-blocks", _) -> true
         | _ -> false);
      check (is_ok (Runtime.stage current op));
      ignore (Ds.reset_conn conn (base_db "Old"));
      Runtime.rebase current 43 [] [];
      let stored = Pending.list path in
      check_eq
        (List.map (fun op -> op.Pending.operation_id) stored)
        [ "offline-insert" ];
      check_eq (List.map (fun op -> op.Pending.base_t) stored) [ 43 ];
      check_eq
        (List.map (fun op -> op.Pending.state) stored)
        [ Pending.Queued ];
      check (is_ok (Runtime.prepare_sync current (List.hd stored)));
      check_eq (title (Runtime.db current) "new") "Local title";
      check_eq (Runtime.journal_page_uuid current 20260816) (Some "page");
      check
        (List.exists
           (fun (p : Model.entity_summary) -> p.uuid = "page")
           (Runtime.sidebar_pages current).Graph_read.recent_pages))

let stale_cursors_and_missing_titles_are_rejected_before_staging () =
  with_runtime (fun path _conn current ->
      let db = Runtime.db current in
      let without_title =
        Ds.db_with [ add 30 "block/uuid" (Ds.Uuid "without-title") ] db
      in
      let stale = { (save_title "stale" "Old" "New") with base_t = 41 } in
      let stale_error =
        Error "operation was created against a stale server cursor"
      in
      check_eq
        (Pending.raw_title db "missing")
        (Error "block no longer exists");
      check_eq
        (Pending.raw_title without_title "without-title")
        (Error "block title is missing");
      check_eq
        (Pending.normalize_expected_title db "block" "Wrong")
        (Error "title changed on the server");
      check_eq (Runtime.prepare_sync current stale) stale_error;
      check_eq (Runtime.stage current stale) stale_error;
      check (Pending.list path = []))

let pending_task_status_is_visible_without_changing_the_authoritative_ref () =
  with_store (fun path ->
      let db =
        Ds.db_with
          [
            add 20 "block/uuid" (Ds.Uuid "status-todo");
            add 20 "db/ident" (Ds.Keyword "logseq.property/status.todo");
            add 20 "block/title" (Ds.String "Todo");
            add 21 "block/uuid" (Ds.Uuid "status-doing");
            add 21 "db/ident" (Ds.Keyword "logseq.property/status.doing");
            add 21 "block/title" (Ds.String "Doing");
            add 10 "logseq.property/status" (Ds.Ref 20);
          ]
          (base_db "Task")
      in
      let conn = Ds.conn_from_db db in
      let authoritative = Ds.conn_db conn in
      let current = Runtime.create path 42 conn Runtime.default_options in
      let op =
        operation "status"
          (Pending.Set_property
             {
               uuid = "block";
               attr = "logseq.property/status";
               expected = Some (Pending.Ref_uuid "status-todo");
               value = Some (Pending.Ref_uuid "status-doing");
             })
      in
      check (is_ok (Projection.compile db op.Pending.intent));
      check (is_ok (Runtime.stage current op));
      let blocks = Runtime.blocks current in
      check_eq (List.length blocks) 1;
      check
        (match (List.hd blocks).Model.status with
         | Some status -> status.Model.uuid = "status-doing"
         | None -> false);
      check (authoritative == Ds.conn_db conn))

let title_normalization_preserves_insert_and_non_title_intents () =
  with_runtime (fun _path conn _current ->
      let insert = insert_operation "normalize-insert" in
      let intents =
        [
          Pending.Move_block
            {
              uuid = "block";
              page_uuid = "page";
              parent_uuid = "page";
              order = "a1";
            };
          Pending.Set_property
            {
              uuid = "block";
              attr = "block/title";
              expected = None;
              value = None;
            };
          Pending.Move_blocks { moves = [] };
          Pending.Delete_blocks { uuids = [ "block" ] };
        ]
      in
      check_eq
        (Pending.normalize_operation (Ds.conn_db conn) insert)
        (Ok insert);
      List.iter
        (fun intent ->
          let op = operation "passthrough" intent in
          check_eq
            (Pending.normalize_operation (Ds.conn_db conn) op)
            (Ok op))
        intents)

let status_only_properties_do_not_invalidate_search () =
  let db = base_db "Old" in
  let status =
    Pending.Set_property
      {
        uuid = "block";
        attr = "logseq.property/status";
        expected = None;
        value = Some (Pending.Ref_ident "logseq.property/status.todo");
      }
  in
  let title_intent =
    Pending.Set_property
      {
        uuid = "block";
        attr = "block/title";
        expected = Some (Pending.String_value "Old");
        value = Some (Pending.String_value "New");
      }
  in
  check (Pending.affected_uuids db status = []);
  check_eq (Pending.affected_uuids db title_intent) [ "block" ]

let safe_queued_title_rebases_to_the_latest_cursor_and_prepares_immediately () =
  with_runtime (fun path conn current ->
      check
        (is_ok
           (Runtime.stage current
              (save_title "queued-rebase" "Old" "Pending")));
      ignore (Ds.reset_conn conn (base_db "Old"));
      Runtime.rebase current 43 [] [];
      let stored = Pending.list path in
      check_eq
        (List.map (fun op -> { op with Pending.base_t = 42 }) stored)
        [ save_title "queued-rebase" "Old" "Pending" ];
      check_eq (List.map (fun op -> op.Pending.base_t) stored) [ 43 ];
      check (prepares_save current (List.hd stored)))

let property_classification_reads_the_pending_projection () =
  with_store (fun path ->
      let db =
        Ds.db_with
          [
            add 20 "block/uuid" (Ds.Uuid "property-class");
            add 20 "db/ident" (Ds.Keyword "logseq.class/Property");
          ]
          (base_db "Old")
      in
      let conn = Ds.conn_from_db db in
      let authoritative = Ds.conn_db conn in
      let current = Runtime.create path 42 conn Runtime.default_options in
      let op =
        operation "classify-property"
          (Pending.Add_tag { uuid = "block"; tag_uuid = "property-class" })
      in
      check (not (Runtime.node_is_property current "block"));
      check (is_ok (Runtime.stage current op));
      check (Runtime.node_is_property current "block");
      check (not (Runtime.node_is_property current "missing"));
      check (authoritative == Ds.conn_db conn))

let runtime_title_normalization_shares_new_tags_without_mutating_the_graph () =
  with_runtime (fun path conn current ->
      let before = Runtime.db current in
      let titles, created =
        Runtime.normalize_titles current "block"
          [ "see [[Page]] #fresh"; "#FRESH again" ]
      in
      check_eq (List.length created) 1;
      let uuid, name = List.hd created in
      check_eq name "fresh";
      check (uuid <> "");
      check_eq titles
        [
          Printf.sprintf "see [[page]] #[[%s]]" uuid;
          Printf.sprintf "#[[%s]] again" uuid;
        ];
      check (before == Runtime.db current);
      check_eq (Ds.conn_db conn).max_tx before.max_tx;
      check (Pending.list path = []))

let page_windows_follow_pending_edits_and_collapse_changes () =
  with_runtime (fun _path _conn current ->
    let first = Runtime.page_window current "page" in
    check_eq (List.map (fun (row : Graph_read.page_window_row) -> row.block.title) first.rows) ["Old"];
    let collapsed = Runtime.page_window ~collapsed:["block"] current "page" in
    check_eq (List.map (fun (row : Graph_read.page_window_row) -> row.is_collapsed) collapsed.rows) [true];
    check_eq (List.map (fun (row : Graph_read.page_window_row) -> row.is_collapsed)
      (Runtime.page_window current "page").rows) [false];
    check (is_ok (Runtime.stage current (save_title "window-edit" "Old" "New")));
    check_eq (List.map (fun (row : Graph_read.page_window_row) -> row.block.title)
      (Runtime.page_window current "page").rows) ["New"])

let upload_activation_preserves_the_staged_asset_transaction () =
  with_runtime (fun path _conn current ->
    let asset = Pending.intent_of_json (Json.from_string
      {|{"type":"create-asset","uuid":"recording","title":"recording.m4a","pageUuid":"page","parentUuid":"block","order":"a2","createdAt":100,"assetType":"m4a","assetSize":12,"assetChecksum":"abc","transcript":{"uuid":"transcript","title":"Spoken note","pageUuid":"page","parentUuid":"recording","order":"a0","createdAt":100}}|}) in
    (* A resolved pending transaction is durable even while the binary upload is pending. *)
    let staged = { (operation "asset:recording" asset) with Pending.state = Pending.Applied } in
    (* This fixture uses the same schema and actual SQLite pending log as the runtime. *)
    let before = Runtime.db current in
    let before = Ds.db_with [add 7 "db/ident" (Ds.Keyword "logseq.class/Asset")] before in
    let options = { Runtime.default_options with auto_create_today = false } in
    let current = Runtime.create path 42 (Ds.conn_from_db before) options in
    check_ok (Runtime.stage current staged);
    let restored = List.hd (Pending.list path) in
    let without_transcript = match restored.intent with
      | Pending.Create_asset value -> Pending.Create_asset { value with transcript = None }
      | _ -> failwith "expected asset" in
    check_ok (Runtime.stage current { restored with state = Pending.Queued; intent = without_transcript });
    check_eq (title (Runtime.db current) "transcript") "Spoken note";
    check (match (List.hd (Pending.list path)).intent with
      | Pending.Create_asset value -> value.transcript <> None | _ -> false))

let new_pages_appear_in_the_builtin_page_collection () =
  with_runtime (fun _path conn _ ->
    ignore (Ds.reset_conn conn (Ds.db_with [
      add 2 "db/ident" (Ds.Keyword "logseq.class/Page");
      add 2 "block/uuid" (Ds.Uuid "page-class");
      add 2 "block/title" (Ds.String "Page")
    ] (Ds.conn_db conn)));
    with_store (fun path ->
      let current = Runtime.create_base path 42 conn Runtime.default_options in
      let intent = Pending.Create_page { uuid = "new-page"; title = "New page"; created_at = 7 } in
      check (is_ok (Runtime.stage current (operation "create-page" intent)));
      check ~msg:"new pages belong to the canonical Page type used by server validation"
        (List.exists (fun (block : Model.block) -> block.uuid = "new-page")
          (Runtime.objects_for_tag current "page-class"));
      cleanup_store path))

let reopening_repairs_legacy_page_creations_and_unblocks_dependent_changes () =
  with_store (fun path -> Fun.protect ~finally:(fun () -> cleanup_store path) (fun () ->
    let page_uuid = "00000000-0000-4000-8000-000000000001" in
    let block_uuid = "00000000-0000-4000-8000-000000000010" in
    let created_uuid = "00000000-0000-4000-8000-000000000020" in
    let queued_uuid = "00000000-0000-4000-8000-000000000021" in
    let denied_uuid = "00000000-0000-4000-8000-000000000022" in
    let db = Ds.db_with [
      add 1 "block/uuid" (Ds.Uuid page_uuid);
      add 10 "block/uuid" (Ds.Uuid block_uuid);
      add 2 "db/ident" (Ds.Keyword "logseq.class/Page");
      add 2 "block/uuid" (Ds.Uuid "00000000-0000-4000-8000-000000000002");
      add 3 "block/uuid" (Ds.Uuid "00000000-0000-4000-8000-000000000003")
    ] (base_db "Old") in
    let legacy id uuid state =
      let intent = Pending.Create_page { uuid; title = "Reference target"; created_at = 7 } in
      let op = { (operation id intent) with state } in
      let projected, tx, reverse = Journal_sync.capture db [Ds.Entity {
        db_id = Some (Ds.Temp_id uuid); attrs = [
          "block/uuid", Ds.One_value (Ds.Uuid uuid);
          "block/name", Ds.One_value (Ds.String "reference target");
          "block/title", Ds.One_value (Ds.String "Reference target");
          "block/created-at", Ds.One_value (Ds.Int64 7L);
          "block/updated-at", Ds.One_value (Ds.Int64 7L)
        ] }] in
      Pending.save path op;
      Graph_sqlite.store_pending_tx path id tx reverse;
      projected in
    let projected = legacy "rejected-page" created_uuid (Pending.Conflicted "db transact failed") in
    let saved_title = "[[" ^ created_uuid ^ "]] typed after the reference" in
    let dependent = operation "dependent-save" (Pending.Save_title {
      uuid = block_uuid; expected_title = "Old"; title = saved_title }) in
    let operations = match Projection.compile projected dependent.intent with
      | Ok operations -> operations | Error message -> fail message in
    let _, tx, reverse = Journal_sync.capture projected operations in
    Pending.save path dependent;
    Graph_sqlite.store_pending_tx path dependent.operation_id tx reverse;
    ignore (legacy "queued-page" queued_uuid Pending.Queued);
    ignore (legacy "unrelated-conflict" denied_uuid (Pending.Conflicted "permission denied"));
    let untouched = Graph_sqlite.pending_tx path "unrelated-conflict" in
    let conn = Ds.conn_from_db db in
    let current = Runtime.create_base path 42 conn Runtime.default_options in
    let pending = Runtime.pending_operations current in
    check_eq ~msg:"the repaired page resumes before the operations that reference it"
      (List.map (fun (op : Pending.pending_operation) -> op.operation_id) pending)
      ["rejected-page"; "dependent-save"; "queued-page"];
    check_eq ~msg:"repair preserves the user's latest local text" (title (Runtime.db current) block_uuid) saved_title;
    let repaired = Graph_sqlite.pending_tx path "rejected-page" in
    ignore (Runtime.create_base path 42 conn Runtime.default_options);
    check_eq ~msg:"reopening an already repaired queue does not rewrite transactions"
      (Graph_sqlite.pending_tx path "rejected-page") repaired;
    List.iteri (fun index (op : Pending.pending_operation) ->
      let _, tx = match Runtime.prepare_sync current op with
        | Ok value -> value | Error message -> fail message in
      let before = (Runtime.state current).server_t in
      let journal = match Journal_sync.decode (Json.to_string (`Assoc [
        "type", `String "tx/batch/ok"; "t-before", `Int before; "t", `Int (before + 1);
        "txs", `List [`Assoc ["t", `Int (before + 1); "tx-id", `String op.operation_id; "tx", `String tx]]])) with
        | Ok value -> value | Error message -> fail message in
      check (is_ok (Runtime.stage current { op with state = Pending.Accepted (before + 1) }));
      let ids, changed = match Journal_sync.apply (fun value -> Ok value) conn before journal with
        | Ok value -> value | Error message -> fail message in
      Runtime.rebase current journal.t ids changed;
      check_eq ~msg:"each acknowledgement advances the queue"
        (List.length (Runtime.pending_operations current)) (2 - index)) pending;
    check_eq ~msg:"the recovered edits reach the authoritative graph" (title (Ds.conn_db conn) block_uuid) saved_title;
    check_eq ~msg:"other conflicts retain their original transaction" (Graph_sqlite.pending_tx path "unrelated-conflict") untouched;
    check ~msg:"other conflicts are never silently retried"
      (List.exists (fun (op : Pending.pending_operation) -> op.operation_id = "unrelated-conflict"
        && op.state = Pending.Conflicted "permission denied") (Pending.list path))))

let reopening_repairs_only_unconfirmed_legacy_page_deletion_timestamps () =
  List.iter (fun (state, repair) ->
    with_store (fun path -> Fun.protect ~finally:(fun () -> cleanup_store path) (fun () ->
      let page_uuid = "00000000-0000-4000-8000-000000000001" in
      let db = Ds.db_with [
        add 1 "block/uuid" (Ds.Uuid page_uuid);
        add 10 "block/uuid" (Ds.Uuid "00000000-0000-4000-8000-000000000010");
        Ds.Retract (Ds.Entity_id 1, "block/journal-day", Some (Ds.Int64 20260816L));
        add 20 "block/uuid" (Ds.Uuid "00000000-0000-4000-8000-000000000020");
        add 20 "block/name" (Ds.String "recycle");
        add 20 "block/title" (Ds.String "Recycle")
      ] (base_db "Old") in
      let loose_schema = List.map (fun (attr, value) ->
        if attr = "logseq.property/deleted-at" then attr, one else attr, value) schema in
      let legacy = Ds.db_with (Ds.Db.datoms db Ds.Eavt () |> List.of_seq
        |> List.map (fun (d : Ds.datom) -> add d.e d.a d.v)) (Ds.empty_db ~schema:loose_schema ()) in
      let now = 1792608926350 in
      let intent = Pending.Delete_page { page_uuid; order = "a0"; deleted_at = now } in
      let op = { (operation "legacy-delete" intent) with state } in
      let _, tx, reverse = Journal_sync.capture legacy [
        add 1 "block/parent" (Ds.Ref 20); add 1 "block/order" (Ds.String "a0");
        add 1 "logseq.property/deleted-at" (Ds.Instant (Int64.of_int now))] in
      Pending.save path op;
      Graph_sqlite.store_pending_tx path op.operation_id tx reverse;
      let before = Graph_sqlite.pending_tx path op.operation_id in
      let conn = Ds.conn_from_db db in
      let current = Runtime.create_base path 42 conn Runtime.default_options in
      if repair then begin
        check_eq ~msg:"legacy page deletions recover without changing the timestamp"
          (Graph_read.value (Runtime.db current) 1 "logseq.property/deleted-at") (Some (Ds.Int64 (Int64.of_int now)));
        check_eq ~msg:"a known validation failure can resume after repair"
          (List.map (fun (operation : Pending.pending_operation) -> operation.operation_id) (Runtime.pending_operations current)) ["legacy-delete"];
        let repaired = Graph_sqlite.pending_tx path op.operation_id in
        check ~msg:"the invalid recorded transaction is repaired" (repaired <> before);
        ignore (Runtime.create_base path 42 conn Runtime.default_options);
        check_eq ~msg:"reopening does not rewrite an already corrected operation"
          (Graph_sqlite.pending_tx path op.operation_id) repaired;
        let pending = List.hd (Runtime.pending_operations current) in
        let _, tx = match Runtime.prepare_sync current pending with Ok value -> value | Error message -> fail message in
        let journal = match Journal_sync.decode (Json.to_string (`Assoc ["type", `String "tx/batch/ok";
          "t-before", `Int 42; "t", `Int 43; "txs", `List [`Assoc ["t", `Int 43;
            "tx-id", `String pending.operation_id; "tx", `String tx]]])) with
          | Ok value -> value | Error message -> fail message in
        let ids, changed = match Journal_sync.apply (fun text -> Ok text) conn 42 journal with
          | Ok value -> value | Error message -> fail message in
        Runtime.rebase current 43 ids changed;
        check_eq ~msg:"confirmation clears the recovered deletion" (Pending.list path) []
      end else
        check_eq ~msg:"unrelated rejections and unconfirmed submissions retain their exact transaction"
          (Graph_sqlite.pending_tx path op.operation_id) before)))
    [Pending.Queued, true; Pending.Retryable, true; Pending.Conflicted "db transact failed", true;
     Pending.Conflicted "permission denied", false; Pending.Submitted, false; Pending.Accepted 43, false]


let cases =
  [
    case "reopening repairs only unconfirmed legacy page deletion timestamps" reopening_repairs_only_unconfirmed_legacy_page_deletion_timestamps;
    case "new pages appear in the built-in Page collection" new_pages_appear_in_the_builtin_page_collection;
    case "reopening repairs legacy pages and unblocks dependent changes" reopening_repairs_legacy_page_creations_and_unblocks_dependent_changes;
    case "upload activation preserves the staged asset transaction"
      upload_activation_preserves_the_staged_asset_transaction;
    case "page windows follow pending edits and collapse changes" page_windows_follow_pending_edits_and_collapse_changes;
    case "semantic values preserve native primitives"
      semantic_values_preserve_native_primitives;
    case "semantic maps preserve nesting entry order and duplicate keys"
      semantic_maps_preserve_nesting_entry_order_and_duplicate_keys;
    case "semantic maps reject invalid keys and unsupported values"
      semantic_maps_reject_invalid_keys_and_unsupported_values;
    case "projected readers share offline edits without changing authoritative data"
      projected_readers_share_offline_edits_without_changing_authoritative_data;
    case "favorites update sidebar and encode the link transaction"
      favorites_update_sidebar_and_encode_the_link_transaction;
    case "page deletion is optimistic durable and rejects built-ins"
      page_deletion_is_optimistic_durable_and_rejects_built_ins;
    case "flashcard review is one atomic millisecond operation"
      flashcard_review_is_one_atomic_millisecond_operation;
    case "legacy fsrs instants never reach the wire as dates"
      legacy_fsrs_instants_never_reach_the_wire_as_dates;
    case "split preparation is atomic and leaves authoritative data unchanged"
      split_preparation_is_atomic_and_leaves_authoritative_data_unchanged;
    case "split page cache preserves nested order and live reference metadata"
      split_page_cache_preserves_nested_order_and_live_reference_metadata;
    case "consecutive empty splits and merges use the latest projection"
      consecutive_empty_splits_and_merges_use_the_latest_projection;
    case "remote title changes preserve recorded overlay"
      remote_title_changes_preserve_recorded_overlay;
    case "cursor advance rebases offline edits and their structural dependencies"
      cursor_advance_rebases_offline_edits_and_their_structural_dependencies;
    case "recorded deletions replay after remote progress"
      recorded_deletions_replay_after_remote_progress;
    case "journal identity confirms server corrections"
      confirmation_uses_journal_identity_and_keeps_server_corrections;
    case "rebase replays valid applied operations and persists invalid conflicts"
      rebase_replays_valid_applied_operations_and_persists_invalid_conflicts;
    case "retryable and submitted edits replay in order"
      retryable_and_submitted_edits_replay_in_order;
    case "dependent edits can sync on an accepted projection"
      dependent_edits_can_sync_on_an_accepted_projection;
    case "stale completions cannot roll back persisted cursors"
      stale_completions_cannot_roll_back_persisted_cursors;
    case "reopen rebases safe retries and conflicts stale deletions"
      reopen_rebases_safe_retries_and_conflicts_stale_deletions;
    case "rebase policy keeps stale deletions unsafe"
      rebase_policy_keeps_stale_deletions_unsafe;
    case "split confirmation requires evidence of submission"
      split_confirmation_requires_evidence_of_submission;
    case "existing inserts remain confirmed after later title changes"
      existing_inserts_remain_confirmed_after_later_title_changes;
    case "persisted search reopens without a full graph refresh" persisted_search_reopens_without_a_full_graph_refresh;
    case "incomplete search index is not reused after restart" incomplete_search_index_is_not_reused_after_restart;
    case "search index incrementally follows edits and splits"
      search_index_incrementally_follows_edits_and_splits;
    case "unavailable search index preserves projection and recovers"
      unavailable_search_index_preserves_projection_and_recovers;
    case "remote search refresh preserves unrelated index rows"
      remote_search_refresh_preserves_unrelated_index_rows;
    case "referenced page renames reindex the page and its referrers"
      referenced_page_renames_reindex_the_page_and_its_referrers;
    case "encrypted sync keeps projection and pending storage plaintext"
      encrypted_sync_keeps_projection_and_pending_storage_plaintext;
    case "encrypted merge encrypts the completed title once"
      encrypted_merge_encrypts_the_completed_title_once;
    case "journal window grows by two pages per request"
      journal_window_grows_by_two_pages_per_request;
    case "journal window excludes future days before pagination"
      journal_window_excludes_future_days_before_pagination;
    case "submitted echoes and accepted cursors confirm only visible results"
      submitted_echoes_and_accepted_cursors_confirm_only_visible_results;
    case "transport state updates do not replay unrelated late rows"
      transport_state_updates_do_not_replay_unrelated_late_rows;
    case "invalid operations never reach persistence or projection"
      invalid_operations_never_reach_persistence_or_projection;
    case "only transport recoverable states enter the send queue"
      only_transport_recoverable_states_enter_the_send_queue;
    case "staging five hundred offline edits stays bounded"
      staging_five_hundred_offline_edits_stays_bounded;
    case "today journal is canonical atomic and not duplicated on reopen"
      today_journal_is_canonical_atomic_and_not_duplicated_on_reopen;
    case "authoritative today journal is not recreated"
      authoritative_today_journal_is_not_recreated;
    case "journal reads fill a missing today once" journal_reads_fill_a_missing_today_once;
    case "accepted journal discards its entire overlay"
      accepted_journal_discards_its_entire_overlay;
    case "persisted offline pages reopen for every transport state"
      persisted_offline_pages_reopen_for_every_transport_state;
    case "sidebar cache reuses unchanged reads and invalidates on rebase"
      sidebar_cache_reuses_unchanged_reads_and_invalidates_on_rebase;
    case "startup persists stale conflicts and restores valid edits"
      startup_persists_stale_conflicts_and_restores_valid_edits;
    case "startup split confirmation distinguishes submission from collision"
      startup_split_confirmation_distinguishes_submission_from_collision;
    case "startup constructs the pending projection only once"
      startup_constructs_the_pending_projection_only_once;
    case "authoritative insert echo accepts server normalized fields"
      authoritative_insert_echo_accepts_server_normalized_fields;
    case "unrelated server progress preserves and rebases offline inserts"
      unrelated_server_progress_preserves_and_rebases_offline_inserts;
    case "stale cursors and missing titles are rejected before staging"
      stale_cursors_and_missing_titles_are_rejected_before_staging;
    case "pending task status is visible without changing the authoritative ref"
      pending_task_status_is_visible_without_changing_the_authoritative_ref;
    case "title normalization preserves insert and non-title intents"
      title_normalization_preserves_insert_and_non_title_intents;
    case "status only properties do not invalidate search"
      status_only_properties_do_not_invalidate_search;
    case "safe queued title rebases to the latest cursor and prepares immediately"
      safe_queued_title_rebases_to_the_latest_cursor_and_prepares_immediately;
    case "property classification reads the pending projection"
      property_classification_reads_the_pending_projection;
    case "runtime title normalization shares new tags without mutating the graph"
      runtime_title_normalization_shares_new_tags_without_mutating_the_graph;
  ]
