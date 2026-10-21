(** SQLite helpers for the graph database: kvs storage, pending ops,
    sync state, and the search index. *)

type graph_reader

val open_reader : string -> graph_reader
val reader_row : graph_reader -> int -> (string * string option) option
val close_reader : graph_reader -> unit

val prepare_staging : string -> unit
val append_staging : string -> Snapshot.snapshot_row list -> unit
val read_stored_row : string -> int -> (string * string option) option
val list_stored_addresses : string -> int list
val delete_stored_addresses : string -> int list -> unit
val copy_app_tables : string -> string -> unit

val store_pending : string -> string -> int -> string -> string -> unit
val list_pending : string -> (string * int * string * string) list
val set_pending_state : string -> string -> string -> unit
val remove_pending : string -> string -> unit
val store_pending_tx : string -> string -> string -> string -> unit
val store_resolved_pending : string -> string -> int -> string -> string -> string -> string -> unit
val pending_tx : string -> string -> (string * string) option

val with_app_db : string -> (Sqlite3.db -> 'a) -> 'a
val with_search_db : string -> (Sqlite3.db -> 'a) -> 'a
val search_open : string -> unit
val search_upsert : string -> (string * string * string) list -> unit
val search_delete : string -> string list -> unit
val search_query : string -> string -> string list -> (string * string * string) list

val with_db : string -> (Sqlite3.db -> 'a) -> 'a
val query :
  Sqlite3.db -> string -> Sqlite3.Data.t list -> (Sqlite3.stmt -> 'a) -> 'a list

val search_source_version : string -> string option
val search_version : string -> string option
val set_search_version : string -> string option -> unit
