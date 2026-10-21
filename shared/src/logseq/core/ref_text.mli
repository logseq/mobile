(** Rewrite Markdown page refs and tags without changing literal link/code text. *)

val config : Mldoc.Conf.t
val is_uuid : string -> bool
val plain_tag_label : string -> bool
val page_names : string -> string list
val tag_names : string -> string list
val to_text :
  (string -> string option) -> (string -> string option) -> string -> string
val to_ids :
  (string -> string option) -> (string -> string option) -> string -> string
