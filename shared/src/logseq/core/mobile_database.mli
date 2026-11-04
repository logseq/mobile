(** Mobile database host: owns the graph catalog and per-graph projection
    SQLite sessions and produces the cache model for the open graph. *)

type mobile_database =
  { graph : Mobile_graph.mobile_graph
  ; catalog : Sqlite.session option ref
  ; projection : Sqlite.session option ref
  }

val create : Mobile_graph.mobile_graph -> mobile_database
val close_projection : mobile_database -> unit
val close_graph : mobile_database -> string -> (unit, string) result
val close : mobile_database -> unit
val open_catalog : mobile_database -> string -> Sqlite.session
val model_for_graph : mobile_database -> string -> Cache_model.model
