(** Shared snapshot download protocol; native hosts stream and decode bytes. *)
val plan : (string * Yojson.Basic.t) list -> (Yojson.Basic.t, string) result
val resolve : (string * Yojson.Basic.t) list -> (Yojson.Basic.t, string) result
