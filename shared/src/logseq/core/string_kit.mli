(** Small string helpers replacing the clojure.string surface used by the
    ported core. All operations are byte-based, like the originals. *)

val starts_with : prefix:string -> string -> bool
val ends_with : suffix:string -> string -> bool
val includes : sub:string -> string -> bool
val index_of : sub:string -> ?start:int -> string -> int option
val last_index_of : sub:string -> string -> int option
val is_blank : string -> bool
val trim : string -> string
val lower : string -> string
val upper : string -> string
val split : on:string -> string -> string list
val split_lines : string -> string list
val replace : string -> match_:string -> replacement:string -> string
val replace_first : string -> match_:string -> replacement:string -> string
val sub : string -> int -> int -> string
val drop : string -> int -> string
val take : string -> int -> string
val char_at : string -> int -> string
val join : string -> string list -> string
val hex_of_char : char -> string
val of_bytes : bytes -> string
val to_bytes : string -> bytes
val is_ascii_whitespace : char -> bool

val utf8_sequence_length : int -> int
val utf16_units : int -> int
val byte_index_of_utf16 : string -> int -> int
val utf16_length : string -> int
