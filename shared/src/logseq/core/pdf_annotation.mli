val read : Datascript.db -> asset_uuid:string -> (Yojson.Basic.t, string) result
val reference : Datascript.db -> string -> Yojson.Basic.t option
val mutation : Datascript.db -> now:int -> Yojson.Basic.t ->
  (Pending_ops.pending_intent option, string) result
