open Test_util

module State = Outliner_state
module Model = Cache_model
module Ops = Pending_ops

let block uuid title : Model.block =
  {
    uuid;
    title;
    page_id = "page";
    parent_id = Some "page";
    order = Some "a0";
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

let row uuid parent order =
  { (block uuid uuid) with parent_id = Some parent; order = Some order }

let context_for blocks = State.context blocks [] []

let context =
  context_for [ block "a" "Alpha"; { (block "b" "Beta") with order = Some "a1" } ]

let candidate label value : State.outliner_candidate = { label; value }
let request kind query : State.reducer_autocomplete = { kind; query }
let text title caret : State.outliner_text = { title; caret }

let step ctx current message =
  let next, commands = State.update ctx current message in
  (next, commands)

let advance ctx current messages =
  List.fold_left (fun current message -> fst (step ctx current message)) current
    messages

let start ctx uuid title caret =
  advance ctx State.empty
    [ State.Tap_block uuid; State.Text_changed (text title caret) ]

let commit uuid expected title =
  State.Commit_title
    { Ops.uuid; expected_title = expected; title }

let split uuid expected before after =
  State.Split_at
    {
      split_uuid = uuid;
      split_expected_title = expected;
      before;
      after;
    }

let merge_command title =
  State.Merge_into_previous
    {
      merge_uuid = "b";
      merge_expected_title = "Beta";
      merge_title = title;
      previous_uuid = "a";
      expected_previous_title = "Alpha";
    }

let backspace selection =
  State.Backspace_pressed { selection_length = selection }

let atomic_backspace title selection =
  State.Backspace_pressed_with_text
    { backspace_title = title; backspace_selection_length = selection }

let visible_ids ctx current =
  List.map (fun (row : State.outliner_row) -> row.block.uuid)
    (State.visible_rows ctx current)

let selected current = State.selected_uuids current
let zoom_path current = State.zoom_path current

let journal_roots_stay_grouped_newest_first () =
  let journal_row uuid page order title day =
    { (row uuid page order) with page_id = page; journal = Some (title, day) }
  in
  let ctx =
    context_for
      [
        journal_row "older-first" "older-page" "a0" "Older" 20260827;
        journal_row "newer-second" "newer-page" "a1" "Newer" 20260828;
        journal_row "older-second" "older-page" "a1" "Older" 20260827;
        journal_row "newer-first" "newer-page" "a0" "Newer" 20260828;
      ]
  in
  check_eq (visible_ids ctx State.empty)
    [ "newer-first"; "newer-second"; "older-first"; "older-second" ]

let editing_and_page_completion_are_pure_until_a_command_is_needed () =
  let editing, commands = step context State.empty (State.Tap_block "a") in
  let changed, changes =
    step context editing (State.Text_changed (text "A [[Pro" 7))
  in
  let completed, effects =
    step context changed (State.Choose_autocomplete "Project")
  in
  check_eq (State.editing_uuid editing) (Some "a");
  check_eq commands [];
  check_eq changes [];
  check_eq (State.autocomplete changed)
    (Some (request State.Node "Pro"));
  check_eq (State.editing_title completed) (Some "A [[Project]]");
  check_eq effects
    [ State.Create_linked_page "Project"; State.Haptic State.Selection ]

let tag_completion_removes_inline_tokens_and_keeps_editing () =
  List.iter
    (fun (label, title) ->
      let ctx =
        { (context_for [ block "a" "Alpha" ]) with
          State.tags = [ candidate label "tag-uuid" ]
        }
      in
      let editing = start ctx "a" title 10 in
      let completed, commands =
        step ctx editing (State.Choose_autocomplete "tag-uuid")
      in
      if label = "Project" then
        check_eq (State.autocomplete editing)
          (Some (request State.Tag "Pro"));
      check_eq (State.editing_title completed) (Some "Alpha");
      check_eq (State.editing_uuid completed) (Some "a");
      check_eq (List.length commands) 2)
    [ ("Project", "Alpha #Pro"); ("favorite book", "Alpha #fav") ]

let summary uuid title : Model.entity_summary = { uuid; title }

let display_references_resolve_names_but_preserve_ambiguous_uuids () =
  let stored =
    {
      (block "a" "Ship [[page-uuid-1]] with #[[tag-uuid-1]] and #[[tag-uuid-2]]")
      with
      references = [ summary "page-uuid-1" "Roadmap" ];
      tags =
        [ summary "tag-uuid-1" "Project"; summary "tag-uuid-2" "favorite book" ];
    }
  in
  let ctx = context_for [ stored ] in
  let editing, _ = step ctx State.empty (State.Tap_block "a") in
  check_eq (State.editing_title editing)
    (Some "Ship [[Roadmap]] with #Project and #[[favorite book]]");
  check_eq (snd (step ctx editing State.Cancel_editing)) [];
  let stored =
    {
      (block "a" "See [[page-uuid-1]] or [[page-uuid-2]]")
      with
      references =
        [ summary "page-uuid-1" "Roadmap"; summary "page-uuid-2" "roadmap" ];
    }
  in
  let editing, _ =
    step (context_for [ stored ]) State.empty (State.Tap_block "a")
  in
  check_eq (State.editing_title editing)
    (Some "See [[page-uuid-1]] or [[page-uuid-2]]")

let tree =
  context_for
    [
      block "parent" "Parent";
      { (block "child" "Child") with parent_id = Some "parent" };
      { (block "sibling" "Sibling") with order = Some "a1" };
    ]

let collapse_and_zoom_own_visible_subtrees () =
  let collapsed, commands =
    step tree State.empty (State.Toggle_collapsed "parent")
  in
  let zoomed, zoom_commands = step tree collapsed (State.Zoom_in "parent") in
  let back, _ = step tree zoomed State.Zoom_out in
  let rows = State.visible_rows tree zoomed in
  check_eq commands [ State.Haptic State.Impact ];
  check_eq (visible_ids tree collapsed) [ "parent"; "sibling" ];
  check_eq zoom_commands [ State.Haptic State.Selection ];
  check_eq (visible_ids tree zoomed) [ "parent" ];
  check_eq
    (match rows with
     | row :: _ -> row.depth
     | [] -> -1)
    0;
  check_eq (visible_ids tree back) [ "parent"; "sibling" ]

let navigation_commits_drafts_and_clears_editing_and_selection () =
  let editing = start tree "parent" "Changed" 7 in
  let navigated, commands = step tree editing (State.Zoom_in "child") in
  check_eq (State.editing_uuid navigated) None;
  check_eq (selected navigated) [];
  check_eq commands
    [ commit "parent" "Parent" "Changed"; State.Haptic State.Selection ];
  let selected_state =
    advance tree State.empty
      [ State.Long_press_block "parent"; State.Zoom_in "parent" ]
  in
  check_eq (State.selected_uuids selected_state) [];
  let zoomed = fst (step tree State.empty (State.Zoom_in "parent")) in
  let editing =
    advance tree zoomed
      [
        State.Tap_block "child";
        State.Text_changed (text "Edited child" 12);
      ]
  in
  let back, commands = step tree editing State.Zoom_out in
  let selected_back =
    advance tree zoomed [ State.Long_press_block "child"; State.Zoom_out ]
  in
  check_eq (State.editing_uuid back) None;
  check_eq (zoom_path back) [];
  check_eq commands
    [ commit "child" "Child" "Edited child"; State.Haptic State.Selection ];
  check_eq (selected selected_back) []

let selection_toggles_and_long_press_restarts_selection () =
  let a = fst (step context State.empty (State.Long_press_block "a")) in
  let both = fst (step context a (State.Tap_block "b")) in
  let b = fst (step context both (State.Tap_block "a")) in
  let restarted = fst (step context b (State.Long_press_block "a")) in
  check_eq (selected a) [ "a" ];
  check_eq (selected both) [ "a"; "b" ];
  check_eq (selected b) [ "b" ];
  check_eq (selected restarted) [ "a" ]

let task_toolbar_preserves_the_editor () =
  let editing = fst (step context State.empty (State.Tap_block "a")) in
  let same, commands = step context editing (State.Toolbar State.Task) in
  check_eq same editing;
  check_eq commands
    [ State.Cycle_task_status "a"; State.Haptic State.Impact ]

let return_splits_the_current_or_atomic_native_text () =
  List.iter
    (fun (title, caret, message, before, after) ->
      let next, commands =
        step context (start context "a" title caret) message
      in
      check_eq (State.editing_uuid next) None;
      check_eq commands [ split "a" "Alpha" before after ])
    [
      ("Alpha Beta", 5, State.Return_pressed, "Alpha", " Beta");
      ( "Alpha",
        5,
        State.Return_pressed_with_text (text "Changed text" 7),
        "Changed",
        " text" );
    ]

let backspace_merges_current_or_atomic_text () =
  let editing =
    advance context State.empty
      [ State.Tap_block "b"; State.Caret_moved 0 ]
  in
  check_eq (snd (step context editing (backspace 0)))
    [ merge_command "Beta" ];
  let editing = fst (step context State.empty (State.Tap_block "b")) in
  check_eq
    (snd (step context editing (atomic_backspace "Changed" 0)))
    [ merge_command "Changed" ]

let first_block_backspace_deletes_and_focuses_the_next_block () =
  let ctx =
    context_for
      [
        block "journal-one" "First journal block";
        {
          (row "journal-two-block" "journal-two" "a1")
          with
          page_id = "journal-two";
          title = "Second journal block";
        };
        {
          (row "journal-two-next" "journal-two" "a2")
          with
          page_id = "journal-two";
          title = "Next journal block";
        };
      ]
  in
  let editing = fst (step ctx State.empty (State.Tap_block "journal-two-block")) in
  let next, commands =
    step ctx editing (atomic_backspace "Second journal block" 0)
  in
  check_eq (State.editing_uuid next) (Some "journal-two-next");
  check_eq commands [ State.Remove_blocks [ "journal-two-block" ] ];
  let editing =
    advance context State.empty
      [ State.Tap_block "a"; State.Caret_moved 0 ]
  in
  let next, commands = step context editing (backspace 0) in
  check_eq (State.editing_uuid next) (Some "b");
  check_eq commands [ State.Remove_blocks [ "a" ] ]

let return_only_outdents_the_final_empty_child () =
  let ctx =
    context_for
      [
        block "parent" "Parent";
        row "child" "parent" "a0";
        { (row "empty" "parent" "a1") with title = "" };
      ]
  in
  let editing = fst (step ctx State.empty (State.Tap_block "empty")) in
  let next, commands =
    step ctx editing (State.Return_pressed_with_text (text "" 0))
  in
  check_eq (State.editing_uuid next) (Some "empty");
  check
    (match commands with
     | [ State.Reparent_blocks [ move ] ] ->
       move.Ops.uuid = "empty" && move.Ops.parent_uuid = "page"
     | _ -> false);
  let ctx =
    context_for
      [
        block "parent" "Parent";
        { (row "empty" "parent" "a0") with title = "" };
        row "following" "parent" "a1";
      ]
  in
  let editing = fst (step ctx State.empty (State.Tap_block "empty")) in
  let next, commands = step ctx editing State.Return_pressed in
  check_eq (State.editing_uuid next) None;
  check
    (match commands with
     | [ State.Split_at _ ] -> true
     | _ -> false)

let moves commands =
  match commands with
  | [ State.Reparent_blocks values; State.Haptic State.Impact ] -> values
  | _ -> fail "expected one move batch and impact haptic"

let selected_indent_and_outdent_stay_atomic_and_preserve_selection () =
  let ctx =
    context_for
      [
        row "first" "page" "a0";
        row "second" "page" "a1";
        row "third" "page" "a2";
      ]
  in
  let current =
    advance ctx State.empty
      [ State.Long_press_block "second"; State.Tap_block "third" ]
  in
  let next, commands = step ctx current (State.Toolbar State.Indent) in
  let batch = moves commands in
  check_eq (selected next) [ "second"; "third" ];
  check_eq (List.map (fun (m : Ops.pending_move) -> m.uuid) batch)
    [ "second"; "third" ];
  check
    (List.for_all (fun (m : Ops.pending_move) -> m.parent_uuid = "first") batch);
  let ctx =
    context_for
      [
        row "parent" "page" "a0";
        row "child-a" "parent" "a0";
        row "child-b" "parent" "a1";
        row "next" "page" "a1";
      ]
  in
  let current =
    advance ctx State.empty
      [ State.Long_press_block "child-a"; State.Tap_block "child-b" ]
  in
  let next, commands = step ctx current (State.Toolbar State.Outdent) in
  let batch = moves commands in
  let a = List.nth batch 0 in
  let b = List.nth batch 1 in
  check_eq (selected next) [ "child-a"; "child-b" ];
  check_eq (List.length batch) 2;
  check_eq a.Ops.parent_uuid "page";
  check_eq b.Ops.parent_uuid "page";
  check (compare "a0" a.Ops.order < 0);
  check (compare a.Ops.order b.Ops.order < 0);
  check (compare b.Ops.order "a1" < 0)

let move_up_and_down_reorder_siblings_and_keep_focus () =
  let ctx =
    context_for
      [
        row "first" "page" "a0";
        row "second" "page" "a1";
        row "third" "page" "a2";
      ]
  in
  let editing = fst (step ctx State.empty (State.Tap_block "third")) in
  let next, commands = step ctx editing (State.Toolbar State.Move_up) in
  let batch = moves commands in
  check_eq (State.editing_uuid next) (Some "third");
  check_eq (List.map (fun (m : Ops.pending_move) -> m.uuid) batch)
    [ "third" ];
  check_eq (List.hd batch).Ops.parent_uuid "page";
  check (compare "a0" (List.hd batch).Ops.order < 0);
  check (compare (List.hd batch).Ops.order "a1" < 0);
  let current =
    advance ctx State.empty
      [ State.Long_press_block "first"; State.Tap_block "second" ]
  in
  let next, commands = step ctx current (State.Toolbar State.Move_down) in
  let batch = moves commands in
  check_eq (selected next) [ "first"; "second" ];
  check_eq (List.map (fun (m : Ops.pending_move) -> m.uuid) batch)
    [ "first"; "second" ];
  check
    (List.for_all
       (fun (m : Ops.pending_move) -> compare "a2" m.Ops.order < 0)
       batch);
  let first_editing = fst (step ctx State.empty (State.Tap_block "first")) in
  check_eq (snd (step ctx first_editing (State.Toolbar State.Move_up)))
    [ State.Haptic State.Impact ];
  let last_editing = fst (step ctx State.empty (State.Tap_block "third")) in
  check_eq (snd (step ctx last_editing (State.Toolbar State.Move_down)))
    [ State.Haptic State.Impact ]

let move_up_down_at_boundary_crosses_into_neighbor_parent () =
  let ctx =
    context_for
      [
        row "ra" "page" "a0";
        row "ca" "ra" "a0";
        row "rb" "page" "a1";
        row "cb1" "rb" "a0";
        row "cb2" "rb" "a1";
        row "rc" "page" "a2";
      ]
  in
  let editing = fst (step ctx State.empty (State.Tap_block "cb1")) in
  let next, commands = step ctx editing (State.Toolbar State.Move_up) in
  let batch = moves commands in
  check_eq (State.editing_uuid next) (Some "cb1");
  check_eq (List.map (fun (m : Ops.pending_move) -> m.uuid) batch) [ "cb1" ];
  check_eq (List.hd batch).Ops.parent_uuid "ra";
  check (compare (List.hd batch).Ops.order "a0" < 0);
  let editing = fst (step ctx State.empty (State.Tap_block "cb2")) in
  let _, commands = step ctx editing (State.Toolbar State.Move_down) in
  let batch = moves commands in
  check_eq (List.map (fun (m : Ops.pending_move) -> m.uuid) batch) [ "cb2" ];
  check_eq (List.hd batch).Ops.parent_uuid "rc";
  let nested =
    context_for
      [
        row "rp" "page" "a0";
        row "only" "rp" "a0";
      ]
  in
  let editing = fst (step nested State.empty (State.Tap_block "only")) in
  check_eq (snd (step nested editing (State.Toolbar State.Move_up)))
    [ State.Haptic State.Impact ];
  check_eq (snd (step nested editing (State.Toolbar State.Move_down)))
    [ State.Haptic State.Impact ]

let delete_confirmation_is_consumed_once () =
  let current = fst (step context State.empty (State.Long_press_block "a")) in
  let asked, commands = step context current (State.Toolbar State.Delete) in
  let deleted, confirmed = step context asked State.Confirm_delete in
  check_eq commands
    [ State.Request_delete_confirmation [ "a" ]; State.Haptic State.Impact ];
  check_eq (selected asked) [];
  check_eq confirmed [ State.Remove_blocks [ "a" ] ];
  check_eq (snd (step context deleted State.Confirm_delete)) []

let drop_message uuid placement =
  State.Drop_blocks { target_uuid = uuid; placement }

let drop_rejects_descendants_and_valid_drop_clears_selection () =
  let ctx =
    context_for
      [
        row "parent" "page" "a0";
        row "child" "parent" "a0";
        row "target" "page" "a1";
      ]
  in
  let current = fst (step ctx State.empty (State.Long_press_block "parent")) in
  let same, ignored = step ctx current (drop_message "child" State.After) in
  let next, commands = step ctx current (drop_message "target" State.Inside) in
  let batch = moves commands in
  check_eq same current;
  check_eq ignored [];
  check_eq (selected next) [];
  check_eq (List.length batch) 1;
  check_eq (List.hd batch).Ops.uuid "parent";
  check_eq (List.hd batch).Ops.parent_uuid "target"

let structural_toolbar_keeps_the_editing_block_focused () =
  List.iter
    (fun (ctx, uuid, action, parent) ->
      let current = fst (step ctx State.empty (State.Tap_block uuid)) in
      let next, commands = step ctx current (State.Toolbar action) in
      let batch = moves commands in
      check_eq (State.editing_uuid next) (Some uuid);
      check_eq (List.length batch) 1;
      check_eq (List.hd batch).Ops.uuid uuid;
      check_eq (List.hd batch).Ops.parent_uuid parent)
    [
      (context, "b", State.Indent, "a");
      ( context_for
          [
            row "parent" "page" "a0";
            row "child" "parent" "a0";
            row "next" "page" "a1";
          ],
        "child",
        State.Outdent,
        "page" );
    ]

let toolbar_inserts_at_caret_and_targets_media_without_leaving_editor () =
  List.iter
    (fun (action, title, caret, kind) ->
      let next, commands =
        step context (start context "a" "AlphaBeta" 5) (State.Toolbar action)
      in
      check_eq (State.editing_uuid next) (Some "a");
      check_eq (State.editing_title next) (Some title);
      check_eq (Option.map (fun (d : State.editor_draft) -> d.caret) next.editing)
        (Some caret);
      check_eq
        (Option.map
           (fun (r : State.reducer_autocomplete) -> r.kind)
           (State.autocomplete next))
        (Some kind);
      check_eq commands [ State.Haptic State.Impact ])
    [
      (State.Tag_action, "Alpha #Beta", 7, State.Tag);
      (State.Page_reference, "Alpha [[]]Beta", 8, State.Node);
    ];
  let current = fst (step context State.empty (State.Tap_block "a")) in
  List.iter
    (fun (action, expected) ->
      let same, commands = step context current (State.Toolbar action) in
      check_eq same current;
      check_eq commands [ expected; State.Haptic State.Impact ])
    [
      (State.Camera, State.Take_photo "a");
      (State.Audio, State.Record_audio "a");
      (State.Attachment, State.Pick_attachment "a");
    ];
  let next, commands =
    step context (start context "a" "Changed" 7)
      (State.Toolbar State.Hide_keyboard)
  in
  check_eq (State.editing_uuid next) None;
  check_eq commands
    [ commit "a" "Alpha" "Changed"; State.Haptic State.Impact ]

let selection_copy_and_unselect_close_selection () =
  let current = fst (step context State.empty (State.Long_press_block "a")) in
  List.iter
    (fun (action, expected) ->
      let next, commands = step context current (State.Toolbar action) in
      check_eq (selected next) [];
      check_eq commands [ expected; State.Haptic State.Impact ])
    [
      (State.Copy, State.Copy_text "Alpha");
      (State.Copy_reference, State.Copy_references [ "a" ]);
      (State.Copy_url, State.Copy_urls [ "a" ]);
    ];
  let next, commands = step context current (State.Toolbar State.Unselect) in
  check_eq (selected next) [];
  check_eq commands [ State.Haptic State.Impact ]

let nested_zoom_and_deleted_destinations_maintain_valid_paths () =
  let ctx =
    context_for
      [
        row "parent" "page" "a0";
        row "child" "parent" "a0";
        row "grandchild" "child" "a0";
        row "sibling" "page" "a1";
      ]
  in
  let nested =
    advance ctx State.empty
      [ State.Zoom_in "parent"; State.Zoom_in "child" ]
  in
  let back = fst (step ctx nested State.Zoom_out) in
  check_eq (zoom_path nested) [ "parent"; "child" ];
  check_eq (visible_ids ctx nested) [ "child"; "grandchild" ];
  check_eq (zoom_path back) [ "parent" ];
  check_eq (zoom_path (fst (step ctx back State.Zoom_out))) [];
  let deleted =
    fst
      (step (context_for []) nested
         (State.Operation_staged
            (Ops.Delete_blocks { Ops.uuids = [ "parent" ] })))
  in
  check_eq (zoom_path deleted) []

let large_outlines_retain_the_existing_latency_bound () =
  let blocks =
    List.init 5000 (fun index ->
        row
          (Printf.sprintf "performance-%d" index)
          (if index = 0 then "page"
           else Printf.sprintf "performance-%d" (index - 1))
          "a0")
  in
  let ctx = context_for blocks in
  let started = Unix.gettimeofday () in
  let rows = State.visible_rows ctx State.empty in
  let elapsed = Unix.gettimeofday () -. started in
  check_eq (List.length rows) 5000;
  check (elapsed < 0.1)

let flattening_ten_thousand_nested_blocks_avoids_quadratic_allocation () =
  let allocated count =
    let blocks = List.init count (fun index ->
      row (string_of_int index)
        (if index mod 4 = 0 then "page" else string_of_int (index - 1))
        (Printf.sprintf "a%06d" index)) in
    let context = context_for blocks in
    let before = Gc.allocated_bytes () in
    let rows = State.visible_rows context State.empty in
    let bytes = Gc.allocated_bytes () -. before in
    check_eq (List.length rows) count;
    List.iteri (fun index (row : State.outliner_row) ->
      check_eq row.block.uuid (string_of_int index);
      check_eq row.depth (index mod 4)) rows;
    bytes
  in
  let small = allocated 1_000 in
  let large = allocated 10_000 in
  check ~msg:"10x the blocks must allocate less than 20x the memory"
    (large < small *. 20.)

let unicode_carets_and_token_search_handle_boundaries () =
  List.iter
    (fun (byte, length) -> check_eq (State.utf8_sequence_length byte) length)
    [ (65, 1); (195, 2); (228, 3); (240, 4); (128, 1) ];
  check_eq (State.utf16_length "Aé中\xF0\x9F\x98\x80") 5;
  List.iter
    (fun (offset, index) ->
      check_eq (State.byte_index_of_utf16 "Aé中\xF0\x9F\x98\x80" offset) index)
    [ (0, 0); (2, 3); (5, 10); (99, 10) ];
  check_eq (State.last_substring "value" "") None;
  check_eq (State.last_substring "aba" "a") (Some 2);
  check (State.includes_case_insensitive "Value" "  ")

let autocomplete_candidates_combine_deduplicate_and_bound_results () =
  let ctx =
    {
      (context_for
         [
           block "alpha" "Alpha block";
           { (block "beta" "Beta") with order = Some "a1" };
         ])
      with
      State.pages = [ candidate "Project Alpha" "Project Alpha" ];
    }
  in
  check_eq
    (State.autocomplete_candidates ctx (request State.Node "alpha"))
    [ candidate "Project Alpha" "Project Alpha";
      candidate "Alpha block" "alpha" ];
  let candidates =
    [ candidate "Project" "project"; candidate "Project duplicate" "project" ]
  in
  let ctx =
    {
      (context_for [ block "alpha" "Alpha" ]) with
      State.pages = candidates;
      tags = candidates;
    }
  in
  check_eq
    (State.autocomplete_candidates ctx (request State.Node "project"))
    [ candidate "Project" "project" ];
  check
    (List.for_all
       (fun (c : State.outliner_candidate) -> c.label <> "")
       (State.autocomplete_candidates
          { ctx with
            State.blocks = [ block "blank" ""; block "alpha" "Alpha" ] }
          (request State.Node "")));
  check_eq
    (List.length (State.autocomplete_candidates ctx (request State.Tag "project")))
    1;
  check_eq
    (State.autocomplete_candidates ctx (request State.Tag "Project"))
    [ candidate "Project" "project" ];
  check_eq
    (State.autocomplete_candidates ctx (request State.Tag "foobar"))
    [ candidate "New tag: foobar" "foobar" ];
  check_eq
    (State.autocomplete_candidates ctx (request State.Property "prio"))
    [ candidate "priority" "priority" ];
  check_eq
    (State.autocomplete_candidates (context_for []) (request State.Tag ""))
    [];
  let pages =
    List.init 20 (fun i -> candidate (string_of_int i) (string_of_int i))
  in
  check_eq
    (List.length
       (State.autocomplete_candidates
          { (context_for []) with State.pages }
          (request State.Node "")))
    12;
  let ctx =
    {
      (context_for []) with
      State.tags =
        [ candidate "Project" "project"; candidate "Personal" "personal" ];
    }
  in
  check
    (List.exists
       (fun (c : State.outliner_candidate) -> c.value = "project")
       (State.autocomplete_candidates ctx (request State.Tag "prj")))

let markdown_literals_do_not_open_or_apply_completion () =
  let literals =
    [ "[PR #101](https://github.com/logseq/logseq_journal/pull/101)";
      "[PR #101]([[Page]])"; "[literal [[Page]]](https://example.com/#tag)";
      "https://example.com/#tag"; "`#tag [[Page]]`";
      "~~~\n#tag [[Page]]\n~~~"; "{{embed [[Page]]}}" ] in
  List.iter (fun literal ->
    let title = "中文 😀 " ^ literal ^ " after" in
    let ctx = context_for [block "a" title] in
    let editing = fst (step ctx State.empty (State.Tap_block "a")) in
    for caret = 0 to State.utf16_length title do
      let moved = fst (step ctx editing (State.Caret_moved caret)) in
      check_eq ~msg:("moving the caret must not activate completion: " ^ title)
        (State.autocomplete moved) None;
      let chosen, commands = step ctx moved (State.Choose_autocomplete "accidental") in
      check_eq ~msg:"a stale popup cannot change literal text" commands [];
      check_eq chosen.editing moved.editing
    done;
    let stale = { editing with State.autocomplete = Some (request State.Tag "101") } in
    let unchanged, commands = step ctx stale (State.Choose_autocomplete "accidental") in
    check_eq ~msg:"a delayed selection is revalidated against current syntax" commands [];
    check_eq unchanged.editing editing.editing;
    let changed = title ^ "!" in
    let typed = start ctx "a" changed (State.utf16_length changed) in
    check_eq ~msg:("literal markers do not consume following prose: " ^ title)
      (State.autocomplete typed) None;
    let tagged = title ^ " #real" in
    check_eq (State.autocomplete (start ctx "a" tagged (State.utf16_length tagged)))
      (Some (request State.Tag "real"))
  ) literals;
  let title = "同步可接收空事务。（[PR #101](https://github.com/logseq/logseq_journal/pull/101)）" in
  let ctx = context_for [block "a" title] in
  for caret = 0 to State.utf16_length title do
    check_eq ~msg:"editing anywhere in the existing Markdown link offers no tag"
      (State.autocomplete (start ctx "a" title caret)) None
  done;
  List.iter (fun (title, caret, expected) ->
    check_eq (State.autocomplete (start context "a" title caret)) expected)
    [ "[[Pro]]", 5, Some (request State.Node "Pro");
      "[[]]", 2, Some (request State.Node "");
      "#new", 4, Some (request State.Tag "new");
      "[[Page]] #new", 13, Some (request State.Tag "new") ]

let entering_code_does_not_offer_tag_completion () =
  List.iter (fun title ->
    let ctx = context_for [block "a" title] in
    let editing = fst (step ctx State.empty (State.Tap_block "a")) in
    let moved = fst (step ctx editing (State.Caret_moved (State.utf16_length title))) in
    check_eq ~msg:("literal code does not open completion: " ^ title) (State.autocomplete moved) None;
    let changed = title ^ (if String_kit.starts_with ~prefix:"```\n" title then "\n #new" else " #new") in
    if not (List.mem title ["`#Asset"; "```\n#tag"]) then begin
      let typed = fst (step ctx moved (State.Text_changed (text changed (State.utf16_length changed)))) in
      check_eq ~msg:"typing a real tag after literal code still offers completion"
        (State.autocomplete typed) (Some (request State.Tag "new"))
    end
  ) ["db-test#1452: `#Asset` label is not displayed on asset nodes when `Hide from Node` is disabled";
     "`#Asset`"; "`#Asset"; "```\n#tag"; "```\n#tag\n```";
     "prefix \\#tag"; "`[[Page`"; "`status::`"; "中文 `#标签`"]

let autocomplete_token_parsing_preserves_current_line_rules () =
  List.iter
    (fun (title, expected) ->
      check_eq
        (State.autocomplete_for title (State.utf16_length title))
        expected)
    [
      ("[[Al", Some (request State.Node "Al"));
      ("property::", Some (request State.Property "property"));
      ("#tag", Some (request State.Tag "tag"));
      ("text #tag", Some (request State.Tag "tag"));
      ("text\n#tag", Some (request State.Tag "tag"));
      ("text#tag", None);
      ("#two words", Some (request State.Tag "two words"));
      ("before\nstatus::", Some (request State.Property "status"));
      ("[[Page]]", None);
      ("((Block", None);
      ("/query", None);
      ("text\n/query", None);
      ("plain text", None);
    ];
  check_eq
    (State.token_request State.Tag '#' "#two words")
    (Some (request State.Tag "two words"));
  check_eq (State.token_request State.Tag '#' "#two\nwords") None

let editing title : State.editor_draft =
  {
    uuid = "a";
    expected_title = title;
    title;
    caret = State.utf16_length title;
  }

let completion_and_caret_insertion_preserve_literal_text () =
  List.iter
    (fun (kind, title, value, expected) ->
      check_eq
        (Option.map
           (fun (d : State.editor_draft) -> d.title)
           (State.complete context (editing title) kind value))
        (Some expected))
    [
      (State.Node, "[[Pr", "Project", "[[Project]]");
      (State.Tag, "#ta", "tag", "#tag");
      ( State.Tag,
        "#ta",
        "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8",
        "#[[018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8]]" );
      (State.Tag, "#ta", "two words", "#[[two words]]");
      (State.Property, "before\nsta::", "status", "before\nstatus:: ");
    ];
  check_eq (State.complete context (editing "plain") State.Node "Project")
    None;
  check_eq (State.commit_effect context (Some (editing "Alpha"))) [];
  check_eq (State.commit_effect context None) [];
  check_eq (State.insert_at_caret (editing "") "#" 0).title "#";
  check_eq (State.insert_at_caret (editing "A ") "#" 0).title "A #"

let block_ordering_and_contiguity_handle_missing_values () =
  let ordered = block "ordered" "Ordered" in
  let unordered = { (block "unordered" "Unordered") with order = None } in
  let earlier =
    { (block "earlier" "Earlier") with order = None; created_at = -1 }
  in
  let later = { (block "later" "Later") with order = None } in
  check_eq
    (List.map
       (fun (b : Model.block) -> b.uuid)
       (List.sort State.compare_blocks [ later; earlier; ordered ]))
    [ "ordered"; "earlier"; "later" ];
  check (State.compare_blocks ordered unordered < 0);
  check (State.compare_blocks unordered ordered > 0);
  check (not (State.selection_is_contiguous [] [ ordered ]));
  check (State.selection_is_contiguous [ ordered ] [ unordered; ordered ]);
  check_eq
    (List.map
       (fun (b : Model.block) -> b.uuid)
       (List.sort State.compare_blocks
          [
            { (block "b" "B") with order = None };
            { (block "a" "A") with order = None };
          ]))
    [ "a"; "b" ];
  check_eq (State.index_of_uuid "missing" []) None

let structural_helpers_reject_invalid_selections_and_order_bounds () =
  check_eq
    (State.moves_with_orders [ block "root" "Root" ] "page" (Some "a1")
       (Some "a0"))
    None;
  check_eq (State.indent context State.Sset.empty) None;
  check_eq (State.outdent context State.Sset.empty) None;
  check_eq (State.drop context State.Sset.empty "a" State.After) None;
  check_eq
    (State.drop context
       (State.Sset.of_list [ "a" ])
       "missing" State.After)
    None;
  let ctx =
    context_for
      [
        row "first" "page" "a0";
        row "second" "page" "a1";
        row "third" "page" "a2";
        row "fourth" "page" "a3";
        row "other-child" "other" "a0";
      ]
  in
  check_eq (State.indent ctx (State.Sset.of_list [ "first" ])) None;
  check_eq
    (State.indent ctx (State.Sset.of_list [ "second"; "fourth" ]))
    None;
  check_eq
    (State.indent ctx (State.Sset.of_list [ "second"; "other-child" ]))
    None;
  let ctx =
    context_for
      [
        row "first" "page" "a0";
        row "existing" "first" "a0";
        row "second" "page" "a1";
      ]
  in
  (match State.indent ctx (State.Sset.of_list [ "second" ]) with
   | Some [ move ] -> check (compare move.Ops.order "a0" > 0)
   | _ -> check false);
  check_eq
    (State.outdent context (State.Sset.of_list [ "a" ]))
    None;
  let ctx =
    context_for
      [
        row "parent" "page" "a0";
        row "first" "parent" "a0";
        row "second" "parent" "a1";
        row "third" "parent" "a2";
        row "other-child" "other" "a0";
      ]
  in
  check_eq
    (State.outdent ctx (State.Sset.of_list [ "first"; "third" ]))
    None;
  check_eq
    (State.outdent ctx (State.Sset.of_list [ "first"; "other-child" ]))
    None;
  check_eq
    (State.outdent
       (context_for
          [
            { (block "parent" "Parent") with parent_id = None };
            row "child" "parent" "a0";
          ])
       (State.Sset.of_list [ "child" ]))
    None;
  match
    State.outdent
      (context_for [ row "parent" "page" "a0"; row "child" "parent" "a0" ])
      (State.Sset.of_list [ "child" ])
  with
  | Some [ move ] -> check (compare move.Ops.order "a0" > 0)
  | _ -> check false

let drop_allocates_before_after_and_inside_orders () =
  let ctx =
    context_for
      [
        row "first" "page" "a0";
        row "middle" "page" "a1";
        row "last" "page" "a2";
        row "last-child" "last" "a0";
        { (block "detached" "Detached") with parent_id = None };
      ]
  in
  let selected = State.Sset.of_list [ "middle" ] in
  (match State.drop ctx selected "first" State.Before with
   | Some [ move ] -> check (compare move.Ops.order "a0" < 0)
   | _ -> check false);
  (match State.drop ctx selected "last" State.After with
   | Some [ move ] -> check (compare move.Ops.order "a2" > 0)
   | _ -> check false);
  check_eq (State.drop ctx selected "middle" State.Inside) None;
  (match State.drop ctx selected "last" State.Inside with
   | Some [ move ] -> check (compare move.Ops.order "a0" > 0)
   | _ -> check false);
  List.iter
    (fun (target, placement) ->
      match State.drop ctx selected target placement with
      | Some [ move ] ->
        check
          (compare move.Ops.order "a0" > 0 && compare move.Ops.order "a2" < 0)
      | _ -> check false)
    [ ("last", State.Before); ("first", State.After) ];
  check_eq (State.drop ctx selected "detached" State.Before) None;
  (match State.drop ctx (State.Sset.singleton "last-child") "last" State.After with
   | Some [ move ] ->
     check_eq ~msg:"a child can become its parent's following sibling" move.Ops.parent_uuid "page";
     check (compare move.order "a2" > 0)
   | _ -> check false)

let ancestor_and_selected_root_traversal_terminate_on_cycles () =
  let a = row "cyclic-a" "cyclic-b" "a0" in
  let b = row "cyclic-b" "cyclic-a" "a0" in
  let ctx = context_for [ a; b ] in
  check_eq (State.Sset.cardinal (State.ancestor_uuids ctx a)) 2;
  check_eq
    (State.selected_roots ctx (State.Sset.of_list [ "cyclic-a"; "cyclic-b" ]))
    [];
  let selected_block = row "selected" "cycle-a" "a0" in
  let ctx =
    context_for
      [
        selected_block;
        row "cycle-a" "cycle-b" "a0";
        row "cycle-b" "cycle-a" "a0";
      ]
  in
  check_eq
    (State.selected_roots ctx (State.Sset.of_list [ "selected" ]))
    [ selected_block ]

let idle_and_stale_editor_messages_are_no_ops () =
  List.iter
    (fun message ->
      check_eq (step context State.empty message) (State.empty, []))
    [
      State.Tap_block "missing";
      State.Text_changed (text "x" 1);
      State.Caret_moved 1;
      State.Return_pressed;
      backspace 0;
      backspace 1;
      State.Choose_autocomplete "value";
      State.Confirm_delete;
      State.Return_pressed_with_text (text "Draft" 5);
      atomic_backspace "Draft" 0;
      State.Cancel_editing;
      State.Toolbar State.Task;
      State.Toolbar State.Tag_action;
      State.Toolbar State.Page_reference;
      State.Toolbar State.Camera;
      State.Toolbar State.Attachment;
      State.Zoom_in "missing";
    ];
  List.iter
    (fun action ->
      check_eq
        (step context State.empty (State.Toolbar action))
        (State.empty, [ State.Haptic State.Impact ]))
    [ State.Indent; State.Outdent ];
  let current = fst (step context State.empty (State.Tap_block "a")) in
  check_eq
    (step context current (atomic_backspace "Draft" 1))
    (current, []);
  check_eq
    (step (context_for [ block "other" "Other" ]) current (backspace 0))
    (current, []);
  let stale =
    { State.empty with
      editing = Some { (editing "") with uuid = "missing" } }
  in
  check_eq (step context stale (backspace 0)) (stale, []);
  let stale =
    {
      State.empty with
      editing = Some (editing "plain");
      autocomplete = Some (request State.Node "");
    }
  in
  check_eq
    (step context stale (State.Choose_autocomplete "Project"))
    (stale, [])

let staged_operations_and_repeated_navigation_maintain_editor_state () =
  let zoomed = fst (step context State.empty (State.Zoom_in "a")) in
  let same, commands = step context zoomed (State.Zoom_in "a") in
  let root, root_commands = step context State.empty State.Zoom_out in
  check_eq (zoom_path same) [ "a" ];
  check_eq commands [ State.Haptic State.Selection ];
  check_eq (zoom_path root) [];
  check_eq root_commands [ State.Haptic State.Selection ];
  let missing =
    Ops.Merge_backward
      {
        Ops.uuid = "a";
        expected_title = "Alpha";
        title = "Alpha";
        previous_uuid = "missing";
        expected_previous_title = "Missing";
        merged_title = None;
      }
  in
  check_eq
    (step context State.empty (State.Operation_staged missing))
    (State.empty, []);
  let intent =
    Ops.Split_block
      {
        Ops.uuid = "a";
        expected_title = "Alpha";
        before = "A";
        after = "lpha";
        new_uuid = "new";
        new_order = "a1";
        created_at = 1;
      }
  in
  let next, commands =
    step context State.empty (State.Operation_staged intent)
  in
  check_eq (State.editing_uuid next) (Some "new");
  check_eq (State.editing_title next) (Some "lpha");
  check_eq commands [];
  check_eq
    (step context State.empty (State.Add_root_block "page-1"))
    ( State.empty,
      [
        State.Insert_root_block { State.page_uuid = "page-1" };
        State.Haptic State.Impact;
      ] );
  let intent =
    Ops.Insert_block
      {
        Ops.uuid = "new-root";
        title = "";
        page_uuid = "page-1";
        parent_uuid = "page-1";
        order = "a0";
        created_at = 1;
      }
  in
  let next, commands =
    step context State.empty (State.Operation_staged intent)
  in
  check_eq (State.editing_uuid next) (Some "new-root");
  check_eq (State.editing_title next) (Some "");
  check_eq commands [];
  let collapsed = fst (step context State.empty (State.Toggle_collapsed "a")) in
  let expanded, commands =
    step context collapsed (State.Toggle_collapsed "a")
  in
  check (State.Sset.is_empty expanded.collapsed);
  check_eq commands [ State.Haptic State.Impact ]

let balanced_completion_and_collapse_preserve_unsaved_text () =
  let ctx =
    { context with State.pages = [ candidate "Project" "page-id" ] }
  in
  List.iter
    (fun (title, caret, value, expected) ->
      let next, commands =
        step ctx (start ctx "a" title caret) (State.Choose_autocomplete value)
      in
      check_eq (State.editing_title next) (Some expected);
      check_eq commands
        (if value = "Novel" then
           [ State.Create_linked_page "Novel"; State.Haptic State.Selection ]
         else [ State.Haptic State.Selection ]))
    [
      ("[[Pro]]", 5, "page-id", "[[Project]]");
      ("[[]]", 2, "Novel", "[[Novel]]");
      ("Before [[Pro]] after", 12, "page-id", "Before [[Project]] after");
      ("\xF0\x9F\x98\x80 [[Pro]] tail", 8, "page-id", "\xF0\x9F\x98\x80 [[Project]] tail");
      ("[[Pro]", 5, "page-id", "[[Project]]");
      ("[[Pro", 5, "page-id", "[[Project]]");
      ("[[Pro]] [[Next]]", 5, "page-id", "[[Project]] [[Next]]");
      ("[[Project]]", 5, "page-id", "[[Project]]");
    ];
  check_eq
    (State.autocomplete_candidates ctx (request State.Node "Novel"))
    [ candidate "New page: Novel" "Novel" ];
  check_eq
    (State.autocomplete_candidates (context_for []) (request State.Node ""))
    [];
  List.iter
    (fun collapsed_flag ->
      let current = start ctx "a" "Edited [[Pro" 12 in
      let current =
        if collapsed_flag then
          { current with
            State.collapsed = State.Sset.of_list [ "b" ] }
        else current
      in
      let next, commands = step ctx current (State.Toggle_collapsed "b") in
      check_eq (State.editing_uuid next) None;
      check_eq (State.autocomplete next) None;
      check
        (List.exists
           (fun command ->
             match command with
             | State.Commit_title _ -> true
             | _ -> false)
           commands))
    [ false; true ]

let cases =
  [
    case "markdown literals do not open or apply completion" markdown_literals_do_not_open_or_apply_completion;
    case "journal roots stay grouped newest first"
      journal_roots_stay_grouped_newest_first;
    case "editing and page completion are pure until a command is needed"
      editing_and_page_completion_are_pure_until_a_command_is_needed;
    case "tag completion removes inline tokens and keeps editing"
      tag_completion_removes_inline_tokens_and_keeps_editing;
    case "display references resolve names but preserve ambiguous uuids"
      display_references_resolve_names_but_preserve_ambiguous_uuids;
    case "collapse and zoom own visible subtrees"
      collapse_and_zoom_own_visible_subtrees;
    case "navigation commits drafts and clears editing and selection"
      navigation_commits_drafts_and_clears_editing_and_selection;
    case "selection toggles and long press restarts selection"
      selection_toggles_and_long_press_restarts_selection;
    case "task toolbar preserves the editor" task_toolbar_preserves_the_editor;
    case "return splits the current or atomic native text"
      return_splits_the_current_or_atomic_native_text;
    case "backspace merges current or atomic text"
      backspace_merges_current_or_atomic_text;
    case "first block backspace deletes and focuses the next block"
      first_block_backspace_deletes_and_focuses_the_next_block;
    case "return only outdents the final empty child"
      return_only_outdents_the_final_empty_child;
    case "selected indent and outdent stay atomic and preserve selection"
      selected_indent_and_outdent_stay_atomic_and_preserve_selection;
    case "move up and down reorder siblings and keep focus"
      move_up_and_down_reorder_siblings_and_keep_focus;
    case "move up and down cross the parent boundary at edges"
      move_up_down_at_boundary_crosses_into_neighbor_parent;
    case "delete confirmation is consumed once"
      delete_confirmation_is_consumed_once;
    case "drop rejects descendants and valid drop clears selection"
      drop_rejects_descendants_and_valid_drop_clears_selection;
    case "structural toolbar keeps the editing block focused"
      structural_toolbar_keeps_the_editing_block_focused;
    case
      "toolbar inserts at caret and targets media without leaving editor"
      toolbar_inserts_at_caret_and_targets_media_without_leaving_editor;
    case "selection copy and unselect close selection"
      selection_copy_and_unselect_close_selection;
    case "nested zoom and deleted destinations maintain valid paths"
      nested_zoom_and_deleted_destinations_maintain_valid_paths;
    case "large outlines retain the existing latency bound"
      large_outlines_retain_the_existing_latency_bound;
    case "flattening 10k nested blocks avoids quadratic allocation"
      flattening_ten_thousand_nested_blocks_avoids_quadratic_allocation;
    case "unicode carets and token search handle boundaries"
      unicode_carets_and_token_search_handle_boundaries;
    case "autocomplete candidates combine deduplicate and bound results"
      autocomplete_candidates_combine_deduplicate_and_bound_results;
    case "entering code does not offer tag completion" entering_code_does_not_offer_tag_completion;
    case "autocomplete token parsing preserves current line rules"
      autocomplete_token_parsing_preserves_current_line_rules;
    case "completion and caret insertion preserve literal text"
      completion_and_caret_insertion_preserve_literal_text;
    case "block ordering and contiguity handle missing values"
      block_ordering_and_contiguity_handle_missing_values;
    case "structural helpers reject invalid selections and order bounds"
      structural_helpers_reject_invalid_selections_and_order_bounds;
    case "drop allocates before after and inside orders"
      drop_allocates_before_after_and_inside_orders;
    case "ancestor and selected root traversal terminate on cycles"
      ancestor_and_selected_root_traversal_terminate_on_cycles;
    case "idle and stale editor messages are no ops"
      idle_and_stale_editor_messages_are_no_ops;
    case "staged operations and repeated navigation maintain editor state"
      staged_operations_and_repeated_navigation_maintain_editor_state;
    case "balanced completion and collapse preserve unsaved text"
      balanced_completion_and_collapse_preserve_unsaved_text;
  ]
