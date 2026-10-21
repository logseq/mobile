(** File I/O helpers for encrypting composer asset payloads. *)

val read_file : string -> (string, string) result
val write_file : string -> string -> (unit, string) result
val resolve_path : string option -> string -> string
val resolve_legacy_path : string option -> string -> string -> string
val import_file : string option -> string -> string -> string -> (string, string) result
val encrypt_file :
  (string -> string -> (string, string) result) ->
  string ->
  string ->
  (string * int, string) result

val cache_download : string -> string -> (unit, string) result
