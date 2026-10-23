val render_rows :
  ?input:string -> Datascript.db -> owner:string -> feature:string ->
  encode_block:(Cache_model.block -> Yojson.Basic.t) -> Query_block.row list -> Yojson.Basic.t

val render :
  ?input:string -> Datascript.db -> owner:string -> feature:string ->
  encode_block:(Cache_model.block -> Yojson.Basic.t) -> (Yojson.Basic.t, string) result

val mutation :
  Datascript.db -> now:int -> fresh_uuid:(unit -> string) -> Yojson.Basic.t ->
  (Pending_ops.pending_intent, string) result

val property_json : ?include_candidates:bool -> Datascript.db -> owner:string -> attr:string ->
  encode_block:(Cache_model.block -> Yojson.Basic.t) -> Yojson.Basic.t
val property_metadata : Datascript.db -> string -> Yojson.Basic.t

val edit_property : ?text_value:bool -> ?allow_builtin:bool -> Datascript.db -> now:int -> fresh_uuid:(unit -> string) ->
  Yojson.Basic.t -> Pending_ops.pending_intent
