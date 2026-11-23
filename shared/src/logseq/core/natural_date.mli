(** Calendar and natural-language input shared by all native date editors. *)
val day : ?now_ms:float -> string -> int option
val timestamp : ?now_ms:float -> string -> int option
val initialization_count : unit -> int

(** Whether a task timestamp represents local midnight or the first instant of its local day. *)
val is_task_date_only : string -> float -> bool
