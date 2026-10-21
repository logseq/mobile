(** Pending-sync transport pump and semantic-queue scheduler. *)

val pending_request_json : Session_types.session -> Yojson.Basic.t
val pending_block_unchanged :
  Session_types.session -> Cache_model.block -> bool
val mark_pending_failed : Session_types.session -> Cache_model.block -> unit
val set_pending_active :
  Session_types.session ->
  Session_types.pending_sync ->
  Session_types.pending_transport ->
  Session_types.transport_operation ->
  string option ->
  unit
val encrypted_title :
  Session_types.session ->
  Api.api_config ->
  string ->
  (string, string) result
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
  Session_types.session ->
  Pending_ops.pending_operation ->
  (unit, string) result
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
val validate_completion_id :
  Yojson.Basic.t -> int -> (int, string) result
val parse_semantic_completion :
  Yojson.Basic.t -> int -> (bool * int option, string) result
val parse_transport_completion :
  Yojson.Basic.t -> int -> ((Api.api_response, string) result, string) result
val complete_semantic_response :
  Session_types.session ->
  Session_types.semantic_active ->
  Yojson.Basic.t ->
  (unit, string) result
val complete_transport_response :
  Session_types.session ->
  Session_types.pending_sync ->
  Session_types.pending_active ->
  Yojson.Basic.t ->
  (unit, string) result
val complete_pending_sync :
  Session_types.session -> string -> (unit, string) result
val cancel_pending_sync : Session_types.session -> unit
val pending_sync_error : Session_types.session -> string option
