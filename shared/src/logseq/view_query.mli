val view : render_block:(Model.outline_row Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t) ->
  Model.logseq_model Signal.signal -> Model.outline_row Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val collection : render_block:(Model.outline_row Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t) ->
  Model.logseq_model Signal.signal -> string Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t

val property_editor : ?open_node:(string * (unit -> unit)) ->
  ?open_nodes:(string * string * (unit -> unit)) list -> id:string -> column:Yojson.Basic.t ->
  submit:((string * Yojson.Basic.t) list -> unit) -> Model.logseq_model Signal.signal ->
  Yojson.Basic.t -> (unit -> unit) -> Lui_elements.t

val block_values : render_block:(Model.outline_row Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t) ->
  string -> Yojson.Basic.t Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t

val action_error : Model.logseq_model Signal.signal -> string -> Lui_elements.t
val waiting : Model.logseq_model Signal.signal -> string -> bool Signal.signal

val temporal_picker : string -> string -> string Signal.signal -> (string -> unit) -> Lui_elements.t
val temporal_default : string -> string
