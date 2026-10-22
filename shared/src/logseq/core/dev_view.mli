(** Filtering and sorting extracted from the upstream native worker. *)
type sorting_item = { s_id : Datascript.attr; s_asc : bool }
type filter_clause = { f_ident : Datascript.attr; f_op : string; f_match : Datascript.value }
type view_filters = { vf_or : bool; vf_clauses : filter_clause list; vf_present : bool }
val sorting_of_value : Datascript.value -> sorting_item list
val parse_filters : Datascript.value -> view_filters
val build_fast_filter_pred : Datascript.db -> view_filters -> string -> (Datascript.entity -> bool) option
val row_matched : Datascript.db -> Datascript.entity -> view_filters -> string -> bool
val sort_entities : Datascript.db -> sorting_item list -> Datascript.entity list -> Datascript.entity list
val filter_eids : Datascript.db -> Datascript.entity_id list -> view_filters -> string -> Datascript.entity_id list
val sort_eids_by_sorting : Datascript.db -> Datascript.entity_id list -> sorting_item list -> Datascript.entity_id list
val property_object_eids : Datascript.db -> string -> Datascript.entity_id list
