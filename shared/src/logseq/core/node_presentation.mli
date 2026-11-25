val calculator_results : string -> string list
val preview : Datascript.db -> int -> Yojson.Basic.t
val decorate : ?actor:string -> Datascript.db -> string -> (Yojson.Basic.t -> Yojson.Basic.t)

val reaction_emoji : string -> string
