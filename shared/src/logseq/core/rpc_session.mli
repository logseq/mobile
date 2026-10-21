(** Session-level RPC dispatcher and snapshot encoders. *)

val default_options : Session_types.host_options
val create_session : Session_types.host_options -> Session_types.session
val state : Session_types.session -> Session_types.session_state
val host : Session_types.session -> Session_types.host_options
val now_ms : unit -> int
val debug : string -> unit
val fresh_squuid : unit -> string
val projection_server_t : Session_types.session -> int option
val submission_server_t : Session_types.session -> int option
val record_accepted_server_t : Session_types.session -> int -> unit
val transport_operation_block : Session_types.transport_operation -> Cache_model.block
val empty_sidebar : Graph_read.sidebar_pages

val sidebar_pages : Session_types.session -> Graph_read.sidebar_pages
val outliner_context_with_blocks :
  Session_types.session ->
  Graph_read.sidebar_pages option ->
  Cache_model.block list ->
  Outliner_state.outliner_context
val base_outliner_context_live :
  Session_types.session -> Outliner_state.outliner_context
val page_overlay :
  Session_types.session -> string -> Cache_model.block list -> Cache_model.block list
val scope_selected_page :
  Session_types.session ->
  Outliner_state.outliner_context ->
  Outliner_state.outliner_context
val base_outliner_context_with_blocks :
  Session_types.session ->
  Graph_read.sidebar_pages option ->
  Cache_model.block list ->
  Outliner_state.outliner_context
val base_outliner_context :
  Session_types.session -> Outliner_state.outliner_context
val page_outliner_context :
  Session_types.session -> string -> Outliner_state.outliner_context option
val node_route_context :
  Session_types.session -> Session_types.node_route -> Outliner_state.outliner_context
val active_node_route : Session_types.session -> Session_types.node_route option
val node_route_related_blocks :
  Session_types.session -> Session_types.node_route -> Cache_model.block list
val node_route_linked_reference_blocks :
  Session_types.session -> Session_types.node_route -> Cache_model.block list
val page_for_visible_block : Cache_model.block -> Cache_model.entity_summary
val projected_node_destination :
  Session_types.session -> string -> (Cache_model.entity_summary * bool) option
val with_extra_blocks :
  Outliner_state.outliner_context ->
  Cache_model.block list ->
  Outliner_state.outliner_context
val outliner_context :
  Session_types.session -> Outliner_state.outliner_context
val project_outliner_operations :
  Outliner_state.outliner_context ->
  Pending_ops.pending_operation list ->
  Outliner_state.outliner_context
val selected_graph : Session_types.session -> Api.api_graph option
val selected_graph_is_encrypted : Session_types.session -> bool
val selected_graph_is_unlocked : Session_types.session -> bool
val selected_page_is_tag : Session_types.session -> bool
val selected_page_is_property : Session_types.session -> bool
val snapshot_related_blocks : Session_types.session -> Cache_model.block list
val snapshot_linked_reference_blocks :
  Session_types.session -> Cache_model.block list
val has_pending_operations : Session_types.session -> bool
val reset_outliner : Session_types.session -> unit
val clear_node_navigation : Session_types.session -> unit
val persist_active_node_state : Session_types.session -> unit
val initial_node_state :
  Session_types.session -> Session_types.node_route -> Outliner_state.outliner_state
val push_node_route : Session_types.session -> Session_types.node_route -> unit
val pop_node_route : Session_types.session -> unit
val aggregate_return_context :
  Session_types.session ->
  string ->
  Outliner_state.outliner_message ->
  (Outliner_state.outliner_context * string) option
val refresh_reference_metadata :
  Session_types.session ->
  string option ->
  Outliner_state.outliner_context ->
  Pending_ops.pending_operation list ->
  Outliner_state.outliner_context
val event_patch_plan :
  Outliner_state.outliner_message ->
  Pending_ops.pending_operation list ->
  Session_outliner.outliner_patch_plan

val pending_request_json : Session_types.session -> Yojson.Basic.t
val pending_block_unchanged : Session_types.session -> Cache_model.block -> bool
val mark_pending_failed : Session_types.session -> Cache_model.block -> unit
val set_pending_active :
  Session_types.session ->
  Session_types.pending_sync ->
  Session_types.pending_transport ->
  Session_types.transport_operation ->
  string option ->
  unit
val encrypted_title :
  Session_types.session -> Api.api_config -> string -> (string, string) result
val prepare_pending_create_request :
  Session_types.session ->
  Session_types.pending_sync ->
  Cache_model.block ->
  string ->
  string option ->
  (unit, string) result
val prepare_pending_creation :
  Session_types.session ->
  Session_types.pending_sync ->
  Cache_model.block ->
  (unit, string) result
val prepare_pending_block :
  Session_types.session ->
  Session_types.pending_sync ->
  Cache_model.block ->
  (unit, string) result
val prepare_pending_next :
  Session_types.session -> Session_types.pending_sync -> unit
val activate_semantic_request :
  Session_types.session -> Api.api_config -> int option -> unit
val enqueue_semantic :
  Session_types.session -> Pending_ops.pending_operation -> (unit, string) result
val normalize_operation_titles :
  Session_types.session ->
  Pending_ops.pending_operation ->
  Pending_ops.pending_operation list
val capture_operations :
  Session_types.session ->
  string ->
  string ->
  int ->
  Cache_model.status option ->
  (Pending_ops.pending_operation list, string) result
val enqueue_capture :
  Session_types.session ->
  string ->
  string ->
  int ->
  Cache_model.status option ->
  (unit, string) result
val restore_semantic_queue : Session_types.session -> unit
val begin_pending_sync : Session_types.session -> Api.api_config -> unit
val finish_semantic_active :
  Session_types.session ->
  Session_types.semantic_active ->
  bool ->
  int option ->
  unit
val cleanup_pending_active :
  Session_types.session -> Session_types.pending_active -> unit
val finish_pending_block :
  Session_types.session ->
  Session_types.pending_sync ->
  Cache_model.block ->
  bool ->
  unit
val asset_datoms_operation :
  Session_types.session ->
  Cache_model.block ->
  Pending_ops.pending_state ->
  (Pending_ops.pending_operation, string) result
val reconcile_created_block :
  Session_types.session ->
  Session_types.pending_sync ->
  Cache_model.block ->
  string ->
  unit
val complete_pending_active :
  Session_types.session ->
  Session_types.pending_sync ->
  Session_types.pending_active ->
  Api.api_response ->
  unit
val accepted_transaction : string -> bool * int option
val completion_error : Yojson.Basic.t -> string option
val parse_semantic_completion :
  Yojson.Basic.t -> int -> (bool * int option, string) result
val parse_transport_completion :
  Yojson.Basic.t -> int -> ((Api.api_response, string) result, string) result
val complete_pending_sync :
  Session_types.session -> string -> (unit, string) result
val cancel_pending_sync : Session_types.session -> unit

val node_routes_json :
  Session_types.session ->
  (Cache_model.block -> Yojson.Basic.t) ->
  (Cache_model.block -> Yojson.Basic.t) ->
  Yojson.Basic.t
val snapshot :
  Session_types.session ->
  Cache_model.block list ->
  Cache_model.block list ->
  string
val outliner_patch_result :
  Session_types.session ->
  Outliner_state.outliner_context ->
  Cache_model.block list ->
  string list ->
  Yojson.Basic.t list ->
  string
val outliner_patch :
  Session_types.session ->
  Outliner_state.outliner_context ->
  string list ->
  string
val structural_outliner_patch :
  bool ->
  Session_types.session ->
  Outliner_state.outliner_context ->
  Outliner_state.outliner_state ->
  Outliner_state.outliner_context ->
  string
val snapshot_visible : Session_types.session -> string
val graph_catalog_snapshot : Session_types.session -> string
val pending_sync_patch : Session_types.session -> string
val reconcile_authoritative_blocks : Session_types.session -> unit
val discover_graphs :
  Session_types.session -> Api.api_config -> (unit, string) result
val resolve_graph : Api.api_config -> (Api.api_config, string) result
val dispatch_outliner_event : Session_types.session -> string -> string
val switch_graph_model :
  Session_types.session -> string -> (unit, string) result
val with_object :
  string ->
  string option ->
  string ->
  (Yojson.Basic.t -> (string * Yojson.Basic.t) list -> string) ->
  string
val stage_result :
  Session_types.session ->
  string ->
  int ->
  Pending_ops.pending_intent ->
  string
val editing_cursor :
  Session_types.session -> (int, string * string) result
val checked_edit :
  Session_types.session ->
  string ->
  int option ->
  string ->
  string ->
  (unit -> (Pending_ops.pending_intent, string) result) ->
  string
val configure :
  Session_types.session ->
  Yojson.Basic.t ->
  (string * Yojson.Basic.t) list ->
  string
val select_graph : Session_types.session -> string option -> string
val select_page : Session_types.session -> string option -> string
val open_node :
  Session_types.session -> (string * Yojson.Basic.t) list -> string
val send_message : Session_types.session -> string option -> string
val send_task :
  Session_types.session ->
  Yojson.Basic.t ->
  (string * Yojson.Basic.t) list ->
  string
val update_block_status :
  Session_types.session ->
  Yojson.Basic.t ->
  (string * Yojson.Basic.t) list ->
  string
val update_block :
  Session_types.session ->
  Yojson.Basic.t ->
  (string * Yojson.Basic.t) list ->
  string
val split_block :
  Session_types.session -> (string * Yojson.Basic.t) list -> string
val merge_backward :
  Session_types.session -> (string * Yojson.Basic.t) list -> string
val move_blocks :
  Session_types.session ->
  Yojson.Basic.t ->
  (string * Yojson.Basic.t) list ->
  string
val delete_blocks :
  Session_types.session ->
  Yojson.Basic.t ->
  (string * Yojson.Basic.t) list ->
  string
val delete_block :
  Session_types.session -> (string * Yojson.Basic.t) list -> string
val reload_flashcards : Session_types.session -> int -> unit
val dispatch : Session_types.session -> string -> string option -> string
val call : Session_types.session -> string -> string
