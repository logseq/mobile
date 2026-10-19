(** Encoders for the host-facing RPC wire payloads. *)

val youtube_url : string -> bool
val youtube_target_urls : Cache_model.block list -> (string * string) list
val summary_json : Cache_model.entity_summary -> Yojson.Basic.t
val status_response_json : Cache_model.status -> Yojson.Basic.t
val block_json : Cache_model.block -> Yojson.Basic.t
val visible_block_json : Cache_model.block -> Yojson.Basic.t
val flashcard_json : Flashcards.due_card -> Yojson.Basic.t
val graph_json : Api.api_graph -> Yojson.Basic.t
val search_hit_json : Search_index.indexed_search_hit -> Yojson.Basic.t
val outliner_row_json :
  string option ->
  (Cache_model.block -> Yojson.Basic.t) ->
  Outliner_state.outliner_row ->
  Yojson.Basic.t
val outliner_rows_json :
  (Cache_model.block -> Yojson.Basic.t) ->
  Outliner_state.outliner_context ->
  Outliner_state.outliner_state ->
  Yojson.Basic.t
val common_row_prefix : 'a list -> 'a list -> int
val sub_list : 'a list -> int -> int -> 'a list
val common_row_suffix : 'a list -> 'a list -> int -> int
val row_splice_position :
  bool -> Outliner_state.outliner_row list -> int -> (string * Yojson.Basic.t) list
val structural_outliner_delta :
  bool ->
  Outliner_state.outliner_context ->
  Outliner_state.outliner_state ->
  Outliner_state.outliner_context ->
  Outliner_state.outliner_state ->
  Cache_model.block list * string list * Yojson.Basic.t list
val outliner_candidates_json :
  Outliner_state.outliner_context ->
  Outliner_state.outliner_state ->
  Yojson.Basic.t
val autocomplete_kind_json : Outliner_state.reducer_autocomplete_kind -> string
val outliner_state_json : Outliner_state.outliner_state -> Yojson.Basic.t
val outliner_command_json :
  Outliner_effects.outliner_platform_command -> Yojson.Basic.t
val outliner_patch_result :
  int ->
  Outliner_state.outliner_context ->
  Outliner_state.outliner_state ->
  int ->
  Outliner_effects.outliner_platform_command list ->
  bool ->
  Cache_model.block list ->
  string list ->
  Yojson.Basic.t list ->
  string

val block_shell_json : Cache_model.block -> Yojson.Basic.t
