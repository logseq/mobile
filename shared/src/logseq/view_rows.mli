type retained_row = {
  render_key : string;
  value : Model.outline_row;
  is_editing : bool;
  editing_title : string;
  editing_caret : int;
}
val make_retained_outline_row :
  Model.logseq_model -> Model.outline_row -> retained_row
val retained_outliner_rows : Model.logseq_model -> retained_row list
val first_journal_section_visible_ : Model.logseq_model -> bool
val retained_row_value : retained_row -> Model.outline_row
val retained_row_identifier : retained_row -> string
val retained_row_editing_ : retained_row -> bool
val retained_row_editing_title : retained_row -> string
val retained_row_editing_caret : retained_row -> int
val windowed_keyed :
  ?scroll_target:string option Signal.signal ->
  ?first_section:int Signal.signal ->
  ?section_titles:(int * string) list Signal.signal -> ?on_window:('a list -> unit) -> ?is_pinned:('a -> bool) ->
  source:'a list Signal.signal -> key:('a -> string) ->
  cmp:(string -> string -> int) -> mount:('a Signal.signal -> Lui_elements.t) -> Lui_elements.t

type reference_entry =
  | Reference_heading of string * string
  | Empty_tag
  | Reference_row of string * Model.outline_row
val reference_entries : Model.logseq_model -> reference_entry list
val reference_entry_identifier : reference_entry -> string
val reference_entry_row : reference_entry -> Model.outline_row

type page_entry = Outline_entry of retained_row | Reference_entry of reference_entry
val page_entries : retained_row list -> Model.logseq_model -> page_entry list
val page_entry_identifier : page_entry -> string
val page_entry_outline : page_entry -> retained_row
val page_entry_reference : page_entry -> reference_entry

val first_journal_section_count : Model.logseq_model -> int

val unloaded_entry_id : page_entry -> string option

val page_entry_ready : page_entry -> bool

val page_entry_editor_ : page_entry -> bool
