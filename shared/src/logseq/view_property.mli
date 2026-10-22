val view : ?compact:bool -> render_block:(Model.outline_row Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t) ->
  Model.logseq_model Signal.signal -> string Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t
val has_properties : string -> bool
