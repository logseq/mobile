(** Outliner context/state helpers layered over session state. *)

val sidebar_pages : Session_types.session -> Graph_read.sidebar_pages

val outliner_context_with_blocks :
  Session_types.session ->
  Graph_read.sidebar_pages option ->
  Cache_model.block list ->
  Outliner_state.outliner_context

val base_outliner_context_live :
  Session_types.session -> Outliner_state.outliner_context

val page_overlay :
  Session_types.session ->
  string ->
  Cache_model.block list ->
  Cache_model.block list

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
  Session_types.session ->
  string ->
  Outliner_state.outliner_context option

val node_route_context :
  Session_types.session ->
  Session_types.node_route ->
  Outliner_state.outliner_context

val active_node_route :
  Session_types.session -> Session_types.node_route option

val node_route_related_blocks :
  Session_types.session ->
  Session_types.node_route ->
  Cache_model.block list

val node_route_linked_reference_blocks :
  Session_types.session ->
  Session_types.node_route ->
  Cache_model.block list

val page_for_visible_block :
  Cache_model.block -> Cache_model.entity_summary

val projected_node_destination :
  Session_types.session ->
  string ->
  (Cache_model.entity_summary * bool) option

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

val selected_graph :
  Session_types.session -> Api.api_graph option

val selected_graph_is_encrypted : Session_types.session -> bool
val selected_graph_is_unlocked : Session_types.session -> bool
val selected_page_is_tag : Session_types.session -> bool
val selected_page_is_property : Session_types.session -> bool

val snapshot_related_blocks :
  Session_types.session -> Cache_model.block list

val snapshot_linked_reference_blocks :
  Session_types.session -> Cache_model.block list

val has_pending_operations : Session_types.session -> bool
val reset_outliner : Session_types.session -> unit
val clear_node_navigation : Session_types.session -> unit
val persist_active_node_state : Session_types.session -> unit

val initial_node_state :
  Session_types.session ->
  Session_types.node_route ->
  Outliner_state.outliner_state

val push_node_route :
  Session_types.session -> Session_types.node_route -> unit

val pop_node_route : Session_types.session -> unit

val aggregate_return_context :
  Session_types.session ->
  string ->
  Outliner_state.outliner_message ->
  (Outliner_state.outliner_context * string) option

type outliner_patch_plan =
  | Patch_blocks of string list
  | Structural_diff

val event_patch_plan :
  Outliner_state.outliner_message ->
  Pending_ops.pending_operation list ->
  outliner_patch_plan

val refresh_reference_metadata :
  Session_types.session ->
  string option ->
  Outliner_state.outliner_context ->
  Pending_ops.pending_operation list ->
  Outliner_state.outliner_context

val references_for_node : Session_types.session -> string -> Cache_model.block list
val pending_reference_uuid : Session_types.session -> string option
val load_page_references : Session_types.session -> string -> unit
