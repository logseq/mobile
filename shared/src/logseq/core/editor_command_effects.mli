val plan : Datascript.db -> now:int -> fresh_uuid:(unit -> string) -> Editor_command.operation ->
  (Pending_ops.pending_intent list, string) result
