module Json = Yojson.Basic
module Json_util = Yojson.Basic.Util
module Types = Session_types
module So = Session_outliner
module Rpc = Rpc
module Model = Cache_model
module Ops = Pending_ops

let pending_request_json (session : Types.session) =
  let s = Types.state session in
  match s.semantic_active with
  | Some active ->
    Rpc.request_json active.id active.request None "application/json" []
  | None ->
    (match s.pending_sync with
     | Some pump ->
       (match !(pump.active) with
        | Some active ->
          (match active.transport with
           | Types.Json_request request ->
             Rpc.request_json active.id request None "application/json" []
           | Types.File_upload upload ->
             Rpc.request_json active.id upload.Api.request
               (Some upload.file_path) upload.content_type upload.headers)
        | None -> `Null)
     | None -> `Null)

let pending_block_unchanged session sent =
  match Model.read_block (Types.state session).model sent.Model.uuid with
  | Some current -> Rpc.same_pending_version sent current
  | None -> false

let mark_pending_failed session (block : Model.block) =
  if pending_block_unchanged session block then
    ignore
      (Model.mark_block_sync_failed (Types.state session).model block.uuid)

let set_pending_active (session : Types.session) (pump : Types.pending_sync) transport operation
    cleanup =
  let next_id = (Types.state session).next_pending_request_id + 1 in
  session.Types.state :=
    { !(session.state) with next_pending_request_id = next_id };
  pump.Types.active :=
    Some { Types.id = next_id; transport; operation; cleanup_path = cleanup }

let encrypted_title session (config : Api.api_config) title =
  match (Types.host session).Types.encrypt_title with
  | Some encrypt -> encrypt config.graph_id title
  | None -> Error "encrypted graph title encryption is unavailable"

let prepare_pending_create_request session (pump : Types.pending_sync) (block : Model.block) title
    page_id =
  let config = pump.Types.config in
  match
    ( block.status
    , block.local_path
    , block.asset_type
    , block.asset_size
    , block.asset_checksum )
  with
  | Some status, _, _, _, _ ->
    set_pending_active session pump
      (Types.Json_request
         (Api.task_request page_id config block.uuid status.uuid title))
      (Types.Create_block block) None;
    Ok ()
  | None, Some source, Some asset_type, Some _, Some checksum ->
    let source = (Types.host session).resolve_asset_path source in
    if So.selected_graph_is_encrypted session then
      match (Types.host session).encrypt_asset_file with
      | Some encrypt ->
        let ( let* ) = Result.bind in
        let* path, _ = encrypt config.graph_id source in
        set_pending_active session pump
          (Types.File_upload
             (Api.raw_asset_upload_request config block.uuid asset_type
                checksum path "text/plain"))
          (Types.Upload_asset block) (Some path);
        Ok ()
      | None -> Error "encrypted asset encryption is unavailable"
    else begin
      set_pending_active session pump
        (Types.File_upload
           (Api.raw_asset_upload_request config block.uuid asset_type
              checksum source (Api.content_type_for_asset_type asset_type)))
        (Types.Upload_asset block) None;
      Ok ()
    end
  | None, None, None, None, None ->
    let request =
      match block.parent_id with
      | Some parent when parent <> block.page_id ->
        Api.child_block_request config parent block.uuid title
      | _ -> Api.capture_request page_id config block.uuid title
    in
    set_pending_active session pump
      (Types.Json_request request) (Types.Create_block block) None;
    Ok ()
  | _ -> Error "pending block has incomplete semantic REST metadata"

let prepare_pending_creation session (pump : Types.pending_sync) (block : Model.block) =
  let ( let* ) = Result.bind in
  if So.selected_graph_is_encrypted session then
    let* title = encrypted_title session pump.Types.config block.title in
    let day = Model.journal_day_for_ms block.created_at in
    let page =
      match Hashtbl.find_opt pump.Types.resolved_journal_pages day with
      | Some page -> Some page
      | None ->
        (match (Types.host session).journal_page_id with
         | Some find -> find day
         | None -> None)
    in
    (match page with
     | Some page -> prepare_pending_create_request session pump block title (Some page)
     | None ->
       let page = Rpc.journal_page_uuid day in
       let journal_title = Rpc.journal_day_title day in
       let* journal_title =
         encrypted_title session pump.config journal_title
       in
       let* journal_name =
         encrypted_title session pump.config
           (String.lowercase_ascii (Rpc.journal_day_title day))
       in
       set_pending_active session pump
         (Types.Json_request
            (Api.encrypted_journal_page_request pump.config page
               journal_title journal_name day))
         (Types.Create_journal
            {
              Types.block;
              encrypted_title = title;
              page_id = page;
              journal_day = day;
            })
         None;
       Ok ())
  else
    prepare_pending_create_request session pump block block.title
      (match block.parent_id with
       | Some _ -> Some block.page_id
       | None -> None)

let prepare_pending_block session (pump : Types.pending_sync) (block : Model.block) =
  if Hashtbl.mem pump.Types.authoritative block.uuid then begin
    let ( let* ) = Result.bind in
    let* title =
      if So.selected_graph_is_encrypted session then
        encrypted_title session pump.config block.title
      else Ok block.title
    in
    set_pending_active session pump
      (Types.Json_request
         (Api.update_block_request pump.config block.uuid title))
      (Types.Update_title block) None;
    Ok ()
  end
  else prepare_pending_creation session pump block

let rec prepare_pending_next (session : Types.session) (pump : Types.pending_sync) =
  match !(pump.Types.remaining) with
  | block :: _ ->
    pump.remaining := List.tl !(pump.remaining);
    (match prepare_pending_block session pump block with
     | Ok () -> ()
     | Error message ->
       Types.debug
         ("prepare pending block failed uuid=" ^ block.uuid
          ^ " message=" ^ message);
       mark_pending_failed session block;
       prepare_pending_next session pump)
  | [] ->
    pump.active := None;
    session.state := { !(session.state) with pending_sync = None }

let activate_semantic_request (session : Types.session) config accepted =
  let s = Types.state session in
  let caught_up =
    match Types.projection_server_t session, s.accepted_server_t with
    | Some local, Some latest -> local >= latest
    | _ -> true
  in
  if s.semantic_active = None && caught_up then
    match s.semantic_queue with
    | pending :: _ ->
      (match (Types.host session).prepare_operation with
       | Some prepare ->
         (match prepare pending.operation with
          | Error message ->
            Types.debug
              ("semantic operation id=" ^ pending.operation.operation_id
               ^ " is waiting for authoritative dependencies: " ^ message)
          | Ok (outliner_op, tx) ->
            let operation = pending.operation in
            let latest =
              match Types.submission_server_t session with
              | Some t -> t
              | None -> operation.base_t
            in
            let before =
              match accepted with
              | Some accepted -> max latest accepted
              | None -> latest
            in
            let tx_id =
              match operation.Ops.intent with
              | Ops.Create_asset asset -> asset.uuid
              | _ -> operation.operation_id
            in
            let request =
              Api.tx_batch_request config before tx_id outliner_op tx
            in
            let next_id = s.next_pending_request_id + 1 in
            session.state :=
              {
                !(session.state) with
                next_pending_request_id = next_id;
                semantic_queue = List.tl s.semantic_queue;
                semantic_active =
                  Some { Types.id = next_id; pending; request };
              })
       | None -> ())
    | [] -> ()

let enqueue_semantic (session : Types.session) operation =
  match
    ( (Types.host session).stage_operation
    , (Types.host session).prepare_operation )
  with
  | Some stage, Some _ ->
    let ( let* ) = Result.bind in
    let* () = stage operation in
    session.state :=
      {
        !(session.state) with
        semantic_queue =
          (Types.state session).semantic_queue
          @ [ { Types.operation } ];
      };
    Ok ()
  | _ -> Error "projected graph operations are unavailable"

let normalize_operation_titles session operation =
  let normalizer =
    match (Types.host session).graph_normalize_titles with
    | Some normalize -> Some (fun uuid titles -> normalize uuid titles)
    | None -> None
  in
  Rpc.normalize_operation_titles normalizer Types.fresh_squuid
    Types.now_ms operation

let capture_operations session uuid title now status =
  Rpc.capture_operations
    (Types.projection_server_t session)
    uuid title now status
    (fun () -> So.base_outliner_context session)
    (Types.host session).journal_page_id Types.fresh_squuid
    (fun operation -> normalize_operation_titles session operation)

let enqueue_capture session uuid title now status =
  let ( let* ) = Result.bind in
  let* operations = capture_operations session uuid title now status in
  List.fold_left
    (fun result operation ->
      let* () = result in
      enqueue_semantic session operation)
    (Ok ()) operations

let restore_semantic_queue (session : Types.session) =
  match (Types.host session).pending_operations with
  | Some pending ->
    let active =
      match (Types.state session).semantic_active with
      | Some active -> Some active.Types.pending.operation.operation_id
      | None -> None
    in
    session.state :=
      {
        !(session.state) with
        semantic_queue =
          List.filter_map
            (fun (operation : Ops.pending_operation) ->
              if Some operation.operation_id = active then None
              else Some { Types.operation })
            (pending ());
      }
  | None -> ()

let begin_pending_sync (session : Types.session) (config : Api.api_config) =
  if not (String_kit.is_blank config.token) then begin
    restore_semantic_queue session;
    let pending = Model.pending_blocks (Types.state session).model in
    let assets = List.filter (fun b -> b.Model.is_asset) pending in
    if assets = [] then activate_semantic_request session config None;
    let s = Types.state session in
    if s.semantic_active = None && s.pending_sync = None then begin
      let authoritative = Hashtbl.create 64 in
      (match (Types.host session).authoritative_graph_blocks with
       | Some load ->
         (match load () with
          | Some blocks ->
            List.iter
              (fun (b : Model.block) -> Hashtbl.replace authoritative b.uuid ())
              blocks
          | None -> ())
       | None -> ());
      let pump =
        {
          Types.config;
          remaining = ref (if assets = [] then pending else assets);
          authoritative;
          resolved_journal_pages = Hashtbl.create 16;
          active = ref None;
        }
      in
      session.state := { !(session.state) with pending_sync = Some pump };
      prepare_pending_next session pump
    end
  end

let settle_semantic_active (session : Types.session) active succeeded
    accepted =
  let next_state =
    if not succeeded then Ops.Retryable
    else
      match accepted with
      | Some t -> Ops.Accepted t
      | None -> Ops.Submitted
  in
  (match (Types.host session).stage_operation with
   | Some stage ->
     ignore (stage { active.Types.pending.operation with Ops.state = next_state })
   | None -> ());
  (if succeeded then
     match accepted with
     | Some accepted -> Types.record_accepted_server_t session accepted
     | None -> ());
  session.state := { !(session.state) with semantic_active = None }

let finish_semantic_active session active succeeded accepted =
  settle_semantic_active session active succeeded accepted;
  if succeeded then
    match (Types.state session).config with
    | Some config -> activate_semantic_request session config accepted
    | None -> ()

let cleanup_pending_active session (active : Types.pending_active) =
  match active.cleanup_path with
  | Some path -> (Types.host session).cleanup_file path
  | None -> ()

let rec finish_pending_block session (pump : Types.pending_sync) (block : Model.block) succeeded =
  if succeeded then
    (if pending_block_unchanged session block then
       ignore
         (Model.mark_block_submitted (Types.state session).model
            block.uuid))
  else mark_pending_failed session block;
  pump.Types.active := None;
  prepare_pending_next session pump

let asset_datoms_operation session block status =
  Rpc.asset_datoms_operation
    (Types.projection_server_t session)
    status block
    (fun () -> So.base_outliner_context session)
    (Types.host session).journal_page_id

let reconcile_created_block session (pump : Types.pending_sync) (block : Model.block) remote_uuid =
  ignore
    (Model.reconcile_created_block
       (Types.state session).model block.uuid remote_uuid
       (if pending_block_unchanged session block then "submitted"
        else "pending"));
  pump.Types.active := None;
  prepare_pending_next session pump

let rec complete_pending_active session (pump : Types.pending_sync)
    (active : Types.pending_active) (response : Api.api_response) =
  if response.status < 200 || response.status > 299 then
    finish_pending_block session pump
      (Types.transport_operation_block active.operation)
      false
  else
    match active.operation with
    | Types.Update_title block ->
      (match block.status with
       | Some status ->
         set_pending_active session pump
           (Types.Json_request
              (Api.update_block_status_request pump.config block.uuid
                 status.uuid))
           (Types.Update_status block) None
       | None -> finish_pending_block session pump block true)
    | Types.Update_status block ->
      finish_pending_block session pump block true
    | Types.Create_journal journal ->
      Hashtbl.replace pump.Types.resolved_journal_pages
        journal.journal_day journal.page_id;
      pump.active := None;
      (match
         prepare_pending_create_request session pump journal.block
           journal.encrypted_title (Some journal.page_id)
       with
       | Ok () -> ()
       | Error message ->
         Types.debug
           ("prepare pending create after journal failed uuid="
            ^ journal.block.uuid ^ " message=" ^ message);
         mark_pending_failed session journal.block;
         prepare_pending_next session pump)
    | Types.Upload_asset block ->
      (match asset_datoms_operation session block Ops.Queued with
       | Error message ->
         Types.debug
           ("prepare asset datoms failed uuid=" ^ block.uuid
            ^ " message=" ^ message);
         finish_pending_block session pump block false
       | Ok operation ->
         (match enqueue_semantic session operation with
          | Error message ->
            Types.debug
              ("stage asset datoms failed uuid=" ^ block.uuid
               ^ " message=" ^ message);
            finish_pending_block session pump block false
          | Ok () ->
            let queue = (Types.state session).semantic_queue in
            let is_asset (pending : Types.semantic_pending) =
              pending.operation.operation_id = operation.Ops.operation_id
            in
            session.state :=
              {
                !(session.state) with
                semantic_queue =
                  List.filter is_asset queue
                  @ List.filter (fun p -> not (is_asset p)) queue;
              };
            finish_pending_block session pump block true;
            activate_semantic_request session pump.config None))
    | Types.Create_block block ->
      (match
         try Ok (Api.created_block_uuid_from_body response.body)
         with error -> Error (Printexc.to_string error)
       with
       | Error message ->
         Types.debug
           ("pending creation response failed uuid=" ^ block.uuid
            ^ " message=" ^ message);
         finish_pending_block session pump block false
       | Ok remote ->
         (match (block.local_path, block.parent_id) with
          | Some _, Some parent ->
            set_pending_active session pump
              (Types.Json_request
                 (Api.move_block_request pump.config remote parent))
              (Types.Move_created_asset
                 { Types.block; remote_uuid = remote })
              None
          | _ -> reconcile_created_block session pump block remote))
    | Types.Move_created_asset moved ->
      reconcile_created_block session pump moved.block moved.remote_uuid

let accepted_transaction body =
  try
    match Json.from_string body with
    | `Assoc _ as body ->
      let rejected =
        Json_util.member "type" body = `String "tx/reject"
      in
      let accepted =
        match
          (Json_util.member "acceptedT" body, Json_util.member "t" body)
        with
        | `Int t, _ -> Some t
        | _, `Int t -> Some t
        | _ -> None
      in
      (rejected, accepted)
    | _ -> (false, None)
  with _ -> (false, None)

let completion_error input =
  match Json_util.member "error" input with
  | `String message when message <> "" -> Some message
  | _ -> None

let validate_completion_id input expected_id =
  match input with
  | `Assoc _ ->
    (match Json_util.member "id" input with
     | `Int id ->
       if id = expected_id then Ok id
       else Error "pending sync request id does not match"
     | _ -> Error "pending sync completion requires id")
  | _ -> Error "pending sync completion must be an object"

let parse_semantic_completion input expected_id =
  let ( let* ) = Result.bind in
  let* _ = validate_completion_id input expected_id in
  match completion_error input with
  | Some _ -> Ok (false, None)
  | None ->
    (match Json_util.member "status" input with
     | `Int status ->
       let rejected, accepted =
         match Json_util.member "body" input with
         | `String body -> accepted_transaction body
         | _ -> (false, None)
       in
       Ok
         ( status >= 200 && status <= 299 && not rejected
         , if rejected then None else accepted )
     | _ -> Error "pending transport returned no HTTP status")

let parse_transport_completion input expected_id =
  let ( let* ) = Result.bind in
  let* _ = validate_completion_id input expected_id in
  Ok
    (match completion_error input with
     | Some message -> Error message
     | None ->
       (match Json_util.member "status" input with
        | `Int status ->
          Ok
            {
              Api.status;
              body =
                (match Json_util.member "body" input with
                 | `String body -> body
                 | _ -> "");
            }
        | _ -> Error "pending transport returned no HTTP status"))

let complete_semantic_response session (active : Types.semantic_active)
    input =
  try
    let ( let* ) = Result.bind in
    let* succeeded, accepted =
      parse_semantic_completion input active.id
    in
    settle_semantic_active session active succeeded accepted;
    (if not succeeded then
       match Json_util.member "body" input with
       | `String body ->
         (match Json.from_string body with
          | `Assoc _ as rejection when Json_util.member "type" rejection = `String "tx/reject" ->
            (match Json_util.member "t" rejection with
             | `Int t when t >= 0 -> Types.record_accepted_server_t session t
             | _ -> ());
            let reason = match Json_util.member "reason" rejection with
              | `String reason -> reason
              | _ -> "transaction rejected"
            in
            if reason <> "stale" && Json_util.member "retryable" rejection <> `Bool true then
              (match (Types.host session).stage_operation with
               | Some stage ->
                 ignore (stage { active.pending.operation with Ops.state = Ops.Conflicted reason })
               | None -> ())
          | _ -> ())
       | _ -> ());
    let* () =
      match succeeded, (Types.host session).apply_sync_event, Json_util.member "body" input with
      | true, Some apply, `String body ->
        let* journal = Journal_sync.decode body in
        (match Types.projection_server_t session, journal.t_before with
         | Some local, Some before when local < before -> Ok ()
         | _ ->
           let scoped_body = match (Types.state session).config, Json.from_string body with
             | Some config, `Assoc fields ->
               Json.to_string (`Assoc (("graphId", `String config.graph_id) :: List.remove_assoc "graphId" fields))
             | _ -> body
           in
           apply scoped_body)
      | _ -> Ok ()
    in
    if succeeded then begin
      restore_semantic_queue session;
      match (Types.state session).config with
      | Some config -> activate_semantic_request session config accepted
      | None -> ()
    end;
    Ok ()
  with error ->
    Error ("invalid pending sync completion: " ^ Printexc.to_string error)

let complete_transport_response session (pump : Types.pending_sync)
    (active : Types.pending_active) input =
  try
    let ( let* ) = Result.bind in
    let* response = parse_transport_completion input active.id in
    cleanup_pending_active session active;
    (match response with
     | Ok response -> complete_pending_active session pump active response
     | Error message ->
       Types.debug
         ("pending transport failed id=" ^ string_of_int active.id
          ^ " message=" ^ message);
       finish_pending_block session pump
         (Types.transport_operation_block active.operation)
         false);
    Ok ()
  with error ->
    Error ("invalid pending sync completion: " ^ Printexc.to_string error)

let complete_pending_sync (session : Types.session) payload =
  let input = Json.from_string payload in
  let id =
    match input with
    | `Assoc _ ->
      (match Json_util.member "id" input with
       | `Int id when id > 0 -> Some id
       | _ -> None)
    | _ -> None
  in
  let stale expected =
    match id with
    | Some id -> id < expected
    | None -> false
  in
  let finished =
    match id with
    | Some id -> id <= (Types.state session).next_pending_request_id
    | None -> false
  in
  match (Types.state session).semantic_active with
  | Some active ->
    if stale active.id then Ok ()
    else complete_semantic_response session active input
  | None ->
    (match (Types.state session).pending_sync with
     | Some pump ->
       (match !(pump.active) with
        | Some active ->
          if stale active.id then Ok ()
          else complete_transport_response session pump active input
        | None ->
          if finished then Ok ()
          else Error "pending sync has no active request")
     | None ->
       if finished then Ok ()
       else Error "pending sync is not active")

let cancel_pending_sync (session : Types.session) =
  (match (Types.state session).semantic_active with
   | Some active ->
     session.state :=
       {
         !(session.state) with
         semantic_queue =
           active.Types.pending :: (Types.state session).semantic_queue;
         semantic_active = None;
       }
   | None -> ());
  (match (Types.state session).pending_sync with
   | Some pump ->
     (match !(pump.Types.active) with
      | Some active -> cleanup_pending_active session active
      | None -> ())
   | None -> ());
  session.state := { !(session.state) with pending_sync = None }
