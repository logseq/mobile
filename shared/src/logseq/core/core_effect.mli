(** Translate application effects into session operations inside the core. *)
val request :
  now:(unit -> int) -> fresh_id:(unit -> string) -> string option ->
  (string * string option, string) result
