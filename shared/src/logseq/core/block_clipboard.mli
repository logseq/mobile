type content = {
  target_uuid : string;
  before_title : string;
  selection_start : int;
  selection_length : int;
  plain_text : string;
  blocks_edn : string;
}

type insertion = {
  intent : Pending_ops.pending_intent;
  focus : string option;
  title : string;
  caret : int;
}

val copy : Datascript.db -> graph:string -> string list -> (string, string) result
val inline : content -> string * int
val paste : Datascript.db -> graph:string -> now:int -> fresh_uuid:(unit -> string) ->
  content -> (insertion, string) result
