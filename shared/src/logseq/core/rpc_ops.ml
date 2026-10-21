module Json = Yojson.Basic
module Wire = Rpc_wire
module Model = Cache_model
module Ops = Pending_ops
module Order = Fractional_order
module Effects = Outliner_effects
module Outliner = Outliner_state
module Bootstrap = Graph_bootstrap

let same_status left right =
  (match left with
   | Some (status : Model.status) -> Some status.uuid
   | None -> None)
  =
  match right with
  | Some (status : Model.status) -> Some status.uuid
  | None -> None

let same_pending_version (left : Model.block) (right : Model.block) =
  left.uuid = right.uuid
  && left.title = right.title
  && left.updated_at = right.updated_at
  && same_status left.status right.status
  && left.asset_size = right.asset_size
  && left.asset_checksum = right.asset_checksum
  && left.local_path = right.local_path

let reconcile_authoritative_blocks cache blocks =
  let by_uuid =
    List.map (fun (block : Model.block) -> (block.uuid, block)) blocks
  in
  List.iter
    (fun (block : Model.block) ->
      match List.assoc_opt block.uuid by_uuid with
      | Some (authoritative : Model.block) ->
        if
          block.sync_status = "submitted"
          || (block.title = authoritative.title
              && same_status block.status authoritative.status)
        then ignore (Model.mark_block_synced cache block.uuid)
      | None -> ())
    (Model.unsynced_blocks cache)

let normalize_title_intent normalize (intent : Ops.pending_intent) =
  match intent with
  | Ops.Save_title value ->
    let titles, tags = normalize value.uuid [ value.title ] in
    ( (match titles with
       | [ title ] -> Ops.Save_title { value with Ops.title }
       | _ -> intent)
    , tags )
  | Ops.Insert_block value ->
    let titles, tags = normalize value.uuid [ value.title ] in
    ( (match titles with
       | [ title ] -> Ops.Insert_block { value with Ops.title }
       | _ -> intent)
    , tags )
  | Ops.Split_block value ->
    let titles, tags = normalize value.uuid [ value.before; value.after ] in
    ( (match titles with
       | [ before; after ] -> Ops.Split_block { value with Ops.before; after }
       | _ -> intent)
    , tags )
  | Ops.Merge_backward value ->
    let titles, tags = normalize value.uuid [ value.title ] in
    ( (match titles with
       | [ title ] -> Ops.Merge_backward { value with Ops.title }
       | _ -> intent)
    , tags )
  | _ -> (intent, [])

let normalize_operation_titles normalizer fresh_id clock
    (operation : Ops.pending_operation) =
  match normalizer with
  | Some normalize ->
    let intent, tags = normalize_title_intent normalize operation.intent in
    let created =
      List.map
        (fun (uuid, title) ->
          {
            Ops.operation_id = fresh_id ();
            base_t = operation.base_t;
            state = Ops.Queued;
            intent =
              Ops.Create_tag
                { Ops.uuid; title; created_at = clock () };
          })
        tags
    in
    created @ [ { operation with Ops.intent } ]
  | None -> [ operation ]

let capture_operation base_t uuid title now load_context journal_page_id
    fresh_id =
  let ( let* ) = Result.bind in
  let journal_day = Model.journal_day_for_ms now in
  let page =
    match journal_page_id with
    | Some find_page -> find_page journal_day
    | None -> None
  in
  match page with
  | Some page_uuid ->
    let last_order =
      Effects.sorted_siblings (load_context ()) (Some page_uuid)
      |> List.filter (fun block -> block.Model.page_id = page_uuid)
      |> List.filter_map (fun block -> block.Model.order)
      |> List.fold_left (fun _ order -> Some order) None
    in
    let* position = Order.between last_order None in
    Ok
      (Effects.operation base_t fresh_id
         (Ops.Insert_block
            {
              Ops.uuid;
              title;
              page_uuid;
              parent_uuid = page_uuid;
              order = position;
              created_at = now;
            }))
  | None ->
    Ok
      (Effects.operation base_t fresh_id
         (Ops.Create_journal
            {
              Ops.page_uuid = Wire.journal_page_uuid journal_day;
              block_uuid = uuid;
              title;
              journal_day;
              created_at = now;
            }))

let capture_operations cursor uuid title now status load_context
    journal_page_id fresh_id normalize =
  let ( let* ) = Result.bind in
  match cursor with
  | Some base_t ->
    let* operation =
      capture_operation base_t uuid title now load_context journal_page_id
        fresh_id
    in
    let status_operations =
      match status with
      | Some (value : Model.status) ->
        [
          Effects.operation base_t fresh_id
            (Ops.Set_property
               {
                 Ops.uuid;
                 attr = "logseq.property/status";
                 expected = None;
                 value =
                   Some
                     (match value.ident with
                      | Some ident -> Ops.Ref_ident ident
                      | None -> Ops.Ref_uuid value.uuid);
               })
        ]
      | None -> []
    in
    Ok (normalize operation @ status_operations)
  | None -> Error "A current server cursor is required"

let asset_destination context (block : Model.block) journal_page_id =
  match block.parent_id with
  | Some parent_uuid ->
    (match Outliner.find_block context parent_uuid with
     | Some parent -> Some (parent.Model.page_id, parent_uuid)
     | None -> None)
  | None ->
    (match journal_page_id with
     | Some find_page ->
       (match find_page (Model.journal_day_for_ms block.created_at) with
        | Some page_uuid -> Some (page_uuid, page_uuid)
        | None -> None)
     | None -> None)

let asset_datoms_operation cursor state (block : Model.block) load_context
    journal_page_id =
  let ( let* ) = Result.bind in
  match cursor with
  | Some base_t ->
    (match (block.asset_type, block.asset_size, block.asset_checksum) with
     | Some asset_type, Some asset_size, Some asset_checksum ->
       let context = load_context () in
       (match asset_destination context block journal_page_id with
        | Some (page_uuid, parent_uuid) ->
          let last_order =
            context.Outliner.blocks
            |> List.filter (fun (candidate : Model.block) ->
                   candidate.page_id = page_uuid
                   && candidate.parent_id = Some parent_uuid
                   && candidate.uuid <> block.uuid)
            |> List.filter_map (fun candidate -> candidate.Model.order)
            |> List.sort compare
            |> List.fold_left (fun _ order -> Some order) None
          in
          let* position = Order.between last_order None in
          Ok
            {
              Ops.operation_id = "asset:" ^ block.uuid;
              base_t;
              state;
              intent =
                Ops.Create_asset
                  {
                    Ops.uuid = block.uuid;
                    title = block.title;
                    page_uuid;
                    parent_uuid;
                    order = position;
                    created_at = block.created_at;
                    asset_type;
                    asset_size;
                    asset_checksum;
                    transcript = None;
                  };
            }
        | None -> Error "asset destination is not available")
     | _ -> Error "asset metadata is incomplete")
  | None -> Error "A current server cursor is required"

let projected_status (value : Ops.semantic_value option) =
  match value with
  | Some (Ops.Ref_ident ident) ->
    let uuid, title =
      match ident with
      | "logseq.property/status.backlog" -> ("backlog", "Backlog")
      | "logseq.property/status.todo" -> ("todo", "Todo")
      | "logseq.property/status.doing" -> ("doing", "Doing")
      | "logseq.property/status.in-review" -> ("in-review", "In Review")
      | "logseq.property/status.done" -> ("done", "Done")
      | "logseq.property/status.canceled" -> ("canceled", "Canceled")
      | _ -> (ident, ident)
    in
    Some
      {
        Model.uuid;
        title;
        ident = Some ident;
        icon_type = None;
        icon_id = None;
        icon_color = None;
      }
  | Some (Ops.Ref_uuid uuid) ->
    Some
      {
        Model.uuid = uuid;
        title = uuid;
        ident = None;
        icon_type = None;
        icon_id = None;
        icon_color = None;
      }
  | _ -> None

let rec project_outliner_intent (blocks : Model.block list)
    (intent : Ops.pending_intent) =
  match intent with
  | Ops.Save_title value ->
    List.map
      (fun (block : Model.block) ->
        if block.uuid = value.uuid then { block with title = value.title }
        else block)
      blocks
  | Ops.Insert_block value ->
    blocks
    @ [
        {
          (Model.local_block value.uuid value.title value.page_uuid
             (Some value.parent_uuid) value.created_at)
          with
          Model.order = Some value.order;
        };
      ]
  | Ops.Create_asset value ->
    let asset =
      {
        (Model.local_block value.uuid value.title value.page_uuid
           (Some value.parent_uuid) value.created_at)
        with
        Model.order = Some value.order;
        is_asset = true;
        asset_type = Some value.asset_type;
        asset_size = Some value.asset_size;
        asset_checksum = Some value.asset_checksum;
      }
    in
    let blocks = if List.exists (fun block -> block.Model.uuid = value.uuid) blocks
    then
      List.map
        (fun (block : Model.block) ->
          if block.uuid = value.uuid then
            { asset with Model.local_path = block.local_path }
          else block)
        blocks
    else blocks @ [ asset ] in
    (match value.transcript with
     | None -> blocks
     | Some child ->
       if List.exists (fun (block : Model.block) -> block.uuid = child.uuid) blocks then blocks
       else project_outliner_intent blocks (Ops.Insert_block child))
  | Ops.Split_block value ->
    (match
       List.find_opt (fun block -> block.Model.uuid = value.uuid) blocks
     with
     | Some source ->
       List.map
         (fun (block : Model.block) ->
           if block.uuid = value.uuid then
             { block with title = value.before }
           else block)
         blocks
       @ [
           {
             (Model.local_block value.new_uuid value.after source.page_id
                source.parent_id value.created_at)
             with
             Model.order = Some value.new_order;
             journal = source.journal;
           };
         ]
     | None -> blocks)
  | Ops.Merge_backward value ->
    let previous_title =
      match
        List.find_opt
          (fun block -> block.Model.uuid = value.previous_uuid)
          blocks
      with
      | Some previous -> previous.title
      | None -> ""
    in
    let title =
      match value.merged_title with
      | Some merged -> merged
      | None -> previous_title ^ value.title
    in
    List.map
      (fun (block : Model.block) ->
        if block.uuid = value.previous_uuid then
          { block with title; sync_status = "pending" }
        else block)
      (List.filter
         (fun block -> block.Model.uuid <> value.uuid)
         blocks)
  | Ops.Move_block value ->
    List.map
      (fun (block : Model.block) ->
        if block.uuid = value.uuid then
          {
            block with
            page_id = value.page_uuid;
            parent_id = Some value.parent_uuid;
            order = Some value.order;
            sync_status = "pending";
          }
        else block)
      blocks
  | Ops.Move_blocks value ->
    List.fold_left
      (fun result move -> project_outliner_intent result (Ops.Move_block move))
      blocks value.moves
  | Ops.Delete_blocks value ->
    List.filter
      (fun block -> not (List.mem block.Model.uuid value.uuids))
      blocks
  | Ops.Set_property value ->
    if value.attr = "logseq.property/status" then
      let status = projected_status value.value in
      List.map
        (fun (block : Model.block) ->
          if block.uuid = value.uuid then
            { block with status; sync_status = "pending" }
          else block)
        blocks
    else blocks
  | _ -> blocks

let merge_live_block_metadata (optimistic : Model.block)
    (live : Model.block) =
  {
    optimistic with
    updated_at = live.updated_at;
    sync_status = live.sync_status;
    tags = live.tags;
    references = live.references;
    breadcrumbs = live.breadcrumbs;
    status = live.status;
    display_type = live.display_type;
    is_asset = live.is_asset;
    asset_type = live.asset_type;
    asset_size = live.asset_size;
    asset_checksum = live.asset_checksum;
    local_path = live.local_path;
    journal = live.journal;
  }

let page_blocks_with_optimistic_overlay cached editing page_uuid
    live_blocks =
  if editing then
    match cached with
    | Some blocks ->
      let live_by_uuid =
        List.map
          (fun (block : Model.block) -> (block.uuid, block))
          (List.rev live_blocks)
      in
      List.map
        (fun (block : Model.block) ->
          match List.assoc_opt block.uuid live_by_uuid with
          | Some live -> merge_live_block_metadata block live
          | None -> block)
        (List.filter
           (fun block -> block.Model.page_id = page_uuid)
           blocks)
    | None -> live_blocks
  else live_blocks

let upload_initial_graph_snapshot (config : Api.api_config) e2ee
    encrypt_title upload_file cleanup_file =
  let ( let* ) = Result.bind in
  let* encrypt_text =
    if e2ee then
      match encrypt_title with
      | Some encrypt ->
        Ok (fun value -> encrypt config.graph_id value)
      | None -> Error "E2EE title encryption is unavailable"
    else Ok (fun value -> Ok value)
  in
  let* prepared = Bootstrap.prepare config.graph_id e2ee encrypt_text in
  Fun.protect
    ~finally:(fun () -> cleanup_file prepared.file_path)
    (fun () ->
      let* response =
        upload_file
          (Api.initial_snapshot_upload_request config prepared.file_path
             prepared.checksum)
      in
      if response.Api.status >= 200 && response.Api.status <= 299 then begin
        prerr_endline
          (Printf.sprintf
             "Logseq core initial graph snapshot uploaded graph=%s rows=%d"
             config.graph_id prepared.row_count);
        Ok ()
      end
      else
        Error
          (if response.Api.body = "" then
             Printf.sprintf "Initial snapshot upload failed with HTTP %d"
               response.Api.status
           else response.Api.body))

let import_snapshot payload importer project completed =
  match (importer, payload) with
  | None, _ ->
    Wire.failure "snapshot_import_unavailable" "Snapshot import is unavailable"
  | _, None ->
    Wire.failure "invalid_params" "importSnapshot requires a JSON payload"
  | Some importer, Some payload ->
    Wire.action_response
      (let ( let* ) = Result.bind in
       let* () =
         Wire.graph_workflow_result "snapshot_import_failed" (importer payload)
       in
       let* () =
         Wire.graph_workflow_result "graph_projection_failed" (project payload)
       in
       Ok (completed ()))

let open_graph payload open_storage project completed =
  match (open_storage, payload) with
  | None, _ ->
    Wire.failure "graph_open_unavailable" "Graph storage is unavailable"
  | _, None ->
    Wire.failure "invalid_params" "openGraph requires a JSON payload"
  | Some open_storage, Some payload ->
    Wire.action_response
      (let ( let* ) = Result.bind in
       let* () =
         Wire.graph_workflow_result "graph_open_failed" (open_storage payload)
       in
       let* () =
         Wire.graph_workflow_result "graph_projection_failed" (project payload)
       in
       Ok (completed ()))

let apply_sync_event payload apply_event completed =
  match (apply_event, payload) with
  | None, _ ->
    Wire.failure "websocket_unavailable" "WebSocket sync is unavailable"
  | _, None ->
    Wire.failure "invalid_params" "applySyncEvent requires a payload"
  | Some apply_event, Some event ->
    (match apply_event event with
     | Ok () -> completed ()
     | Error message ->
       Wire.failure
         (if
            String_kit.starts_with ~prefix:"snapshot required:" message
            || message = "sync schema mismatch"
          then "snapshot_required"
          else "websocket_apply_failed")
         message)

let asset_metadata fields =
  match
    ( Wire.required_string fields "uuid"
    , Wire.required_string fields "title"
    , Wire.optional_int fields "now"
    , Wire.required_string fields "assetType"
    , Wire.optional_int fields "assetSize"
    , Wire.required_string fields "assetChecksum"
    , Wire.required_string fields "localPath"
    , Wire.optional_string fields "targetBlockId" )
  with
  | Ok uuid, Ok title, Ok now, Ok asset_type, Ok (Some asset_size)
  , Ok checksum, Ok local_path, Ok target ->
    Ok (uuid, title, now, asset_type, asset_size, checksum, local_path, target)
  | _ -> Error ("invalid_params", "addAsset requires complete file metadata")

let add_asset ?(prepare_file = (fun _ path -> Ok path)) payload cache clock load_target prepare_view prepare_operation
    load_stage =
  match payload with
  | Some payload ->
    Wire.action_response
      (let ( let* ) = Result.bind in
       let* fields = Wire.action_fields "addAsset" payload in
       let* metadata = asset_metadata fields in
       let ( uuid
           , title
           , requested_now
           , asset_type
           , asset_size
           , checksum
           , local_path
           , target ) =
         metadata
       in
       let* transcript = Wire.graph_workflow_result "invalid_params"
         (let* title = Wire.optional_string fields "transcript" in
          let* child_id = Wire.optional_string fields "transcriptUUID" in
          match title, child_id with
          | None, _ | Some "", _ -> Ok None
          | Some title, Some child_id when child_id <> "" && child_id <> uuid -> Ok (Some (child_id, title))
          | _ -> Error "A transcript requires a distinct transcriptUUID") in
       let now =
         match requested_now with
         | Some now -> now
         | None -> clock ()
       in
       let* local_path = Wire.graph_workflow_result "asset_import_failed" (prepare_file uuid local_path) in
       let asset_type = Api.normalize_asset_type asset_type in
       let completed = prepare_view () in
       (match target with
        | Some uuid when Model.read_block cache uuid = None ->
          (match load_target uuid with
           | Some block -> Model.upsert_blocks cache [ block ] now
           | None -> ())
        | _ -> ());
       Model.cache_local_asset cache uuid title asset_type asset_size
         checksum local_path now target;
       let cache_transcript submitted = match transcript with
         | None -> ()
         | Some (child_id, title) ->
           ignore (Model.cache_local_child cache child_id title uuid now);
           if submitted then ignore (Model.mark_block_submitted cache child_id) in
       (match (load_stage (), Model.read_block cache uuid) with
        | Some stage, Some block ->
          let* operation =
            Wire.graph_workflow_result "asset_projection_failed"
              (prepare_operation block)
          in
          let operation = match operation.Ops.intent, transcript with
            | Ops.Create_asset asset, Some (child_id, title) ->
              { operation with Ops.intent = Ops.Create_asset { asset with transcript = Some {
                Ops.uuid = child_id; title; page_uuid = asset.page_uuid;
                parent_uuid = asset.uuid; order = "a0"; created_at = now } } }
            | _ -> operation in
          let* () =
            Wire.graph_workflow_result "stage_operation_failed"
              (stage operation)
          in
          cache_transcript true;
          Ok (completed ())
        | _ -> cache_transcript false; Ok (completed ())))
  | None -> Wire.failure "invalid_params" "addAsset requires a JSON payload"

let child_operation base_t context uuid title parent_id now fresh_id =
  let ( let* ) = Result.bind in
  match Outliner.find_block context parent_id with
  | Some parent ->
    let last_order =
      context.Outliner.blocks
      |> List.filter (fun (block : Model.block) ->
             block.page_id = parent.Model.page_id
             && block.parent_id = Some parent.Model.uuid)
      |> List.filter_map (fun block -> block.Model.order)
      |> List.sort compare
      |> List.fold_left (fun _ order -> Some order) None
    in
    let* position = Order.between last_order None in
    Ok
      (Effects.operation base_t fresh_id
         (Ops.Insert_block
            {
              Ops.uuid;
              title;
              page_uuid = parent.page_id;
              parent_uuid = parent.uuid;
              order = position;
              created_at = now;
            }))
  | None -> Error "parent block is unavailable"

let add_child_block payload cache clock load_sync_state load_context enqueue
    fresh_id completed =
  match payload with
  | Some payload ->
    Wire.action_response
      (let ( let* ) = Result.bind in
       let* fields = Wire.action_fields "addChildBlock" payload in
       let* uuid =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "uuid")
       in
       let* title =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "title")
       in
       let* parent_id =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "parentId")
       in
       let* requested_now =
         Wire.graph_workflow_result "invalid_params"
           (Wire.optional_int fields "now")
       in
       let now =
         match requested_now with
         | Some now -> now
         | None -> clock ()
       in
       (match load_sync_state () with
        | Some config, Some base_t ->
          let* operation =
            Wire.graph_workflow_result "invalid_params"
              (child_operation base_t (load_context parent_id) uuid title parent_id
                 now fresh_id)
          in
          let* () =
            Wire.graph_workflow_result "stage_operation_failed"
              (enqueue config operation)
          in
          Ok (completed ())
        | Some _, None ->
          Error ("invalid_params", "A current server cursor is required")
        | None, _ ->
          let* () =
            Wire.graph_workflow_result "invalid_params"
              (Model.cache_local_child cache uuid title parent_id now)
          in
          Ok (completed ())))
  | None ->
    Wire.failure "invalid_params" "addChildBlock requires a JSON payload"

let review_flashcard payload review clock completed =
  match (payload, review) with
  | None, _ ->
    Wire.failure "invalid_params" "reviewFlashcard requires a payload"
  | _, None -> Wire.failure "flashcards_unavailable" "No graph is open"
  | Some payload, Some review ->
    Wire.action_response
      (let ( let* ) = Result.bind in
       let* fields = Wire.action_fields "reviewFlashcard" payload in
       let* uuid =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "uuid")
       in
       let* rating =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "rating")
       in
       let* requested_now =
         Wire.graph_workflow_result "invalid_params"
           (Wire.optional_int fields "now")
       in
       let* operation_id =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "operationId")
       in
       let* rating =
         Wire.graph_workflow_result "invalid_params"
           (Wire.flashcard_rating rating)
       in
       let now =
         match requested_now with
         | Some now -> now
         | None -> clock ()
       in
       let* () =
         Wire.graph_workflow_result "flashcard_review_failed"
           (review uuid rating now operation_id)
       in
       Ok (completed now))

let set_page_favorite payload set_favorite configured clock completed =
  match (payload, set_favorite, configured) with
  | None, _, _ ->
    Wire.failure "invalid_params" "setPageFavorite requires a payload"
  | _, None, _ ->
    Wire.failure "set_page_favorite_unavailable" "No graph is open"
  | _, _, false -> Wire.failure "graph_not_configured" "Select a graph first"
  | Some payload, Some set_favorite, true ->
    Wire.action_response
      (let ( let* ) = Result.bind in
       let* fields = Wire.action_fields "setPageFavorite" payload in
       let* page_uuid =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "pageUuid")
       in
       let* favorite =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_bool fields "favorite")
       in
       let* operation_id =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "operationId")
       in
       let* requested_now =
         Wire.graph_workflow_result "invalid_params"
           (Wire.optional_int fields "now")
       in
       let now =
         match requested_now with
         | Some now -> now
         | None -> clock ()
       in
       let* () =
         Wire.graph_workflow_result "set_page_favorite_failed"
           (set_favorite page_uuid favorite operation_id now)
       in
       Ok (completed ()))

let delete_page payload delete configured clock completed =
  match (payload, delete, configured) with
  | None, _, _ ->
    Wire.failure "invalid_params" "deletePage requires a payload"
  | _, None, _ -> Wire.failure "delete_page_unavailable" "No graph is open"
  | _, _, false -> Wire.failure "graph_not_configured" "Select a graph first"
  | Some payload, Some delete, true ->
    Wire.action_response
      (let ( let* ) = Result.bind in
       let* fields = Wire.action_fields "deletePage" payload in
       let* page_uuid =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "pageUuid")
       in
       let* operation_id =
         Wire.graph_workflow_result "invalid_params"
           (Wire.required_string fields "operationId")
       in
       let* requested_now =
         Wire.graph_workflow_result "invalid_params"
           (Wire.optional_int fields "now")
       in
       let now =
         match requested_now with
         | Some now -> now
         | None -> clock ()
       in
       let* () =
         Wire.graph_workflow_result "delete_page_failed"
           (delete page_uuid operation_id now)
       in
       Ok (completed ()))

let create_sync_graph config payload send ensure_user_keys provision initialize discover
    created =
  match (config, payload) with
  | None, _ ->
    Wire.failure "graph_not_configured"
      "Configure Logseq before creating a graph"
  | _, None ->
    Wire.failure "invalid_params" "createSyncGraph requires a payload"
  | Some config, Some payload ->
    (try
       let result =
         let ( let* ) = Result.bind in
         let* name, encrypted = Wire.graph_creation_payload payload in
         let* () =
           if not encrypted then Ok ()
           else match ensure_user_keys with
           | None -> Ok ()
           | Some ensure ->
             let fields = Yojson.Basic.from_string payload in
             let password = Api.option_string_member "password" fields in
             (match ensure config password with
              | Ok () -> Ok ()
              | Error message ->
                Error ((if message = E2ee_keyring.password_required_message then
                          "e2ee_password_required" else "e2ee_user_keys_failed"), message))
         in
         let* response =
           Wire.graph_workflow_result "graph_create_failed"
             (send (Api.create_graph_request config name "65.33" encrypted))
         in
         let* graph_id =
           Wire.graph_workflow_result "graph_create_failed"
             (Wire.graph_creation_response response)
         in
         let selected =
           { config with Api.graph_id; graph_name = Some name }
         in
         let* () =
           Wire.graph_workflow_result "graph_key_provision_failed"
             (if encrypted then
                match provision with
                | Some provision -> provision selected
                | None -> Error "E2EE key provisioning is unavailable"
              else Ok ())
         in
         let* () =
           Wire.graph_workflow_result "graph_initial_upload_failed"
             (initialize { config with Api.graph_id } encrypted)
         in
         let* () =
           Wire.graph_workflow_result "graph_discovery_failed"
             (discover config)
         in
         Ok (created selected)
       in
       match result with
       | Ok response -> response
       | Error (code, message) -> Wire.failure code message
     with error -> Wire.failure "invalid_json" (Printexc.to_string error))
