(** Full-text search index over block titles, backed by sqlite FTS. *)

type search_index =
  { path : string
  }

type search_result =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; is_page : bool
  }

type indexed_search_hit =
  { uuid : string
  ; title : string
  ; is_page : bool
  ; page : Cache_model.entity_summary option
  ; breadcrumbs : Cache_model.entity_summary list
  }

val search_open : string -> unit
val search_upsert : string -> (string * string * string) list -> unit
val search_delete : string -> string list -> unit
val search_query : string -> string -> string list -> (string * string * string) list
val utf8_length : string -> int
val utf8_chars : string -> string list
val clean_str : string -> string
val str_len_distance : string -> string -> float
val fuzzy_score : string -> string -> float
val get_match_input : string -> string
val create : string -> search_index
val row_of_eid : Datascript.db -> int -> (string * string * string) option
val row_for_uuid : Datascript.db -> string -> (string * string * string) option
val rows_of_db : Datascript.db -> (string * string * string) list
val referring_uuids : Datascript.db -> string -> string list
val refresh_uuids :
  search_index -> Datascript.db -> Datascript.db -> string list -> unit
val refresh : search_index -> Datascript.db -> unit
val search :
  int -> search_index -> string -> search_result list
val search_hits :
  int -> search_index -> Datascript.db -> string -> indexed_search_hit list
val query_rows :
  search_index -> string -> string list -> (string * string * string) list

val search_hits_page :
  offset:int -> limit:int -> search_index -> Datascript.db -> string ->
  indexed_search_hit list * bool
