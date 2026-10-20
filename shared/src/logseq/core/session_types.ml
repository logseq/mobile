module Api_ = Api
module Model = Cache_model
module Graph = Graph_read
module Ops = Pending_ops
module Outliner = Outliner_state
module Search = Search_index
module Cards = Flashcards
module Effects = Outliner_effects

type pending_transport =
  | Json_request of Api.api_request
  | File_upload of Api.api_file_upload

type moved_asset =
  { block : Model.block
  ; remote_uuid : string
  }

type created_journal =
  { block : Model.block
  ; encrypted_title : string
  ; page_id : string
  ; journal_day : int
  }

type transport_operation =
  | Create_block of Model.block
  | Upload_asset of Model.block
  | Move_created_asset of moved_asset
  | Update_title of Model.block
  | Update_status of Model.block
  | Create_journal of created_journal

type pending_active =
  { id : int
  ; transport : pending_transport
  ; operation : transport_operation
  ; cleanup_path : string option
  }

type pending_sync =
  { config : Api.api_config
  ; remaining : Model.block list ref
  ; authoritative : (string, unit) Hashtbl.t
  ; resolved_journal_pages : (int, string) Hashtbl.t
  ; active : pending_active option ref
  }

type semantic_pending =
  { operation : Ops.pending_operation
  }

type semantic_active =
  { id : int
  ; pending : semantic_pending
  ; request : Api.api_request
  }

type node_route =
  { uuid : string
  ; is_tag : bool
  ; is_property : bool
  ; page : Model.entity_summary
  ; scroll_target : string option
  ; zoom_to_block : bool
  ; related_blocks : Model.block list
  ; state : Outliner.outliner_state
  }

type host_options =
  { storage : Datascript.storage option
  ; outliner_projection_limit : int option
  ; open_graph : (string -> (unit, string) result) option
  ; import_snapshot : (string -> (unit, string) result) option
  ; model_for_graph : (string -> Model.model) option
  ; apply_sync_event : (string -> (unit, string) result) option
  ; sync_cursor : (unit -> int option) option
  ; graph_blocks : (unit -> Model.block list option) option
  ; authoritative_graph_blocks : (unit -> Model.block list option) option
  ; graph_sidebar_pages : (unit -> Graph.sidebar_pages option) option
  ; graph_tag_pages : (unit -> Model.entity_summary list option) option
  ; graph_node_is_tag : (string -> bool) option
  ; graph_node_is_property : (string -> bool) option
  ; graph_page_blocks : (string -> Model.block list option) option
  ; graph_node_destination :
      (string -> (Model.entity_summary * bool) option) option
  ; graph_node_references : (string -> Model.block list option) option
  ; graph_tag_objects : (string -> Model.block list option) option
  ; graph_normalize_titles :
      (string -> string list -> string list * (string * string) list) option
  ; graph_search : (string -> Search.indexed_search_hit list) option
  ; graph_due_flashcards : (int -> Cards.due_card list) option
  ; graph_review_flashcard :
      (string -> Cards.flashcard_rating -> int -> string -> (unit, string) result)
      option
  ; graph_set_page_favorite :
      (string -> bool -> string -> int -> (unit, string) result) option
  ; graph_delete_page : (string -> string -> int -> (unit, string) result) option
  ; load_older_journals : (unit -> unit) option
  ; has_older_journals : (unit -> bool) option
  ; load_cached_graph_key : (Api.api_config -> (unit, string) result) option
  ; unlock_graph :
      (Api.api_config -> string -> (unit, string) result) option
  ; ensure_user_keys : (Api.api_config -> string option -> (unit, string) result) option
  ; provision_graph_key : (Api.api_config -> (unit, string) result) option
  ; graph_unlocked : (string -> bool) option
  ; encrypt_title : (string -> string -> (string, string) result) option
  ; resolve_asset_path : string -> string
  ; decrypt_asset : (string -> string -> (string, string) result) option
  ; encrypt_asset_file :
      (string -> string -> (string * int, string) result) option
  ; journal_page_id : (int -> string option) option
  ; send : Api.api_request -> (Api.api_response, string) result
  ; upload_file : Api.api_file_upload -> (Api.api_response, string) result
  ; cleanup_file : string -> unit
  ; stage_operation : (Ops.pending_operation -> (unit, string) result) option
  ; prepare_operation :
      (Ops.pending_operation -> (string * string, string) result) option
  ; pending_operations : (unit -> Ops.pending_operation list) option
  ; load_graph_catalog : (unit -> string option) option
  ; save_graph_catalog : (string -> unit) option
  }

type session_state =
  { model : Model.model
  ; config : Api.api_config option
  ; available_graphs : Api.api_graph list
  ; related_blocks : Model.block list
  ; selected_sidebar_page : Model.entity_summary option
  ; node_routes : node_route list
  ; node_base_state : Outliner.outliner_state option
  ; accepted_server_t : int option
  ; flashcards : Cards.due_card list
  ; search_results : Search.indexed_search_hit list
  ; search_query : string
  ; sync_connected : bool
  ; pending_sync : pending_sync option
  ; next_pending_request_id : int
  ; semantic_queue : semantic_pending list
  ; semantic_active : semantic_active option
  ; outliner_state : Outliner.outliner_state
  ; outliner_optimistic_blocks : Model.block list option
  ; outliner_commands : Effects.outliner_platform_command list
  ; outliner_revision : int
  ; sidebar_deferred : bool
  }

type session =
  { host : host_options
  ; state : session_state ref
  ; reference_cache : (string, Model.block list) Hashtbl.t
  ; reference_generation : (string option * int option * int) option ref
  }

let default_options =
  {
    storage = None;
    outliner_projection_limit = None;
    open_graph = None;
    import_snapshot = None;
    model_for_graph = None;
    apply_sync_event = None;
    sync_cursor = None;
    graph_blocks = None;
    authoritative_graph_blocks = None;
    graph_sidebar_pages = None;
    graph_tag_pages = None;
    graph_node_is_tag = None;
    graph_node_is_property = None;
    graph_page_blocks = None;
    graph_node_destination = None;
    graph_node_references = None;
    graph_tag_objects = None;
    graph_normalize_titles = None;
    graph_search = None;
    graph_due_flashcards = None;
    graph_review_flashcard = None;
    graph_set_page_favorite = None;
    graph_delete_page = None;
    load_older_journals = None;
    has_older_journals = None;
    load_cached_graph_key = None;
    unlock_graph = None;
    ensure_user_keys = None;
    provision_graph_key = None;
    graph_unlocked = None;
    encrypt_title = None;
    resolve_asset_path = (fun path -> path);
    decrypt_asset = None;
    encrypt_asset_file = None;
    journal_page_id = None;
    send = Http.send;
    upload_file = Http.upload_file;
    cleanup_file =
      (fun path -> try Sys.remove path with _ -> ());
    stage_operation = None;
    prepare_operation = None;
    pending_operations = None;
    load_graph_catalog = None;
    save_graph_catalog = None;
  }

let state session = !(session.state)
let host session = session.host
let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)
let debug message = prerr_endline ("Logseq core " ^ message)

let fresh_squuid () =
  match Datascript.squuid () with
  | Datascript.Uuid uuid -> uuid
  | _ -> failwith "Datascript.squuid returned a non-UUID value"

let projection_server_t session =
  match session.host.sync_cursor with
  | Some cursor -> cursor ()
  | None -> None

let submission_server_t session =
  match (projection_server_t session, (state session).accepted_server_t) with
  | Some applied, Some accepted -> Some (max applied accepted)
  | Some applied, None -> Some applied
  | None, accepted -> accepted

let record_accepted_server_t session accepted =
  let current = state session in
  session.state :=
    {
      current with
      accepted_server_t =
        Some
          (match current.accepted_server_t with
           | Some previous -> max previous accepted
           | None -> accepted);
    }

let create_session options =
  let options =
    {
      options with
      authoritative_graph_blocks =
        (match options.authoritative_graph_blocks with
         | Some _ -> options.authoritative_graph_blocks
         | None -> options.graph_blocks);
    }
  in
  let catalog =
    match options.load_graph_catalog with
    | Some load -> load ()
    | None -> None
  in
  let graphs =
    match catalog with
    | Some body ->
      (try Api.graphs_from_graphs_body body with _ -> [])
    | None -> []
  in
  {
    host = options;
    reference_cache = Hashtbl.create 8;
    reference_generation = ref None;
    state =
      ref
        {
          model = Model.create options.storage;
          config = None;
          available_graphs = graphs;
          related_blocks = [];
          selected_sidebar_page = None;
          node_routes = [];
          node_base_state = None;
          accepted_server_t = None;
          flashcards = [];
          search_results = [];
          search_query = "";
          sync_connected = false;
          pending_sync = None;
          next_pending_request_id = 0;
          semantic_queue = [];
          semantic_active = None;
          outliner_state = Outliner.empty;
          outliner_optimistic_blocks = None;
          outliner_commands = [];
          outliner_revision = 0;
          sidebar_deferred = false;
        };
  }

let empty_sidebar = { Graph.favorites = []; recent_pages = [] }

let transport_operation_block operation =
  match operation with
  | Create_block block | Upload_asset block | Update_title block
  | Update_status block -> block
  | Move_created_asset moved -> moved.block
  | Create_journal journal -> journal.block
