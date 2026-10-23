(** Markdown inline markup parsing to a compact node model. *)

type markup_node =
  | Markup_text of string
  | Markup_emphasis of string * markup_node list
  | Markup_code of string
  | Markup_code_block of string option * string
  | Markup_quote of markup_node list
  | Markup_math of string * bool
  | Markup_video of string
  | Markup_iframe of string
  | Markup_html of string
  | Markup_image of string * string
  | Markup_youtube_timestamp of int * string
  | Markup_cloze of string
  | Markup_link of string * markup_node list
  | Markup_node_ref of string * string
  | Markup_tag_ref of string * string

val emphasis_string : string -> string
val append_node : markup_node list -> markup_node -> markup_node list
val youtube_timestamp : string -> markup_node option
val tweet_id : string -> string
val fenced_code : string -> markup_node option
val debug_string : markup_node -> string
val node_to_yojson : markup_node -> Yojson.Basic.t
val to_yojson : markup_node list -> Yojson.Basic.t
val config : Mldoc.Conf.t
val parse :
  Cache_model.entity_summary list ->
  Cache_model.entity_summary list ->
  string ->
  markup_node list

val plain_text : markup_node list -> string
