module Runtime = Graph_runtime
module Assets = Asset_files
module Read = Graph_read
module Sync = Sync_session
module Checkpoint = Sync_checkpoint
module Store = Graph_store
module Payload = Mobile_payload
module Ds = Datascript

type graph_crypto =
  { require_key : string -> (unit, string) result
  ; encrypt_title : string -> string -> (string, string) result
  ; decrypt_title : string -> string -> (string, string) result
  }

type mobile_graph_runtime =
  { conn : Ds.conn
  ; state : Sync.sync_session_state
  ; checkpoint_path : string
  ; graph_id : string
  ; e2ee : bool
  ; read_runtime : Runtime.graph_runtime
  }

type file_stamp = int * int * int * float * float

type resident_graph =
  { runtime : mobile_graph_runtime
  ; prepared : bool
  ; database_stamp : file_stamp
  ; checkpoint_stamp : file_stamp
  }

type mobile_graph =
  { crypto : graph_crypto
  ; creator : Created_by.identity option ref
  ; current : mobile_graph_runtime option ref
  ; resident_ids : string list ref
  ; residents : (string, resident_graph) Hashtbl.t
  }

let create crypto = { crypto; creator = ref None; current = ref None;
  resident_ids = ref []; residents = Hashtbl.create 3 }

let retain_graphs host ids =
  host.resident_ids := ids;
  Hashtbl.filter_map_inplace (fun id resident ->
    if List.mem id ids then Some resident else None) host.residents

let evict_graph host id = Hashtbl.remove host.residents id

let configure_identity host token =
  let identity = Created_by.of_token token in
  let owner = Option.map (fun (identity : Created_by.identity) -> identity.uuid) in
  if owner identity <> owner !(host.creator) then retain_graphs host [];
  host.creator := identity

let file_stamp path =
  try
    let stat = Unix.stat path in
    Some (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime, stat.st_ctime)
  with Unix.Unix_error _ -> None

let remember ?(prepared = false) host (runtime : mobile_graph_runtime) =
  if List.mem runtime.graph_id !(host.resident_ids) then
    match file_stamp runtime.read_runtime.path, file_stamp runtime.checkpoint_path with
    | Some database_stamp, Some checkpoint_stamp ->
      Hashtbl.replace host.residents runtime.graph_id {runtime; prepared; database_stamp; checkpoint_stamp}
    | _ -> evict_graph host runtime.graph_id

let resident host graph_id path checkpoint e2ee =
  match Hashtbl.find_opt host.residents graph_id with
  | Some cached when cached.runtime.read_runtime.path = path
      && cached.runtime.checkpoint_path = checkpoint && cached.runtime.e2ee = e2ee
      && file_stamp path = Some cached.database_stamp
      && file_stamp checkpoint = Some cached.checkpoint_stamp -> Some cached
  | _ -> evict_graph host graph_id; None

let resolve_asset_path (host : mobile_graph) source_path =
  match !(host.current) with
  | Some opened -> Assets.resolve_legacy_path (Some opened.checkpoint_path) opened.graph_id source_path
  | None -> source_path

let import_asset_file (host : mobile_graph) uuid source_path =
  match !(host.current) with
  | Some opened -> Assets.import_file (Some opened.checkpoint_path) opened.graph_id uuid source_path
  | None -> Error "Open a graph before importing an asset"

let sync_cursor (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Some (Sync.applied_server_t opened.state)
  | None -> None

let projected_db (host : mobile_graph) =
  Option.map (fun opened -> Runtime.db opened.read_runtime) !(host.current)

let blocks (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Some (Runtime.blocks opened.read_runtime)
  | None -> None

let empty_journals (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Runtime.empty_journals opened.read_runtime
  | None -> []

let authoritative_blocks (host : mobile_graph) uuids =
  match !(host.current) with
  | Some opened ->
    let db = Ds.conn_db opened.conn in
    Some (List.filter_map (fun uuid ->
      Option.bind (Ds.entid db "block/uuid" (Ds.Uuid uuid)) (fun eid ->
        if Read.page_is_hidden db eid then None
        else Read.block ~with_breadcrumbs:false (fun value -> Ok value) db eid)) uuids)
  | None -> None

let sidebar_pages (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Some (Runtime.sidebar_pages opened.read_runtime)
  | None -> None

let tag_pages (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Some (Runtime.tag_pages opened.read_runtime)
  | None -> None

let node_is_tag (host : mobile_graph) uuid =
  match !(host.current) with
  | Some opened -> Runtime.node_is_tag opened.read_runtime uuid
  | None -> false

let node_is_property (host : mobile_graph) uuid =
  match !(host.current) with
  | Some opened -> Runtime.node_is_property opened.read_runtime uuid
  | None -> false

let blocks_for_page (host : mobile_graph) uuid =
  match !(host.current) with
  | Some opened -> Some (Runtime.blocks_for_page opened.read_runtime uuid)
  | None -> None

let node_icon (host : mobile_graph) uuid =
  Option.bind !(host.current) (fun opened -> Graph_read.node_icon (Runtime.db opened.read_runtime) uuid)

let node_destination (host : mobile_graph) uuid =
  match !(host.current) with
  | Some opened -> Runtime.node_destination opened.read_runtime uuid
  | None -> None

let objects_for_tag (host : mobile_graph) uuid =
  match !(host.current) with
  | Some opened -> Some (Runtime.objects_for_tag opened.read_runtime uuid)
  | None -> None

let references_for_node (host : mobile_graph) uuid =
  match !(host.current) with
  | Some opened -> Some (Runtime.references_for_node opened.read_runtime uuid)
  | None -> None

let normalize_titles (host : mobile_graph) uuid titles =
  match !(host.current) with
  | Some opened -> Runtime.normalize_titles opened.read_runtime uuid titles
  | None -> (titles, [])

let search (host : mobile_graph) query =
  match !(host.current) with
  | Some opened -> Runtime.search opened.read_runtime query
  | None -> []

let pending_search_index (host : mobile_graph) =
  match !(host.current) with
  | Some opened when Runtime.search_index_pending opened.read_runtime -> Some opened.graph_id
  | _ -> None

let maintain_search_index (host : mobile_graph) graph_id =
  match !(host.current) with
  | Some opened when opened.graph_id = graph_id ->
    Runtime.refresh_search opened.read_runtime;
    (Runtime.state opened.read_runtime).search_index_is_fresh
  | _ -> false

let due_flashcards (host : mobile_graph) now =
  match !(host.current) with
  | Some opened -> Runtime.due_flashcards opened.read_runtime now
  | None -> []

let review_flashcard (host : mobile_graph) uuid rating now operation_id =
  match !(host.current) with
  | Some opened ->
    Runtime.review_flashcard opened.read_runtime uuid rating now
      operation_id
  | None -> Error "graph runtime is not open"

let set_page_favorite (host : mobile_graph) uuid favorite operation_id now =
  match !(host.current) with
  | Some opened ->
    Runtime.set_page_favorite opened.read_runtime uuid favorite
      operation_id now
  | None -> Error "graph runtime is not open"

let delete_page (host : mobile_graph) uuid operation_id now =
  match !(host.current) with
  | Some opened ->
    Runtime.delete_page opened.read_runtime uuid operation_id now
  | None -> Error "graph runtime is not open"

let load_older_journals (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Runtime.load_older_journals opened.read_runtime
  | None -> ()

let has_older_journals (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Runtime.has_older_journals opened.read_runtime
  | None -> false

let journal_page_uuid (host : mobile_graph) day =
  match !(host.current) with
  | Some opened -> Runtime.journal_page_uuid opened.read_runtime day
  | None -> None

let stage (host : mobile_graph) operation =
  match !(host.current) with
  | Some opened -> Runtime.stage opened.read_runtime operation
  | None -> Error "graph runtime is not open"

let prepare_sync (host : mobile_graph) operation =
  match !(host.current) with
  | Some opened -> Runtime.prepare_sync opened.read_runtime operation
  | None -> Error "graph runtime is not open"

let pending_operations (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Runtime.pending_operations opened.read_runtime
  | None -> []

let prepare_sync_batch (host : mobile_graph) operations =
  match !(host.current) with
  | Some opened -> Runtime.prepare_sync_batch opened.read_runtime operations
  | None -> [Error "graph runtime is not open"]

let record_sync_failure (host : mobile_graph) ~semantic operation_id message =
  match !(host.current) with
  | Some opened ->
    let path = opened.read_runtime.path in
    let message = if semantic && Graph_sqlite.pending_tx path operation_id = None then None else message in
    Graph_sqlite.record_sync_failure path operation_id message
  | None -> ()

let sync_error (host : mobile_graph) =
  match !(host.current) with
  | None -> None
  | Some opened ->
    let path = opened.read_runtime.path in
    let pending = Pending_ops.list path in
    let pending_assets = Hashtbl.create (List.length pending) in
    List.iter (fun (operation : Pending_ops.pending_operation) -> match operation.intent with
      | Pending_ops.Create_asset asset -> Hashtbl.replace pending_assets asset.uuid ()
      | _ -> ()) pending;
    let recorded = Graph_sqlite.sync_failures path |> List.filter (fun (id, _) ->
      let pending_asset = Hashtbl.mem pending_assets id in
      let confirmed_asset = match Ds.entid (Ds.conn_db opened.conn) "block/uuid" (Ds.Uuid id) with
        | Some eid -> Read.value (Ds.conn_db opened.conn) eid "logseq.property.asset/type" <> None
        | None -> false in
      if confirmed_asset && not pending_asset then begin
        Graph_sqlite.record_sync_failure path id None;
        false
      end else true) in
    let recorded_ids = Hashtbl.create (List.length recorded) in
    List.iter (fun (id, _) -> Hashtbl.replace recorded_ids id ()) recorded;
    let conflicts = List.filter_map (fun (operation : Pending_ops.pending_operation) ->
      match operation.state with
      | Pending_ops.Conflicted reason when not (Hashtbl.mem recorded_ids operation.operation_id) ->
        Some (Pending_ops.outliner_op operation.intent ^ " (" ^ operation.operation_id ^ "): " ^ reason)
      | _ -> None) (Pending_ops.list path) in
    match List.map snd recorded @ conflicts with
    | [] -> None
    | messages -> Some (String.concat "\n\n" messages)

let report_open started stage =
  Metric_log.line
    ("LOGSEQ_GRAPH_OPEN_METRIC stage=" ^ stage
     ^ Printf.sprintf " elapsed_ms=%.3f"
         ((Unix.gettimeofday () -. started) *. 1000.0))

let load_runtime ?(preparing = false) (host : mobile_graph) graph_id active_path checkpoint_path e2ee =
  let started = Unix.gettimeofday () in
  let ( let* ) = Result.bind in
  let* saved = Checkpoint.load_checkpoint checkpoint_path in
  report_open started "checkpoint_loaded";
  let* saved =
    match saved with
    | Some saved ->
      if saved.graph_id = graph_id then Ok saved
      else Error "graph checkpoint belongs to another graph"
    | None -> Error "graph checkpoint is missing"
  in
  let* conn = Store.restore_conn active_path in
  report_open started "connection_restored";
  let* () =
    if e2ee then (host.crypto.require_key) graph_id else Ok ()
  in
  report_open started "encryption_ready";
  let state =
    Sync.create_state graph_id saved.schema_version saved.applied_server_t
  in
  let options =
    {
      Runtime.default_options with
      search_index_path =
        Some
          (Filename.concat
             (Filename.dirname active_path)
             "search/db.sqlite");
      auto_create_today = true;
      current_creator = (fun () -> !(host.creator));
    }
  in
  let options =
    if e2ee then
      {
        options with
        Runtime.encrypt_title = host.crypto.encrypt_title graph_id;
      }
    else options
  in
  let read_runtime =
    let create = if preparing then Runtime.restore_runtime else Runtime.create in
    create active_path saved.applied_server_t conn options
  in
  report_open started "runtime_created";
  report_open started "complete";
  Ok {conn; state; checkpoint_path; graph_id; e2ee; read_runtime}

let open_paths host graph_id active_path checkpoint_path e2ee =
  let ( let* ) = Result.bind in
  let* opened = match resident host graph_id active_path checkpoint_path e2ee with
    | Some cached ->
      let* () = if e2ee then host.crypto.require_key graph_id else Ok () in
      if cached.prepared then Runtime.activate_prepared cached.runtime.read_runtime;
      Metric_log.line "LOGSEQ_GRAPH_OPEN_METRIC stage=resident_reused";
      Ok cached.runtime
    | None -> load_runtime host graph_id active_path checkpoint_path e2ee in
  Option.iter (fun old -> if old.graph_id <> graph_id then remember host old) !(host.current);
  evict_graph host graph_id;
  host.current := Some opened;
  Ok ()

let prepare_graph host body =
  try
    let ( let* ) = Result.bind in
    let* request = Payload.decode_open body in
    let id = request.graph_id in
    if not (List.mem id !(host.resident_ids))
       || Option.exists (fun opened -> opened.graph_id = id) !(host.current)
       || Option.is_some (resident host id request.active_path request.checkpoint_path request.e2ee)
    then Ok ()
    else
      let* opened = load_runtime ~preparing:true host id request.active_path request.checkpoint_path request.e2ee in
      remember ~prepared:true host opened;
      Ok ()
  with error -> Error (Printexc.to_string error)

let open_graph (host : mobile_graph) body =
  try
    let ( let* ) = Result.bind in
    let* request = Payload.decode_open body in
    open_paths host request.graph_id request.active_path
      request.checkpoint_path request.e2ee
  with error -> Error (Printexc.to_string error)

let import_snapshot (host : mobile_graph) body =
  try
    let ( let* ) = Result.bind in
    let* request = Payload.decode_import body in
    evict_graph host request.graph_id;
    let* metadata = Sync.decode_snapshot_metadata request.metadata_body in
    let* _ =
      Sync.import_snapshot_file
        (if request.e2ee then Some (host.crypto.decrypt_title request.graph_id)
         else None)
        request.graph_id request.active_path request.checkpoint_path
        metadata request.download_path
    in
    open_paths host request.graph_id request.active_path
      request.checkpoint_path request.e2ee
  with error -> Error (Printexc.to_string error)

let apply_sync_event (host : mobile_graph) body =
  let ( let* ) = Result.bind in
  let* journal = Journal_sync.decode body in
  match !(host.current) with
  | None -> Error "graph runtime is not open"
  | Some opened when Option.fold ~none:false ~some:(fun id -> id <> opened.graph_id) journal.graph_id ->
    Error "journal belongs to another graph"
  | Some opened ->
    let local_t = Sync.applied_server_t opened.state in
    let* applied = Journal_sync.apply
        (if opened.e2ee then host.crypto.decrypt_title opened.graph_id else fun value -> Ok value)
        opened.conn local_t journal in
    if journal.t <= local_t then Ok ()
    else
      let* () = Checkpoint.save_checkpoint_atomic opened.checkpoint_path
          (Checkpoint.create opened.graph_id opened.state.schema_version journal.t) in
      opened.state.applied_server_t := journal.t;
      Runtime.rebase ~changed_attributes:applied.changed_attributes
        opened.read_runtime journal.t applied.operation_ids applied.changed_uuids;
      Ok ()

let search_page host ~offset ~limit query =
  match !(host.current) with
  | Some opened -> Runtime.search_page opened.read_runtime ~offset ~limit query
  | None -> [], false
