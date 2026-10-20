open Test_util

module Model = Cache_model
module Ds = Datascript

let now = 1776000000000

let block uuid title page created : Model.block =
  {
    uuid;
    title;
    page_id = page;
    parent_id = None;
    order = None;
    created_at = created;
    updated_at = created;
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

let read_block cache uuid =
  match Model.read_block cache uuid with
  | Some block -> block
  | None -> fail ("missing block " ^ uuid)

let ok result = match result with Ok _ -> true | Error _ -> false

let ids blocks =
  List.map (fun (b : Model.block) -> b.uuid) blocks

let recent_captures_keep_the_newest_hundred_in_order () =
  let cache = Model.create None in
  for index = 0 to 104 do
    Model.cache_local_message cache
      (Printf.sprintf "local-%d" index)
      (Printf.sprintf "Capture %d" index)
      (now + index)
  done;
  let recent = Model.recent_blocks cache in
  check_eq (List.length recent) 100;
  check_eq (List.hd recent).uuid "local-5";
  check_eq (List.hd recent).title "Capture 5";
  let last = List.nth recent (List.length recent - 1) in
  check_eq last.uuid "local-104";
  check_eq last.title "Capture 104"

let refresh_selection_and_outliner_orphans () =
  let cache = Model.create None in
  let row uuid parent order =
    {
      (block uuid uuid "page" 1) with
      Model.parent_id = Some parent;
      order = Some order;
    }
  in
  let rows =
    [
      row "orphan" "missing" "a2";
      row "root" "page" "a1";
      row "child" "root" "a0";
      row "cycle-a" "cycle-b" "a3";
      row "cycle-b" "cycle-a" "a4";
    ]
  in
  Model.upsert_blocks cache [] 42;
  check_eq cache.revision 0;
  check_eq cache.last_refresh_at (Some 42);
  check_eq (Model.select cache "missing") (Error "unknown block: missing");
  check_eq
    (ids (Model.outliner_preorder "page" rows))
    [ "root"; "child"; "orphan"; "cycle-a"; "cycle-b" ];
  Model.upsert_blocks cache rows 43;
  check (ok (Model.select cache "child"));
  (match Model.selected_block cache with
   | Some selected -> check_eq selected.uuid "child"
   | None -> fail "missing selection");
  Model.clear_selection cache;
  check_eq (Model.selected_block cache) None

let partial_refresh_preserves_timestamps_and_journal_relation () =
  let cache = Model.create None in
  Model.cache_local_message cache "stable-created-at" "Original" now;
  Model.upsert_blocks cache
    [ block "stable-created-at" "Updated remotely" "page-1" 0 ]
    (now + 10000);
  let restored = read_block cache "stable-created-at" in
  check_eq restored.created_at now;
  check_eq restored.updated_at now;
  let cache = Model.create None in
  let original = block "search-block" "Before search" "journal-1" 100 in
  Model.upsert_journal_page cache "journal-1" 20260813 "Aug 13th, 2026";
  Model.upsert_blocks cache [ original ] 100;
  Model.upsert_blocks cache
    [
      {
        original with
        Model.title = "Search result";
        page_id = "";
        created_at = 0;
        updated_at = 0;
      };
    ]
    200;
  let recent = Model.recent_blocks cache in
  check_eq (List.length recent) 1;
  check_eq (List.hd recent).page_id "journal-1";
  check_eq (List.hd recent).title "Search result"

let recent_journals_filter_pages_empty_and_future_blocks () =
  let cache = Model.create None in
  Model.upsert_blocks cache
    [
      block "empty-block" "   " "journal-1" 200;
      block "real-block" "Visible" "journal-1" 100;
    ]
    400;
  Model.upsert_journal_page cache "journal-1" 20260813 "";
  check_eq (ids (Model.recent_blocks cache)) [ "real-block" ];
  check_eq
    (ids
       (Model.visible_from cache
          [
            {
              (block "empty-block" "" "journal-1" 100) with
              Model.journal = Some ("Aug 22nd, 2026", 20260822);
            };
          ]))
    [ "empty-block" ];
  let cache = Model.create None in
  Model.upsert_journal_page cache "past-journal" 20260812 "";
  Model.upsert_journal_page cache "future-journal" 20990101 "";
  Model.upsert_blocks cache
    [
      block "past-block" "past-block" "past-journal" 300;
      block "future-block" "future-block" "future-journal" 400;
      block "ordinary-page-block" "ordinary-page-block" "ordinary-page" 500;
    ]
    600;
  check_eq (ids (Model.recent_blocks cache)) [ "past-block" ]

let journal_rows_follow_tree_order_not_timestamps () =
  let cache = Model.create None in
  let row uuid parent order created =
    {
      (block uuid uuid "journal-today" created) with
      Model.parent_id = Some parent;
      order = Some order;
    }
  in
  Model.upsert_journal_page cache "journal-today" 20260815 "";
  Model.upsert_blocks cache
    [
      row "second-root" "journal-today" "a2" 100;
      {
        (block "other-page" "Other" "project" 500) with
        Model.parent_id = Some "project";
        order = Some "a0";
      };
      row "child" "first-root" "a0" 300;
      row "first-root" "journal-today" "a1" 400;
    ]
    500;
  check_eq
    (ids (Model.recent_blocks cache))
    [ "first-root"; "child"; "second-root" ]

let local_task_and_asset_metadata_survive_caching () =
  let cache = Model.create None in
  let status : Model.status =
    {
      uuid = "status-waiting";
      ident = Some "user.status/waiting";
      title = "Waiting";
      icon_type = Some "tabler-icon";
      icon_id = Some "clock";
      icon_color = Some "#7c3aed";
    }
  in
  Model.cache_local_task cache "task-local" "Follow up" status now;
  Model.cache_local_asset cache "asset-local" "voice.m4a" "m4a" 4096
    "checksum" "/documents/voice.m4a" (now + 1) None;
  (match (read_block cache "task-local").status with
   | Some status -> check_eq status.title "Waiting"
   | None -> fail "missing status");
  check_eq (read_block cache "asset-local").asset_type (Some "m4a");
  check_eq (read_block cache "asset-local").local_path
    (Some "/documents/voice.m4a")

let targeted_assets_and_transcripts_inherit_the_editing_page () =
  let cache = Model.create None in
  Model.upsert_blocks cache
    [
      {
        (block "editing-block" "Editing" "page-target" 100) with
        Model.parent_id = Some "page-target";
      };
    ]
    100;
  Model.cache_local_asset cache "audio-asset" "Audio.m4a" "m4a" 4096
    "checksum" "/documents/Audio.m4a" 200 (Some "editing-block");
  check_eq (read_block cache "audio-asset").page_id "page-target";
  check_eq (read_block cache "audio-asset").parent_id (Some "editing-block");
  check (ok (Model.cache_local_child cache "transcript" "Transcript" "audio-asset" 201));
  check_eq (read_block cache "transcript").page_id "page-target";
  check_eq (read_block cache "transcript").parent_id (Some "audio-asset")

let uploaded_assets_merge_local_metadata_into_server_identity () =
  let cache = Model.create None in
  Model.cache_local_asset cache "local-asset" "photo.jpg" "jpg" 2048
    "checksum" "/documents/photo.jpg" now None;
  Model.upsert_blocks cache
    [
      {
        (block "server-asset" "photo" "remote-journal" (now + 100)) with
        Model.parent_id = Some "remote-journal";
      };
    ]
    (now + 100);
  check
    (ok (Model.reconcile_created_block cache "local-asset" "server-asset" "submitted"));
  check_eq (Model.read_block cache "local-asset") None;
  let asset = read_block cache "server-asset" in
  check_eq asset.local_path (Some "/documents/photo.jpg");
  check_eq asset.asset_checksum (Some "checksum");
  check_eq asset.sync_status "submitted";
  check_eq
    (List.length
       (List.filter
          (fun (b : Model.block) -> b.asset_type <> None)
          (Model.all_blocks cache)))
    1

let refresh_preserves_synced_asset_metadata_and_offline_edits () =
  let cache = Model.create None in
  Model.cache_local_asset cache "stable-asset" "photo.jpg" "jpg" 2048
    "checksum" "/documents/photo.jpg" now None;
  check (ok (Model.mark_block_synced cache "stable-asset"));
  Model.upsert_blocks cache
    [ block "stable-asset" "photo.jpg" "journal/2026-08-15" now ]
    (now + 100);
  let asset = read_block cache "stable-asset" in
  check_eq asset.asset_type (Some "jpg");
  check_eq asset.asset_checksum (Some "checksum");
  check_eq asset.local_path (Some "/documents/photo.jpg");
  let cache = Model.create None in
  let original = block "offline-edit" "Server title" "journal/2026-08-15" now in
  Model.upsert_blocks cache [ original ] now;
  check
    (ok
       (Model.update_block_title cache "offline-edit" "Edited offline"
          (now + 100)));
  Model.upsert_blocks cache [ original ] (now + 200);
  check_eq (read_block cache "offline-edit").title "Edited offline";
  check_eq (read_block cache "offline-edit").sync_status "pending"

let local_captures_use_journals_and_remain_retryable_after_failure () =
  let cache = Model.create None in
  Model.cache_local_message cache "local-test" "Capture note" now;
  let captured = read_block cache "local-test" in
  check (captured.page_id <> "local-pending");
  check (String.starts_with ~prefix:"journal/" captured.page_id);
  check_eq captured.sync_status "pending";
  check (ok (Model.mark_block_synced cache "local-test"));
  check_eq (read_block cache "local-test").sync_status "synced";
  Model.cache_local_message cache "local-failed" "Capture failed" (now + 1);
  check (ok (Model.mark_block_sync_failed cache "local-failed"));
  check_eq (read_block cache "local-failed").sync_status "failed";
  check
    (List.exists
       (fun (b : Model.block) -> b.uuid = "local-failed")
       (Model.pending_blocks cache));
  let cache = Model.create None in
  Model.cache_local_message cache "local-block" "Offline capture" now;
  check
    (ok
       (Model.reconcile_created_block cache "local-block" "server-block"
          "submitted"));
  check_eq (Model.read_block cache "local-block") None;
  check_eq (read_block cache "server-block").title "Offline capture";
  check_eq (read_block cache "server-block").sync_status "submitted"

let missing_attributes_default_but_malformed_attributes_raise () =
  let cache = Model.create None in
  Model.commit cache
    [ Ds.Add (Ds.Temp_id "minimal", "block/uuid", Ds.String "minimal") ];
  let minimal = read_block cache "minimal" in
  check_eq minimal.title "";
  check_eq minimal.created_at 0;
  check_eq minimal.sync_status "synced";
  check_eq minimal.asset_size None;
  check_eq (Model.read_block cache "absent") None;
  List.iter
    (fun (attr, value) ->
      let cache = Model.create None in
      cache.db <- Ds.empty_db ~schema:[ List.hd Model.schema ] ();
      Model.commit cache
        [
          Ds.Add (Ds.Temp_id "invalid", "block/uuid", Ds.String "invalid");
          Ds.Add (Ds.Temp_id "invalid", attr, value);
        ];
      check
        (try
           ignore (Model.read_block cache "invalid");
           false
         with Failure _ -> true))
    [
      ("block/title", Ds.Int64 42L);
      ("block/created-at", Ds.Float 1.5);
      ("block/asset-size", Ds.String "large");
      ("block/local-path", Ds.Bool false);
    ]

let cases =
  [
    case "recent captures keep the newest hundred in order"
      recent_captures_keep_the_newest_hundred_in_order;
    case "refresh selection and outliner orphans"
      refresh_selection_and_outliner_orphans;
    case "partial refresh preserves timestamps and journal relation"
      partial_refresh_preserves_timestamps_and_journal_relation;
    case "recent journals filter pages empty and future blocks"
      recent_journals_filter_pages_empty_and_future_blocks;
    case "journal rows follow tree order not timestamps"
      journal_rows_follow_tree_order_not_timestamps;
    case "local task and asset metadata survive caching"
      local_task_and_asset_metadata_survive_caching;
    case "targeted assets and transcripts inherit the editing page"
      targeted_assets_and_transcripts_inherit_the_editing_page;
    case "uploaded assets merge local metadata into server identity"
      uploaded_assets_merge_local_metadata_into_server_identity;
    case "refresh preserves synced asset metadata and offline edits"
      refresh_preserves_synced_asset_metadata_and_offline_edits;
    case "local captures use journals and remain retryable after failure"
      local_captures_use_journals_and_remain_retryable_after_failure;
    case "missing attributes default but malformed attributes raise"
      missing_attributes_default_but_malformed_attributes_raise;
  ]
