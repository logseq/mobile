type picker = Embed | Template | Link | Image | Date | Deadline | Scheduled | Youtube
type action =
  | Insert of string * int
  | Properties of (string * Pending_ops.semantic_value option) list
  | Choice of string * string option
  | Code of string option
  | Number of bool
  | Journal of int
  | Time
  | Pick of picker
type entry = { id : string; label : string; action : action }
type operation =
  | Insert_code of string * string option
  | Ensure_journal of int
  | Apply of string * action
  | Embed_node of string * string * bool
  | Apply_template of string * string * string
val catalog : Datascript.db option -> entry list
val candidates : Datascript.db option -> string -> entry list
val picker_name : picker -> string
val picker_of_name : string -> picker option
val journal_reference : Datascript.db option -> int -> string
val date_ms : string -> (int, string) result
val timestamp : string -> (int, string) result
val link : image:bool -> string -> (string, string) result
