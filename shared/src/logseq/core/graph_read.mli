(** Read-side queries over a graph DataScript database, producing
    cache-model blocks and entity summaries. *)

type sidebar_pages =
  { favorites : Cache_model.entity_summary list
  ; recent_pages : Cache_model.entity_summary list
  }

val value : Datascript.db -> int -> string -> Datascript.value option
val string_value : Datascript.value option -> string option
val uuid_value : Datascript.value option -> string option
val int_value : Datascript.value option -> int option
val uuid_for_eid : Datascript.db -> int -> string option
val has_ref : Datascript.db -> int -> string -> int -> bool
val ref_eids : Datascript.db -> int -> string -> int list
val class_descendants : Datascript.db -> int -> int list
val entity_is_instance_of : Datascript.db -> int -> string -> bool
val tag_display_type : Datascript.db -> int -> string option
val default_task_status_eid : Datascript.db -> int option
val entity_summary :
  (string -> (string, string) result) ->
  Datascript.db ->
  int ->
  Cache_model.entity_summary option
val entity_summaries :
  (string -> (string, string) result) ->
  Datascript.db ->
  int ->
  string ->
  Cache_model.entity_summary list
val visible_tag_summaries :
  (string -> (string, string) result) ->
  Datascript.db ->
  int ->
  Cache_model.entity_summary list
val breadcrumbs :
  (string -> (string, string) result) ->
  Datascript.db ->
  int ->
  Cache_model.entity_summary list
val status_for_eid :
  (string -> (string, string) result) ->
  Datascript.db ->
  int ->
  Cache_model.status option
val block :
  ?with_breadcrumbs:bool ->
  (string -> (string, string) result) ->
  Datascript.db ->
  int ->
  Cache_model.block option
val page_is_hidden : Datascript.db -> int -> bool
val page_summary :
  (string -> (string, string) result) ->
  Datascript.db ->
  int ->
  Cache_model.entity_summary option
val favorite_page_eid : Datascript.db -> int option
val recycle_page_eid : Datascript.db -> int option
val last_order : Datascript.db -> string -> int -> string option
val last_recycle_order : Datascript.db -> string option
val last_favorite_order : Datascript.db -> string option
val favorite_block_eid : Datascript.db -> string -> int option
val favorite_block_uuid : Datascript.db -> string -> string option
val page_is_favorite : Datascript.db -> string -> bool
val sidebar_pages :
  (string -> (string, string) result) -> Datascript.db -> sidebar_pages
val page_block :
  (string -> (string, string) result) ->
  Datascript.db ->
  int ->
  Cache_model.block option
val tag_pages :
  (string -> (string, string) result) ->
  Datascript.db ->
  Cache_model.entity_summary list
val node_is_tag : Datascript.db -> string -> bool
val node_is_property : Datascript.db -> string -> bool
val unique_named_uuid : bool -> Datascript.db -> string -> string option
val known_title : Cache_model.entity_summary list -> string -> string option
val normalize_title_text :
  (string -> string option) -> Datascript.db -> string -> string -> string
val normalize_titles_creating_tags :
  Datascript.db ->
  (unit -> string) ->
  string ->
  string list ->
  string list * (string * string) list
val compare_blocks : Cache_model.block -> Cache_model.block -> int
val compare_journal_blocks : Cache_model.block -> Cache_model.block -> int
val blocks_referencing :
  ?with_breadcrumbs:bool ->
  (string -> (string, string) result) ->
  Datascript.db ->
  string ->
  string ->
  Cache_model.block list
val blocks_for_page :
  (string -> (string, string) result) ->
  Datascript.db ->
  string ->
  Cache_model.block list
val references_for_node :
  (string -> (string, string) result) ->
  Datascript.db ->
  string ->
  Cache_model.block list

type page_window_row = {
  block : Cache_model.block;
  depth : int;
  has_children : bool;
  is_collapsed : bool;
}
type page_window = {
  rows : page_window_row list;
  next_offset : int option;
}
type page_reader

(** Create a lazy depth-first reader for one immutable database and collapse
    state. Child ordering metadata is shared by subsequent window reads. *)
val page_reader : ?collapsed:string list -> Datascript.db -> string -> page_reader

(** Change the collapse state while reusing the same immutable tree metadata. *)
val page_reader_with_collapsed : page_reader -> string list -> page_reader

(** Hydrate at most 32 visible rows. Skipped rows and collapsed descendants do
    not load block content. [next_offset] continues the same visible outline. *)
val read_page_window :
  ?offset:int -> ?limit:int -> (string -> (string, string) result) ->
  page_reader -> page_window
val node_destination :
  (string -> (string, string) result) ->
  Datascript.db ->
  string ->
  (Cache_model.entity_summary * bool) option
val objects_for_tag :
  (string -> (string, string) result) ->
  Datascript.db ->
  string ->
  Cache_model.block list
val recent_journal_page_ids : ?through_day:int -> int -> Datascript.db -> int list
val journal_page_count : Datascript.db -> int
val journal_page_uuid : Datascript.db -> int -> string option
val blocks :
  ?block_limit:int -> ?through_day:int ->
  (string -> (string, string) result) ->
  int ->
  Datascript.db ->
  Cache_model.block list

val node_icon : Datascript.db -> string -> Yojson.Basic.t option
