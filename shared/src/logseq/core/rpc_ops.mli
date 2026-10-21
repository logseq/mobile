(** RPC operation helpers shared by the session dispatcher. *)

val same_status : Cache_model.status option -> Cache_model.status option -> bool
val same_pending_version : Cache_model.block -> Cache_model.block -> bool
val reconcile_authoritative_blocks :
  Cache_model.model -> Cache_model.block list -> unit

val normalize_title_intent :
  (string -> string list -> string list * (string * string) list) ->
  Pending_ops.pending_intent ->
  Pending_ops.pending_intent * (string * string) list

val normalize_operation_titles :
  (string -> string list -> string list * (string * string) list) option ->
  (unit -> string) ->
  (unit -> int) ->
  Pending_ops.pending_operation ->
  Pending_ops.pending_operation list

val capture_operation :
  int ->
  string ->
  string ->
  int ->
  (unit -> Outliner_state.outliner_context) ->
  (int -> string option) option ->
  (unit -> string) ->
  (Pending_ops.pending_operation, string) result

val capture_operations :
  int option ->
  string ->
  string ->
  int ->
  Cache_model.status option ->
  (unit -> Outliner_state.outliner_context) ->
  (int -> string option) option ->
  (unit -> string) ->
  (Pending_ops.pending_operation -> Pending_ops.pending_operation list) ->
  (Pending_ops.pending_operation list, string) result

val asset_destination :
  Outliner_state.outliner_context ->
  Cache_model.block ->
  (int -> string option) option ->
  (string * string) option

val asset_datoms_operation :
  int option ->
  Pending_ops.pending_state ->
  Cache_model.block ->
  (unit -> Outliner_state.outliner_context) ->
  (int -> string option) option ->
  (Pending_ops.pending_operation, string) result

val projected_status :
  Pending_ops.semantic_value option -> Cache_model.status option

val project_outliner_intent :
  Cache_model.block list ->
  Pending_ops.pending_intent ->
  Cache_model.block list

val merge_live_block_metadata :
  Cache_model.block -> Cache_model.block -> Cache_model.block

val page_blocks_with_optimistic_overlay :
  Cache_model.block list option ->
  bool ->
  string ->
  Cache_model.block list ->
  Cache_model.block list

val upload_initial_graph_snapshot :
  Api.api_config ->
  bool ->
  (string -> string -> (string, string) result) option ->
  (Api.api_file_upload -> (Api.api_response, string) result) ->
  (string -> unit) ->
  (unit, string) result

val import_snapshot :
  string option ->
  (string -> (unit, string) result) option ->
  (string -> (unit, string) result) ->
  (unit -> string) ->
  string

val open_graph :
  string option ->
  (string -> (unit, string) result) option ->
  (string -> (unit, string) result) ->
  (unit -> string) ->
  string

val apply_sync_event :
  string option ->
  (string -> (unit, string) result) option ->
  (unit -> string) ->
  string

val asset_metadata :
  (string * Yojson.Basic.t) list ->
  (string * string * int option * string * int * string * string * string option,
   string * string)
    result

val add_asset :
  ?prepare_file:(string -> string -> (string, string) result) ->
  string option ->
  Cache_model.model ->
  (unit -> int) ->
  (string -> Cache_model.block option) ->
  (unit -> unit -> string) ->
  (Cache_model.block -> (Pending_ops.pending_operation, string) result) ->
  (unit -> (Pending_ops.pending_operation -> (unit, string) result) option) ->
  string

val child_operation :
  int ->
  Outliner_state.outliner_context ->
  string ->
  string ->
  string ->
  int ->
  (unit -> string) ->
  (Pending_ops.pending_operation, string) result

val add_child_block :
  string option ->
  Cache_model.model ->
  (unit -> int) ->
  (unit -> Api.api_config option * int option) ->
  (unit -> Outliner_state.outliner_context) ->
  (Api.api_config -> Pending_ops.pending_operation -> (unit, string) result) ->
  (unit -> string) ->
  (unit -> string) ->
  string

val review_flashcard :
  string option ->
  (string -> Flashcards.flashcard_rating -> int -> string -> (unit, string) result) option ->
  (unit -> int) ->
  (int -> string) ->
  string

val set_page_favorite :
  string option ->
  (string -> bool -> string -> int -> (unit, string) result) option ->
  bool ->
  (unit -> int) ->
  (unit -> string) ->
  string

val delete_page :
  string option ->
  (string -> string -> int -> (unit, string) result) option ->
  bool ->
  (unit -> int) ->
  (unit -> string) ->
  string

val create_sync_graph :
  Api.api_config option ->
  string option ->
  (Api.api_request -> (Api.api_response, string) result) ->
  (Api.api_config -> string option -> (unit, string) result) option ->
  (Api.api_config -> (unit, string) result) option ->
  (Api.api_config -> bool -> (unit, string) result) ->
  (Api.api_config -> (unit, string) result) ->
  (Api.api_config -> string) ->
  string
