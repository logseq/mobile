(** Read-only Query block execution against the current projected graph DB. *)
type row = Block of Cache_model.block | Cells of string list
type result = {
  kind : string;
  source : string;
  rows : row list;
  error : string option;
}
val render : ?current_page:string -> Datascript.db -> string -> result option
val owner_uuids : Datascript.db -> string list
val to_yojson : (Cache_model.block -> Yojson.Basic.t) -> result -> Yojson.Basic.t

val is_query : Datascript.db -> string -> bool
