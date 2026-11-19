val plan : Datascript.db -> now:int -> fresh_uuid:(unit -> string) -> Editor_command.operation ->
  (Pending_ops.pending_intent list, string) result

val tag_template_intent :
  ?applied:int list -> Datascript.tx_report -> now:int -> fresh_uuid:(unit -> string) ->
  (Pending_ops.pending_intent option, string) result
