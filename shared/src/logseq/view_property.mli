val view : ?compact:bool -> render_block:(Model.outline_row Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t) ->
  Model.logseq_model Signal.signal -> string Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t
val has_properties : string -> bool
val has_tag_schema : string -> bool
val owner_uuid : string -> string
val tag_properties : Model.logseq_model Signal.signal -> string Signal.signal ->
  (Model.logseq_action -> bool) -> (unit -> unit) -> Lui_elements.t

val rename_page : string -> (string * Yojson.Basic.t) option

val with_add_property_picker : ?in_tag_properties:bool -> Model.logseq_model Signal.signal -> string Signal.signal ->
  (Model.logseq_action -> bool) -> (Lui_elements.t -> Lui_elements.t -> Lui_elements.t) -> Lui_elements.t

val tag_picker : string -> (string * Yojson.Basic.t) option
