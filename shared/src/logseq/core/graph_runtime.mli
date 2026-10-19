(** Pending-operation projection, search-index maintenance, and cached
    reads over a graph's DataScript connection. *)

type runtime_options =
  { encrypt_title : string -> (string, string) result
  ; search_index_path : string option
  ; auto_create_today : bool
  }

type read_caches =
  { blocks : (int * int option * int, Cache_model.block list) Hashtbl.t
  ; page_blocks : (string, Cache_model.block list) Hashtbl.t
  ; page_readers : (string, Graph_read.page_reader) Hashtbl.t
  ; node_blocks : (string, Cache_model.block list) Hashtbl.t
  ; node_destinations :
      (string, (Cache_model.entity_summary * bool) option) Hashtbl.t
  ; node_kind : (string, bool * bool) Hashtbl.t
  ; journal_page_uuids : (int, string option) Hashtbl.t
  ; tag_pages : Cache_model.entity_summary list option ref
  ; journal_page_count : int option ref
  }

type runtime_state =
  { server_t : int
  ; snapshot : Pending_projection.pending_projection_snapshot
  ; sidebar_cache : (Datascript.db * Graph_read.sidebar_pages) option
  ; read_cache : (Datascript.db * read_caches) option
  ; journal_limit : int
  ; journal_block_limit : int option
  ; search_index_is_fresh : bool
  }

type graph_runtime =
  { path : string
  ; conn : Datascript.conn
  ; encrypt_title : string -> (string, string) result
  ; search_index : Search_index.search_index option
  ; state : runtime_state ref
  }

val default_options : runtime_options
val state : graph_runtime -> runtime_state
val db : graph_runtime -> Datascript.db
val new_read_caches : unit -> read_caches
val caches_for_db : graph_runtime -> Datascript.db -> read_caches
val operation_statuses :
  graph_runtime -> (string * Pending_ops.pending_state) list
val trace_stage : string -> float -> string -> unit
val search_error : string -> exn -> unit
val refresh_search : graph_runtime -> unit
val refresh_search_affected :
  graph_runtime -> Datascript.db -> Pending_ops.pending_intent -> unit
val refresh_search_after_rebase :
  graph_runtime ->
  Datascript.db ->
  Pending_ops.pending_operation list ->
  string list ->
  unit
val confirmed_operation :
  string list ->
  int ->
  Datascript.db ->
  Pending_ops.pending_operation ->
  bool
val rebase_operation :
  graph_runtime ->
  int ->
  Datascript.db ref ->
  Pending_ops.pending_operation ->
  Pending_ops.pending_state
val rebase :
  graph_runtime -> int -> string list -> string list -> unit
val create_base :
  string -> int -> Datascript.conn -> runtime_options -> graph_runtime
val fresh_uuid : unit -> string
val pending_operations : graph_runtime -> Pending_ops.pending_operation list
val db_before_operation : graph_runtime -> string -> Datascript.db
val prepare_sync :
  graph_runtime ->
  Pending_ops.pending_operation ->
  (string * string, string) result
val transport_state : Pending_ops.pending_state -> bool
val stage :
  graph_runtime -> Pending_ops.pending_operation -> (unit, string) result
val queued_operation :
  graph_runtime -> string -> Pending_ops.pending_intent -> Pending_ops.pending_operation
val ensure_today_journal : graph_runtime -> (unit, string) result
val create :
  string -> int -> Datascript.conn -> runtime_options -> graph_runtime
val blocks : graph_runtime -> Cache_model.block list
val due_flashcards : graph_runtime -> int -> Flashcards.due_card list
val semantic_option :
  Datascript.value option -> (Pending_ops.semantic_value option, string) result
val review_flashcard :
  graph_runtime ->
  string ->
  Flashcards.flashcard_rating ->
  int ->
  string ->
  (unit, string) result
val has_older_journals : graph_runtime -> bool
val load_older_journals : graph_runtime -> unit
val blocks_for_page : graph_runtime -> string -> Cache_model.block list
val page_window :
  ?collapsed:string list -> ?offset:int -> ?limit:int ->
  graph_runtime -> string -> Graph_read.page_window

val sidebar_pages : graph_runtime -> Graph_read.sidebar_pages
val set_page_favorite :
  graph_runtime -> string -> bool -> string -> int -> (unit, string) result
val delete_page :
  graph_runtime -> string -> string -> int -> (unit, string) result
val node_destination :
  graph_runtime ->
  string ->
  (Cache_model.entity_summary * bool) option
val node_blocks_for : graph_runtime -> string -> string -> Cache_model.block list
val objects_for_tag : graph_runtime -> string -> Cache_model.block list
val references_for_node : graph_runtime -> string -> Cache_model.block list
val tag_pages : graph_runtime -> Cache_model.entity_summary list
val node_kind : graph_runtime -> string -> bool * bool
val node_is_tag : graph_runtime -> string -> bool
val node_is_property : graph_runtime -> string -> bool
val journal_page_uuid : graph_runtime -> int -> string option
val normalize_titles :
  graph_runtime -> string -> string list -> string list * (string * string) list
val search : graph_runtime -> string -> Search_index.indexed_search_hit list
