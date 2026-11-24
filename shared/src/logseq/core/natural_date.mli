(** Calendar and natural-language input shared by all native date editors. *)
val day : ?now_ms:float -> ?locale:string -> string -> int option
val timestamp : ?now_ms:float -> ?locale:string -> ?full_match:bool -> string -> int option
val initialization_count : unit -> int
