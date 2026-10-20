open Test_util

module Effects = Outliner_effects
module State = Outliner_state
module Model = Cache_model
module Ops = Pending_ops

let block uuid title order : Model.block =
  {
    uuid;
    title;
    page_id = "page";
    parent_id = Some "page";
    order;
    created_at = 0;
    updated_at = 0;
    sync_status = "synced";
    tags = [];
    references = [];
    breadcrumbs = [];
    priority = None;
    status = None;
    display_type = None;
    is_asset = false;
    asset_type = None;
    asset_size = None;
    asset_checksum = None;
    local_path = None;
    journal = None;
  }

let context_for blocks = State.context blocks [] []

let context =
  context_for
    [
      block "first" "First" (Some "a0");
      block "second" "Second" (Some "a1");
      block "third" "Third" (Some "a2");
    ]

let fresh_values values =
  let index = ref 0 in
  fun () ->
    let value = List.nth values !index in
    incr index;
    value

let interpret_in context ids commands =
  Effects.interpret 42 (fun () -> 100) (fresh_values ids) context commands

let interpret commands = interpret_in context [ "operation" ] commands

let expect_ok ?(msg = "expected Ok") result =
  match result with Ok value -> value | Error message -> fail (msg ^ ": " ^ message)

let only_operation (result : Effects.outliner_effects) =
  check_eq (List.length result.operations) 1;
  match result.operations with
  | operation :: _ -> operation
  | [] -> fail "missing operation"

let split uuid before after : State.outliner_command =
  State.Split_at
    { split_uuid = uuid; split_expected_title = "Second"; before; after }

let split_generates_between_sibling_order_and_focus () =
  let result =
    expect_ok
      (interpret_in context [ "operation-1"; "new-block" ]
         [ split "second" "Sec" "ond" ])
  in
  let operation = only_operation result in
  check_eq operation.Ops.operation_id "operation-1";
  check_eq operation.base_t 42;
  (match operation.intent with
   | Ops.Split_block value ->
     check_eq value.new_uuid "new-block";
     check_eq value.created_at 100;
     check (String.compare "a1" value.new_order < 0);
     check (String.compare value.new_order "a2" < 0)
   | _ -> check false);
  check_eq result.platform [ Effects.Focus_block "new-block" ];
  let duplicates =
    context_for
      [
        block "first" "First" (Some "a0");
        block "second" "Second" (Some "a1");
        block "duplicate" "Duplicate" (Some "a1");
        block "third" "Third" (Some "a2");
      ]
  in
  let operation =
    only_operation
      (expect_ok
         (interpret_in duplicates
            [ "duplicate-operation"; "duplicate-new-block" ]
            [ split "second" "Second" "" ]))
  in
  match operation.Ops.intent with
  | Ops.Split_block value ->
    check (String.compare "a1" value.new_order < 0);
    check (String.compare value.new_order "a2" < 0)
  | _ -> check false

let explicit_task_status_and_move_batches_preserve_haptics () =
  let result =
    expect_ok
      (Effects.interpret 43 (fun () -> 100)
         (fresh_values [ "operation" ])
         context
         [
           State.Set_task_status_value
             { status_uuid = "first"; status = Ops.Ref_uuid "waiting" };
           State.Haptic State.Impact;
         ])
  in
  let operation = only_operation result in
  check_eq operation.Ops.base_t 43;
  check_eq operation.intent
    (Ops.Set_property
       {
         uuid = "first";
         attr = "logseq.property/status";
         expected = None;
         value = Some (Ops.Ref_uuid "waiting");
       });
  check_eq result.platform
    [ Effects.Platform_haptic State.Impact ];
  let move : Ops.pending_move =
    { uuid = "second"; page_uuid = "page"; parent_uuid = "first"; order = "a0" }
  in
  let result =
    expect_ok (interpret [ State.Reparent_blocks [ move ]; State.Haptic State.Impact ])
  in
  check_eq (only_operation result).Ops.intent
    (Ops.Move_blocks { moves = [ move ] });
  check_eq result.platform [ Effects.Platform_haptic State.Impact ]

let task_cycle_without_status_stays_a_semantic_operation () =
  let result = expect_ok (interpret [ State.Cycle_task_status "first" ]) in
  check_eq (only_operation result).Ops.intent
    (Ops.Set_property
       {
         uuid = "first";
         attr = "logseq.property/status";
         expected = None;
         value = Some (Ops.Ref_ident "logseq.property/status.todo");
       });
  check_eq result.platform []

let platform_commands_map_exactly_without_semantic_operations () =
  List.iter
    (fun (command, expected) ->
      let result = expect_ok (interpret [ command ]) in
      check_eq result.operations [];
      check_eq result.platform [ expected ])
    [
      (State.Haptic State.Selection, Effects.Platform_haptic State.Selection);
      (State.Pick_attachment "first", Effects.Platform_pick_attachment "first");
      (State.Record_audio "first", Effects.Platform_record_audio "first");
      (State.Take_photo "first", Effects.Platform_take_photo "first");
      (State.Copy_text "First", Effects.Set_clipboard_text "First");
      ( State.Copy_references [ "first" ],
        Effects.Set_clipboard_references [ "first" ] );
      (State.Copy_urls [ "first" ], Effects.Set_clipboard_urls [ "first" ]);
      ( State.Request_delete_confirmation [ "first" ],
        Effects.Confirm_delete [ "first" ] );
    ]

let missing_sibling_orders_sort_after_orders_then_by_uuid () =
  let context =
    context_for
      [
        block "z" "Z" None;
        block "ordered" "Ordered" (Some "a0");
        block "a" "A" None;
      ]
  in
  check_eq
    (List.map (fun (b : Model.block) -> b.uuid)
       (Effects.sorted_siblings context (Some "page")))
    [ "ordered"; "a"; "z" ]

let invalid_commands_fail_and_empty_delete_is_a_no_op () =
  check_eq (interpret [ split "missing" "" "" ])
    (Error "split source no longer exists");
  check_eq (interpret [ State.Reparent_blocks [] ])
    (Error "move batch must not be empty");
  check_eq (interpret [ State.Cycle_task_status "missing" ])
    (Error "task block no longer exists");
  check_eq
    (interpret
       [
         State.Set_task_status_value
           { status_uuid = "missing"; status = Ops.Ref_uuid "todo" };
       ])
    (Error "task block no longer exists");
  check_eq (interpret [ State.Remove_blocks [] ])
    (Ok (Effects.result [] []));
  check_eq
    (only_operation
       (expect_ok (interpret [ State.Remove_blocks [ "first" ] ]))).Ops.intent
    (Ops.Delete_blocks { uuids = [ "first" ] })

let title_commit_is_guarded_and_merge_focuses_the_survivor () =
  let title : Ops.pending_title =
    { uuid = "first"; expected_title = "First"; title = "Edited" }
  in
  let result = expect_ok (interpret [ State.Commit_title title ]) in
  check_eq (only_operation result).Ops.intent (Ops.Save_title title);
  check_eq result.platform [];
  let result =
    expect_ok
      (interpret
         [
           State.Merge_into_previous
             {
               merge_uuid = "second";
               merge_expected_title = "Second";
               merge_title = "Second";
               previous_uuid = "first";
               expected_previous_title = "First";
             };
         ])
  in
  (match (only_operation result).Ops.intent with
   | Ops.Merge_backward value -> check_eq value.previous_uuid "first"
   | _ -> check false);
  check_eq result.platform [ Effects.Focus_block "first" ]

let inserting_root_blocks_orders_and_focuses_the_new_row () =
  let result =
    expect_ok
      (interpret_in (context_for []) [ "operation"; "new-root" ]
         [ State.Insert_root_block { page_uuid = "page-1" } ])
  in
  (match (only_operation result).Ops.intent with
   | Ops.Insert_block value ->
     check_eq value.uuid "new-root";
     check_eq value.title "";
     check_eq value.page_uuid "page-1";
     check_eq value.parent_uuid "page-1";
     check_eq value.created_at 100;
     check (value.order <> "")
   | _ -> check false);
  check_eq result.platform [ Effects.Focus_block "new-root" ];
  let result =
    expect_ok
      (interpret_in context [ "operation"; "new-root" ]
         [ State.Insert_root_block { page_uuid = "page" } ])
  in
  match (only_operation result).Ops.intent with
  | Ops.Insert_block value ->
    check (String.compare value.order "a2" > 0)
  | _ -> check false

let status uuid ident : Model.status =
  { uuid; ident; title = uuid; icon_type = None; icon_id = None; icon_color = None }

let task_cycle_preserves_guards_for_built_in_custom_and_uuid_statuses () =
  List.iter
    (fun (current, expected, value) ->
      let context =
        context_for
          [ { (block "task" "Task" (Some "a0")) with Model.status = Some current } ]
      in
      let operation =
        only_operation
          (expect_ok
             (interpret_in context [ "operation" ]
                [ State.Cycle_task_status "task" ]))
      in
      match operation.Ops.intent with
      | Ops.Set_property property ->
        check_eq property.expected expected;
        check_eq property.value value
      | _ -> check false)
    [
      ( status "todo" (Some "logseq.property/status.todo"),
        Some (Ops.Ref_ident "logseq.property/status.todo"),
        Some (Ops.Ref_ident "logseq.property/status.doing") );
      ( status "doing" (Some "logseq.property/status.doing"),
        Some (Ops.Ref_ident "logseq.property/status.doing"),
        Some (Ops.Ref_ident "logseq.property/status.done") );
      ( status "done" (Some "logseq.property/status.done"),
        Some (Ops.Ref_ident "logseq.property/status.done"),
        None );
      ( status "custom" (Some "user.status/custom"),
        Some (Ops.Ref_ident "user.status/custom"),
        Some (Ops.Ref_ident "logseq.property/status.todo") );
      ( status "uuid-only" None,
        Some (Ops.Ref_uuid "uuid-only"),
        Some (Ops.Ref_ident "logseq.property/status.todo") );
    ]

let cases =
  [
    case "split generates between sibling order and focus"
      split_generates_between_sibling_order_and_focus;
    case "explicit task status and move batches preserve haptics"
      explicit_task_status_and_move_batches_preserve_haptics;
    case "task cycle without status stays a semantic operation"
      task_cycle_without_status_stays_a_semantic_operation;
    case "platform commands map exactly without semantic operations"
      platform_commands_map_exactly_without_semantic_operations;
    case "missing sibling orders sort after orders then by uuid"
      missing_sibling_orders_sort_after_orders_then_by_uuid;
    case "invalid commands fail and empty delete is a no-op"
      invalid_commands_fail_and_empty_delete_is_a_no_op;
    case "title commit is guarded and merge focuses the survivor"
      title_commit_is_guarded_and_merge_focuses_the_survivor;
    case "inserting root blocks orders and focuses the new row"
      inserting_root_blocks_orders_and_focuses_the_new_row;
    case "task cycle preserves guards for built-in custom and uuid statuses"
      task_cycle_preserves_guards_for_built_in_custom_and_uuid_statuses;
  ]
