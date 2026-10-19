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

type mobile_graph =
  { crypto : graph_crypto
  ; current : mobile_graph_runtime option ref
  }

let create crypto = { crypto; current = ref None }

let resolve_asset_path (host : mobile_graph) source_path =
  Assets.resolve_path
    (match !(host.current) with
     | Some opened -> Some opened.checkpoint_path
     | None -> None)
    source_path

let sync_cursor (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Some (Sync.applied_server_t opened.state)
  | None -> None

let blocks (host : mobile_graph) =
  match !(host.current) with
  | Some opened -> Some (Runtime.blocks opened.read_runtime)
  | None -> None

let authoritative_blocks (host : mobile_graph) =
  match !(host.current) with
  | Some opened ->
    Some (Read.blocks (fun v -> Ok v) 7 (Ds.conn_db opened.conn))
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

let report_open started stage =
  Metric_log.line
    ("LOGSEQ_GRAPH_OPEN_METRIC stage=" ^ stage
     ^ Printf.sprintf " elapsed_ms=%.3f"
         ((Unix.gettimeofday () -. started) *. 1000.0))

let open_paths (host : mobile_graph) graph_id active_path checkpoint_path
    e2ee =
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
    Runtime.create active_path saved.applied_server_t conn options
  in
  report_open started "runtime_created";
  host.current :=
    Some
      {
        conn;
        state;
        checkpoint_path;
        graph_id;
        e2ee;
        read_runtime;
      };
  report_open started "complete";
  Ok ()

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
    let* ids, changed = Journal_sync.apply
        (if opened.e2ee then host.crypto.decrypt_title opened.graph_id else fun value -> Ok value)
        opened.conn local_t journal in
    if journal.t <= local_t then Ok ()
    else
      let* () = Checkpoint.save_checkpoint_atomic opened.checkpoint_path
          (Checkpoint.create opened.graph_id opened.state.schema_version journal.t) in
      opened.state.applied_server_t := journal.t;
      Runtime.rebase opened.read_runtime journal.t ids changed;
      Ok ()
