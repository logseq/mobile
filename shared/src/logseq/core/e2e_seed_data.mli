(** E2E fixture data: deterministic DataScript seeds for the iOS test
    graphs (composer, outliner, header navigation, rich blocks, tags,
    flashcards, performance). *)

val tag_uuid : string
val source_uuid : string
val older_block_uuid : string
val trailing_tag_uuid : string
val child_tag_uuid : string
val flashcard_uuid : string
val flashcard_answer_uuid : string
val header_navigation_page_uuid : string
val header_navigation_block_uuid : string
val composer_page_uuid : string
val composer_block_uuid : string
val outliner_page_uuid : string
val outliner_block_uuid : string
val outliner_tag_uuid : string

val entity_has_attr : Datascript.db -> int -> string -> bool
val entity_built_in : Datascript.db -> int -> bool
val transact : Datascript.conn -> Datascript.tx_op list -> unit
val reset_user_page_entities : ?preserve_page_uuid:string -> Datascript.conn -> unit
val uuid_attr : string -> Datascript.tx_value
val string_attr : string -> Datascript.tx_value
val int_attr : int -> Datascript.tx_value
val ref_attr : string -> Datascript.tx_value
val many_refs : string list -> Datascript.tx_value
val entity :
  string option -> (string * Datascript.tx_value) list -> Datascript.tx_op
val assoc_attr :
  string ->
  Datascript.tx_value ->
  (string * Datascript.tx_value) list ->
  (string * Datascript.tx_value) list
val page_attrs :
  string ->
  string ->
  string ->
  int ->
  int ->
  (string * Datascript.tx_value) list
val block_attrs :
  string ->
  string ->
  string ->
  string ->
  int ->
  (string * Datascript.tx_value) list
val seed_current_journal :
  Datascript.conn -> int -> string -> string -> string -> unit
val attempt : string -> (unit -> unit) -> (unit, string) result
val seed_composer : Datascript.conn -> int -> (unit, string) result
val page_uuid : int -> string
val block_uuid : int -> string
val seed_header_navigation : Datascript.conn -> (unit, string) result
val journal_entities : Datascript.tx_op list
val rich_block_titles : string list
val rich_block_entities : Datascript.tx_op list
val tag_attrs :
  string -> string -> string -> (string * Datascript.tx_value) list
val seed : Datascript.conn -> (unit, string) result
val seed_outliner : Datascript.conn -> int -> (unit, string) result
val seed_fixture : Datascript.conn -> int -> (unit, string) result
val performance_page_uuid : int -> string
val performance_block_uuid : int -> int -> string
val performance_block_title : int -> int -> string
val seed_performance : Datascript.conn -> int -> (unit, string) result
val seed_performance_sized :
  Datascript.conn -> int -> int -> int -> (unit, string) result
