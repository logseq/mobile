(** Compile pending intents into DataScript transactions and check whether
    intents are already satisfied by the authoritative db. *)

type pending_projection_snapshot =
  { db : Datascript.db
  ; server_t : int
  ; statuses : (string * Pending_ops.pending_state) list
  }

val lookup : string -> Datascript.entity_ref
val one_value :
  Datascript.db -> Datascript.entity_ref -> string -> Datascript.value option
val string_value : Datascript.value option -> string option
val bool_value : Datascript.value option -> bool option
val has_ref : Datascript.db -> int -> string -> int -> bool
val named_page_eid : Datascript.db -> string -> int option
val favorite_page_eid : Datascript.db -> int option
val recycle_page_eid : Datascript.db -> int option
val favorite_block_eid : Datascript.db -> string -> int option
val datascript_value : Pending_ops.semantic_value -> Datascript.value
val semantic_value_equal_value :
  Datascript.db -> Datascript.value -> Pending_ops.semantic_value -> bool
val semantic_value_equal :
  Datascript.db ->
  Datascript.value option ->
  Pending_ops.semantic_value option ->
  bool
val page_names : string -> string list
val inline_tag_names : string -> string list
val eid_for_node : Datascript.db -> string -> int option
val refs_for_title : Datascript.db -> string -> int list
val tag_eids_for_title : Datascript.db -> string -> int list
val title_tx : Datascript.db -> string -> string -> Datascript.tx_op list
val uuid_for_eid : Datascript.db -> int -> string option
val journal_page_eid : Datascript.db -> int -> int option
val outliner_block : Datascript.db -> string -> Outliner.outliner_block option
val entity_tx :
  Datascript.entity_ref -> (string * Datascript.tx_value) list -> Datascript.tx_op
val insert_tx :
  Datascript.db -> Outliner.outliner_block -> int -> Datascript.tx_op list
val outliner_mutation_tx :
  Datascript.db -> Outliner.mutation -> Datascript.tx_op list
val compile_outliner :
  Datascript.db -> Outliner.command -> (Datascript.tx_op list, string) result
val children : Datascript.db -> int -> int list
val subtree : Datascript.db -> int list -> int list
val page_entity : Datascript.db -> int -> bool
val would_create_cycle : Datascript.db -> int -> int -> bool
val property_tx :
  string -> string -> Pending_ops.semantic_value option -> Datascript.tx_op
val compile :
  Datascript.db ->
  Pending_ops.pending_intent ->
  (Datascript.tx_op list, string) result
val block_location_matches :
  Datascript.db -> string -> string -> string -> string -> bool
val satisfied : Datascript.db -> Pending_ops.pending_intent -> bool
val build :
  int ->
  Datascript.db ->
  Pending_ops.pending_operation list ->
  pending_projection_snapshot
