(** Mobile graph host: holds the open graph's DataScript connection, sync
    state, and read runtime; exposes the host-facing loaders the session
    layer binds into `host_options`. *)

type graph_crypto =
  { require_key : string -> (unit, string) result
  ; encrypt_title : string -> string -> (string, string) result
  ; decrypt_title : string -> string -> (string, string) result
  }

type mobile_graph_runtime =
  { conn : Datascript.conn
  ; state : Sync_session.sync_session_state
  ; checkpoint_path : string
  ; graph_id : string
  ; e2ee : bool
  ; read_runtime : Graph_runtime.graph_runtime
  }

type mobile_graph =
  { crypto : graph_crypto
  ; current : mobile_graph_runtime option ref
  }

val create : graph_crypto -> mobile_graph
val resolve_asset_path : mobile_graph -> string -> string
val sync_cursor : mobile_graph -> int option
val blocks : mobile_graph -> Cache_model.block list option
val authoritative_blocks : mobile_graph -> Cache_model.block list option
val sidebar_pages : mobile_graph -> Graph_read.sidebar_pages option
val tag_pages : mobile_graph -> Cache_model.entity_summary list option
val node_is_tag : mobile_graph -> string -> bool
val node_is_property : mobile_graph -> string -> bool
val blocks_for_page : mobile_graph -> string -> Cache_model.block list option
val node_destination :
  mobile_graph ->
  string ->
  (Cache_model.entity_summary * bool) option
val objects_for_tag : mobile_graph -> string -> Cache_model.block list option
val references_for_node : mobile_graph -> string -> Cache_model.block list option
val normalize_titles :
  mobile_graph -> string -> string list -> string list * (string * string) list
val search : mobile_graph -> string -> Search_index.indexed_search_hit list
val due_flashcards : mobile_graph -> int -> Flashcards.due_card list
val review_flashcard :
  mobile_graph ->
  string ->
  Flashcards.flashcard_rating ->
  int ->
  string ->
  (unit, string) result
val set_page_favorite :
  mobile_graph -> string -> bool -> string -> int -> (unit, string) result
val delete_page : mobile_graph -> string -> string -> int -> (unit, string) result
val load_older_journals : mobile_graph -> unit
val has_older_journals : mobile_graph -> bool
val journal_page_uuid : mobile_graph -> int -> string option
val stage :
  mobile_graph -> Pending_ops.pending_operation -> (unit, string) result
val prepare_sync :
  mobile_graph ->
  Pending_ops.pending_operation ->
  (string * string, string) result
val pending_operations : mobile_graph -> Pending_ops.pending_operation list
val report_open : float -> string -> unit
val open_paths :
  mobile_graph ->
  string ->
  string ->
  string ->
  bool ->
  (unit, string) result
val open_graph : mobile_graph -> string -> (unit, string) result
val import_snapshot : mobile_graph -> string -> (unit, string) result
val apply_sync_event : mobile_graph -> string -> (unit, string) result

val search_page : mobile_graph -> offset:int -> limit:int -> string ->
  Search_index.indexed_search_hit list * bool
