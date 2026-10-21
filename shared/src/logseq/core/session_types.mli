(** Session record types shared by the session/sync/graph layers. *)

type pending_transport =
  | Json_request of Api.api_request
  | File_upload of Api.api_file_upload

type moved_asset =
  { block : Cache_model.block
  ; remote_uuid : string
  }

type created_journal =
  { block : Cache_model.block
  ; encrypted_title : string
  ; page_id : string
  ; journal_day : int
  }

type transport_operation =
  | Create_block of Cache_model.block
  | Upload_asset of Cache_model.block
  | Move_created_asset of moved_asset
  | Update_title of Cache_model.block
  | Update_status of Cache_model.block
  | Create_journal of created_journal

type pending_retry =
  { request_id : int
  ; attempt : int
  ; delay_ms : int
  }

type pending_active =
  { id : int
  ; transport : pending_transport
  ; operation : transport_operation
  ; cleanup_path : string option
  }

type pending_sync =
  { config : Api.api_config
  ; remaining : Cache_model.block list ref
  ; authoritative : (string, unit) Hashtbl.t
  ; resolved_journal_pages : (int, string) Hashtbl.t
  ; active : pending_active option ref
  }

type semantic_pending =
  { operation : Pending_ops.pending_operation
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
  ; page : Cache_model.entity_summary
  ; scroll_target : string option
  ; zoom_to_block : bool
  ; related_blocks : Cache_model.block list
  ; state : Outliner_state.outliner_state
  }

type host_options =
  { configure_identity : (string -> unit) option
  ; storage : Datascript.storage option
  ; outliner_projection_limit : int option
  ; open_graph : (string -> (unit, string) result) option
  ; import_snapshot : (string -> (unit, string) result) option
  ; model_for_graph : (string -> Cache_model.model) option
  ; apply_sync_event : (string -> (unit, string) result) option
  ; sync_cursor : (unit -> int option) option
  ; graph_blocks : (unit -> Cache_model.block list option) option
  ; authoritative_graph_blocks : (unit -> Cache_model.block list option) option
  ; graph_sidebar_pages : (unit -> Graph_read.sidebar_pages option) option
  ; graph_tag_pages : (unit -> Cache_model.entity_summary list option) option
  ; graph_node_is_tag : (string -> bool) option
  ; graph_node_is_property : (string -> bool) option
  ; graph_page_blocks : (string -> Cache_model.block list option) option
  ; graph_node_destination :
      (string -> (Cache_model.entity_summary * bool) option) option
  ; graph_node_references : (string -> Cache_model.block list option) option
  ; graph_tag_objects : (string -> Cache_model.block list option) option
  ; graph_normalize_titles :
      (string -> string list -> string list * (string * string) list) option
  ; graph_search : (string -> Search_index.indexed_search_hit list) option
  ; graph_search_page : (offset:int -> limit:int -> string -> Search_index.indexed_search_hit list * bool) option
  ; graph_due_flashcards : (int -> Flashcards.due_card list) option
  ; graph_review_flashcard :
      (string -> Flashcards.flashcard_rating -> int -> string -> (unit, string) result)
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
  ; import_asset_file : string -> string -> (string, string) result
  ; resolve_asset_path : string -> string
  ; decrypt_asset : (string -> string -> (string, string) result) option
  ; encrypt_asset_file :
      (string -> string -> (string * int, string) result) option
  ; journal_page_id : (int -> string option) option
  ; send : Api.api_request -> (Api.api_response, string) result
  ; upload_file : Api.api_file_upload -> (Api.api_response, string) result
  ; cleanup_file : string -> unit
  ; stage_operation : (Pending_ops.pending_operation -> (unit, string) result) option
  ; prepare_operation :
      (Pending_ops.pending_operation -> (string * string, string) result) option
  ; pending_operations : (unit -> Pending_ops.pending_operation list) option
  ; load_sync_error : (unit -> string option) option
  ; record_sync_failure : (semantic:bool -> string -> string option -> unit) option
  ; load_graph_catalog : (unit -> string option) option
  ; load_collapsed_nodes : (string -> string list) option
  ; save_collapsed_nodes : (string -> string list -> unit) option
  ; save_graph_catalog : (string -> unit) option
  }

type session_state =
  { model : Cache_model.model
  ; config : Api.api_config option
  ; available_graphs : Api.api_graph list
  ; related_blocks : Cache_model.block list
  ; selected_sidebar_page : Cache_model.entity_summary option
  ; node_routes : node_route list
  ; node_base_state : Outliner_state.outliner_state option
  ; bootstrap_generation : int
  ; active_graph_id : string option
  ; accepted_server_t : int option
  ; flashcards : Flashcards.due_card list
  ; search_has_more : bool
  ; search_result_pages : Search_index.indexed_search_hit list list
  ; search_result_count : int
  ; search_query : string
  ; sync_transport : Sync_driver.t
  ; sync_connected : bool
  ; pending_sync : pending_sync option
  ; pending_retry : pending_retry option
  ; pending_sync_error : string option
  ; next_pending_request_id : int
  ; semantic_queue : semantic_pending list
  ; semantic_active : semantic_active option
  ; outliner_state : Outliner_state.outliner_state
  ; outliner_optimistic_blocks : Cache_model.block list option
  ; outliner_commands : Outliner_effects.outliner_platform_command list
  ; outliner_revision : int
  ; sidebar_deferred : bool
  }

type session =
  { host : host_options
  ; state : session_state ref
  ; collapsed_nodes : (string, Outliner_state.Sset.t) Hashtbl.t
  ; reference_cache : (string, Cache_model.block list) Hashtbl.t
  ; reference_generation : (string option * int option * int) option ref
  }

val default_options : host_options
val state : session -> session_state
val host : session -> host_options
val now_ms : unit -> int
val debug : string -> unit
val fresh_squuid : unit -> string
val projection_server_t : session -> int option
val submission_server_t : session -> int option
val record_accepted_server_t : session -> int -> unit
val create_session : host_options -> session
val empty_sidebar : Graph_read.sidebar_pages
val transport_operation_block : transport_operation -> Cache_model.block
