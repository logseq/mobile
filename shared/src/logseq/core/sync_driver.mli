(** Shared decisions for the native graph-event transport. *)

type t
type event =
  | Opened
  | Frame of string
  | Failed of string
  | Closed
  | Cancelled
  | Snapshot_applied
  | Network of bool
  | Submission_response of int * string * int option

val empty : t
val generation : t -> int
val graph_id : t -> string
val connected : t -> bool
val error : t -> string option
val without_commands : t -> t
val invalidate : t -> t
val begin_connection :
  Api.api_config -> cursor:int option -> editing:bool -> t -> (t, string) result
val receive :
  cursor:int option ->
  editing:bool ->
  apply_frame:(string -> (int option, string) result) ->
  event -> t -> t
val to_yojson : t -> Yojson.Basic.t
