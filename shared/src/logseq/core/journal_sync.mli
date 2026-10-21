(** Adapter for the dev journal protocol and vendored normalization/replay core. *)
type entry = { t : int; tx_id : string option; tx : Dev_sync.Wire.t list }
type journal =
  { t : int; t_before : int option; entries : entry list; graph_id : string option }
val decode : string -> (journal, string) result
val capture : ?creator:Created_by.identity -> Datascript.db -> Datascript.tx_op list -> Datascript.db * string * string
val replay : Datascript.db -> string -> string -> string -> Datascript.db
val encode : (string -> (string, string) result) -> string -> (string, string) result
val apply :
  (string -> (string, string) result) -> Datascript.conn -> int -> journal ->
  (string list * string list, string) result
