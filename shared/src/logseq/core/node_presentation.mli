val calculator_results : string -> string list
val preview : ?on_reference:(string -> unit) -> Datascript.db -> int -> Yojson.Basic.t
val decorate : ?actor:string -> ?on_comment_reference:(string -> unit) -> Datascript.db -> string -> (Yojson.Basic.t -> Yojson.Basic.t)

val reaction_emoji : string -> string
