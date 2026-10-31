module Json = Yojson.Basic
module Json_util = Yojson.Basic.Util
module Types = Session_types
module So = Session_outliner
module Rpc = Rpc
module Model = Cache_model
module Ops = Pending_ops

let json_field name = function
  | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields)
  | _ -> `Null

let pending_sync_error session =
  let pending = match (Types.host session).load_sync_error with
  | Some load -> load ()
  | None -> (Types.state session).pending_sync_error in
  match pending, Sync_driver.error (Types.state session).sync_transport with
  | None, error | error, None -> error
  | Some pending, Some transport -> Some (pending ^ "\n\n" ^ transport)

let pending_request_json (session : Types.session) =
  let s = Types.state session in
  let request = match s.semantic_active with
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
  in
  match request, s.pending_retry with
  | `Assoc fields, Some retry when List.assoc_opt "id" fields = Some (`Int retry.request_id) ->
    `Assoc (("delayMs", `Int retry.delay_ms) :: fields)
  | _ -> request

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
       let journal_title =
         let db = match (Types.host session).graph_db with
           | Some read -> read () | None -> Some (Types.state session).model.db in
         Option.fold ~none:(Rpc.journal_day_title day) ~some:(fun db -> Journal.title db day) db in
       let journal_name = String.lowercase_ascii journal_title in
       let* journal_title =
         encrypted_title session pump.config journal_title
       in
       let* journal_name =
         encrypted_title session pump.config
           journal_name
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

let semantic_members (active : Types.semantic_active) = active.pending :: active.following

let semantic_tx_id (operation : Ops.pending_operation) =
  match operation.intent with Ops.Create_asset asset -> asset.uuid | _ -> operation.operation_id

let rec singleton_intent = function
  | Ops.Delete_blocks _ | Ops.Delete_page _ -> true
  | Ops.Atomic intents -> List.exists singleton_intent intents
  | _ -> false

let batch_max_operations = 50
let batch_max_bytes = 1_000_000

let activate_semantic_request (session : Types.session) config accepted =
  let s = Types.state session in
  let caught_up = match Types.projection_server_t session, s.accepted_server_t with
    | Some local, Some latest -> local >= latest | _ -> true in
  if s.semantic_active = None && caught_up then
    match s.semantic_queue with
    | [] -> ()
    | first :: _ ->
      let latest = Option.value (Types.submission_server_t session) ~default:first.operation.base_t in
      let before = Option.fold ~none:latest ~some:(max latest) accepted in
      let rec candidates count reversed = function
        | [] -> List.rev reversed
        | _ when count = batch_max_operations -> List.rev reversed
        | (pending : Types.semantic_pending) :: rest ->
          if singleton_intent pending.operation.intent then
            if reversed = [] then [pending] else List.rev reversed
          else candidates (count + 1) (pending :: reversed) rest in
      let candidates = candidates 0 [] s.semantic_queue in
      let operations = List.map (fun (pending : Types.semantic_pending) -> pending.operation) candidates in
      let prepared = match (Types.host session).prepare_operations, (Types.host session).prepare_operation with
        | Some prepare, _ -> prepare operations
        | None, Some prepare -> List.map prepare operations
        | None, None -> [] in
      let empty = Api.tx_batch_websocket_request config before [] in
      let overhead = String.length (Option.get empty.body) in
      let rec pack bytes members wires candidates prepared =
        match candidates, prepared with
        | (pending : Types.semantic_pending) :: rest, Ok (op, tx) :: results ->
          let wire = semantic_tx_id pending.operation, op, tx in
          let size = String.length (Json.to_string (Api.tx_batch_transaction wire)) in
          let total = bytes + size + (if members = [] then 0 else 1) in
          if total > batch_max_bytes then begin
            if members = [] then begin
              let message = "The local transaction exceeds the 1 MB WebSocket message limit" in
              session.state := { !(session.state) with pending_sync_error = Some message };
              Option.iter (fun record -> record ~semantic:true pending.operation.operation_id (Some message))
                (Types.host session).record_sync_failure
            end;
            List.rev members, List.rev wires
          end else pack total (pending :: members) (wire :: wires) rest results
        | pending :: _, Error message :: _ ->
          Types.debug ("semantic operation id=" ^ pending.operation.operation_id
            ^ " is waiting for authoritative dependencies: " ^ message);
          List.rev members, List.rev wires
        | _ -> List.rev members, List.rev wires in
      let members, wires = pack overhead [] [] candidates prepared in
      match members with
      | [] -> ()
      | pending :: following ->
        let rec drop n values = if n = 0 then values else match values with
          | [] -> [] | _ :: rest -> drop (n - 1) rest in
        let next_id = s.next_pending_request_id + 1 in
        session.state := { !(session.state) with
          next_pending_request_id = next_id;
          semantic_queue = drop (List.length members) s.semantic_queue;
          semantic_active = Some { Types.id = next_id; pending; following;
            request = Api.tx_batch_websocket_request config before wires } }

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
    let active_ids = Hashtbl.create batch_max_operations in
    Option.iter (fun active -> List.iter (fun (pending : Types.semantic_pending) ->
      Hashtbl.replace active_ids pending.operation.operation_id ()) (semantic_members active))
      (Types.state session).semantic_active;

    session.state :=
      {
        !(session.state) with
        semantic_queue =
          List.filter_map
            (fun (operation : Ops.pending_operation) ->
              if Hashtbl.mem active_ids operation.operation_id then None
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
     List.iter (fun (pending : Types.semantic_pending) ->
       ignore (stage { pending.operation with Ops.state = next_state })) (semantic_members active)
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
        json_field "type" body = `String "tx/reject"
      in
      let accepted =
        match
          (json_field "acceptedT" body, json_field "t" body)
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

let completion_failure input =
  match completion_error input with
  | Some _ as error -> error
  | None ->
    let body = match Json_util.member "body" input with
      | `String body -> (try Json.from_string body with Yojson.Json_error _ -> `Null)
      | _ -> `Null in
    let text key = match body with
      | `Assoc _ -> (match Json_util.member key body with `String text when text <> "" -> Some text | _ -> None)
      | _ -> None in
    let bounded value = String.sub value 0 (Outliner_state.byte_index_of_utf16 value 4096) in
    let detail = match text "error-detail" with
      | Some _ as detail -> detail
      | None -> (match text "error" with Some _ as detail -> detail | None -> text "message") in
    let detail = match detail with
      | Some detail -> Some (bounded detail)
      | None -> (match Json_util.member "body" input with
          | `String body when body <> "" && not (String.starts_with ~prefix:"{" (String.trim body)) -> Some (bounded body)
          | _ -> None) in
    match Json_util.member "status" input with
    | `Int status when status < 200 || status >= 300 ->
      let reason = match detail with Some _ as reason -> reason | None -> text "reason" in
      let reason = match reason, Json_util.member "body" input with
        | None, `String body when String.trim body <> "" -> Some (bounded body)
        | _ -> reason in
      Some ("Sync server returned HTTP " ^ string_of_int status
        ^ Option.fold ~none:"" ~some:(fun reason -> ": " ^ reason) reason)
    | _ when text "type" = Some "tx/reject" ->
      Some ("Sync server rejected the change: " ^ Option.value ~default:"transaction rejected" (text "reason")
        ^ Option.fold ~none:"" ~some:(fun value -> " — " ^ value) detail)
    | _ -> None

let semantic_settlements (active : Types.semantic_active) input succeeded accepted =
  let members = semantic_members active in
  let retry error = List.map (fun pending -> pending, Ops.Retryable, error) members in
  if succeeded then
    let state = match accepted with Some t -> Ops.Accepted t | None -> Ops.Submitted in
    Ok (List.map (fun pending -> pending, state, None) members)
  else if completion_error input <> None then Ok (retry (completion_error input))
  else
    let body = match Json_util.member "body" input with
      | `String body -> (try Json.from_string body with Yojson.Json_error _ -> `Null)
      | _ -> `Null in
    if json_field "type" body <> `String "tx/reject" then
      Ok (retry (completion_failure input))
    else
      let ( let* ) = Result.bind in
      let* successes = match json_field "success-tx-ids" body with
        | `Null -> Ok []
        | `List ids when List.for_all (function `String _ -> true | _ -> false) ids ->
          Ok (List.map Json_util.to_string ids)
        | _ -> Error "invalid batch rejection success IDs" in
      let reason = match json_field "reason" body with
        | `String reason -> reason | _ -> "transaction rejected" in
      let failure = completion_failure input in
      if reason = "stale" || reason = "snapshot upload in progress" then
        if successes <> [] then Error "batch rejection has an invalid accepted prefix"
        else Ok (retry failure)
      else
        let rec prefix reversed members ids = match members, ids with
          | _, [] -> Ok (List.rev reversed, members)
          | (pending : Types.semantic_pending) :: rest, id :: ids
            when semantic_tx_id pending.operation = id -> prefix (pending :: reversed) rest ids
          | _ -> Error "rejection accepted IDs are not a batch prefix" in
        let* successful, remaining = prefix [] members successes in
        let* cursor = match successful, json_field "t" body with
          | [], _ -> Ok None
          | _ :: _, `Int t when t >= 0 -> Ok (Some t)
          | _ -> Error "partial batch rejection omitted its server cursor" in
        match remaining with
        | [] -> Error "batch rejection omitted its failed member"
        | failed :: unexecuted ->
          let* () = match json_field "failed-tx-id" body with
            | `String id when id = semantic_tx_id failed.operation -> Ok ()
            | `Null when successes = [] -> Ok ()
            | _ -> Error "rejection failed ID is not the next submitted member" in
          let accepted = List.map (fun pending -> pending, Ops.Accepted (Option.get cursor), None) successful in
          let failed_state = if json_field "retryable" body = `Bool true then Ops.Retryable
            else Ops.Conflicted reason in
          Ok (List.rev_append (List.rev accepted)
            ((failed, failed_state, failure) :: List.map (fun pending -> pending, Ops.Retryable, None) unexecuted))

let complete_semantic_response session (active : Types.semantic_active) input =
  try
    let ( let* ) = Result.bind in
    let* succeeded, accepted = parse_semantic_completion input active.id in
    let* settlements = semantic_settlements active input succeeded accepted in
    let* () = List.fold_left (fun result ((pending : Types.semantic_pending), state, _) ->
      let* () = result in
      match (Types.host session).stage_operation with
      | Some stage -> stage { pending.operation with Ops.state = state }
      | None -> Ok ()) (Ok ()) settlements in
    let retryable = List.filter_map (fun (pending, state, _) ->
      if state = Ops.Retryable then Some pending else None) settlements in
    session.Types.state := { !(session.state) with semantic_active = None;
      semantic_queue = List.rev_append (List.rev retryable) (Types.state session).semantic_queue };
    (match succeeded, accepted with
     | true, Some accepted -> Types.record_accepted_server_t session accepted
     | _ ->
       (match Json_util.member "body" input with
        | `String body ->
          let body = try Json.from_string body with Yojson.Json_error _ -> `Null in
          if json_field "type" body = `String "tx/reject" then
            (match json_field "t" body with
             | `Int t when t >= 0 -> Types.record_accepted_server_t session t
             | _ -> ())
        | _ -> ()));
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
             | _ -> body in
           apply scoped_body)
      | _ -> Ok () in
    List.iter (fun ((pending : Types.semantic_pending), _, failure) ->
      Option.iter (fun record -> record ~semantic:true pending.operation.operation_id failure)
        (Types.host session).record_sync_failure) settlements;
    restore_semantic_queue session;
    let continue = succeeded || List.exists (fun (_, state, _) ->
      match state with Ops.Conflicted _ -> true | _ -> false) settlements in
    if continue then
      (match (Types.state session).config with
       | Some config -> activate_semantic_request session config accepted
       | None -> ());
    Ok ()
  with error -> Error ("invalid pending sync completion: " ^ Printexc.to_string error)

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
  let complete ~semantic expected failure_ids label handle =
    let ( let* ) = Result.bind in
    let* _ = validate_completion_id input expected in
    let transient = completion_error input <> None ||
      (match Json_util.member "status" input with
       | `Int status -> status = 408 || status = 429 || (status >= 500 && status <= 599)
       | _ -> false) in
    let attempt = match (Types.state session).pending_retry with
      | Some retry when retry.request_id = expected -> retry.attempt
      | _ -> 0 in
    let result = if transient && attempt < 3 then begin
      session.state := { !(session.state) with
        pending_retry = Some { Types.request_id = expected; attempt = attempt + 1;
          delay_ms = 1000 lsl attempt };
        pending_sync_error = completion_failure input };
      Ok ()
    end else begin
      let* () = handle () in
      session.state := { !(session.state) with pending_retry = None;
        pending_sync_error = completion_failure input };
      Ok ()
    end in
    let failure = match result with Ok () -> completion_failure input | Error message -> Some message in
    session.state := { !(session.state) with pending_sync_error = failure };
    if not semantic || (transient && attempt < 3) || Result.is_error result then
      List.iter (fun failure_id ->
        Option.iter (fun record -> record ~semantic failure_id (Option.map (fun message -> label ^ ": " ^ message) failure))
          (Types.host session).record_sync_failure) failure_ids;
    result in
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
    else
      let operation = active.pending.operation in
      let fields = Ops.intent_json operation.intent in
      let target = List.find_map (fun key -> match Json_util.member key fields with
        | `String uuid -> Some uuid | _ -> None) ["uuid"; "pageUuid"; "blockUuid"] in
      let target = match target with Some _ -> target | None ->
        (match Json_util.member "moves" fields, Json_util.member "uuids" fields with
         | `List (move :: _), _ -> (match Json_util.member "uuid" move with `String uuid -> Some uuid | _ -> None)
         | _, `List (`String uuid :: _) -> Some uuid
         | _ -> None) in
      let label = String.map (function '-' -> ' ' | value -> value) (Ops.outliner_op operation.intent)
        ^ " (" ^ Option.value ~default:operation.operation_id target ^ ")" in
      complete ~semantic:true active.id
        (List.map (fun (pending : Types.semantic_pending) -> pending.operation.operation_id) (semantic_members active)) label (fun () -> complete_semantic_response session active input)
  | None ->
    (match (Types.state session).pending_sync with
     | Some pump ->
       (match !(pump.active) with
        | Some active ->
          if stale active.id then Ok ()
          else
            let block = Types.transport_operation_block active.operation in
            let label = match active.operation with
              | Types.Upload_asset _ -> "Upload asset"
              | Types.Move_created_asset _ -> "Attach asset"
              | Types.Update_title _ -> "Save block"
              | Types.Update_status _ -> "Update task status"
              | Types.Create_journal _ -> "Create journal"
              | Types.Create_block _ -> "Create block" in
            complete ~semantic:false active.id [block.uuid] (label ^ " (" ^ block.uuid ^ ")")
              (fun () -> complete_transport_response session pump active input)
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
           List.rev_append (List.rev (semantic_members active)) (Types.state session).semantic_queue;
         semantic_active = None;
       }
   | None -> ());
  (match (Types.state session).pending_sync with
   | Some pump ->
     (match !(pump.Types.active) with
      | Some active -> cleanup_pending_active session active
      | None -> ())
   | None -> ());
  session.state := { !(session.state) with pending_sync = None; pending_retry = None; pending_sync_error = None }
