val render : Datascript.db -> owner:string ->
  encode_block:(Cache_model.block -> Yojson.Basic.t) -> (Yojson.Basic.t, string) result

val mutation : Datascript.db -> now:int -> fresh_uuid:(unit -> string) ->
  Yojson.Basic.t -> (Pending_ops.pending_intent, string) result
