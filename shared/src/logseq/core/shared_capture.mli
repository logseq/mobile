(** Canonical shared-note and deep-link semantics, independent of OS providers. *)
val text : (string * Yojson.Basic.t) list -> (string, string) result
val deep_link : (string * Yojson.Basic.t) list ->
  ([ `Capture of string | `Quick_action of string | `Ignore ], string) result
