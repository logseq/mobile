type retained_row = {
  render_key : string;
  edit_scope : string option;
  value : Model.outline_row;
  is_editing : bool;
  is_selected : bool;
  editing_title : string;
  editing_caret : int;
}
val make_retained_outline_row :
  ?edit_scope:string -> Model.logseq_model -> Model.outline_row -> retained_row
val embedded_edit_scope : parent_scope:string option -> page:string -> row:string -> mount_id:int -> string
val retained_outliner_rows : Model.logseq_model -> retained_row list
val first_journal_section_visible_ : Model.logseq_model -> bool
val retained_row_value : retained_row -> Model.outline_row
val retained_row_identifier : retained_row -> string
val retained_row_editing_ : retained_row -> bool
val retained_row_selected_ : retained_row -> bool
val retained_row_editing_title : retained_row -> string
val retained_row_editing_caret : retained_row -> int
val paged_keyed : identifier:string -> item_extent:int -> count:int Signal.signal -> offset:int Signal.signal ->
  on_visible_range:(int -> int -> unit) -> source:'a list Signal.signal -> key:('a -> string) ->
  cmp:(string -> string -> int) -> mount:('a Signal.signal -> Lui_elements.t) -> Lui_elements.t
val windowed_keyed :
  ?scroll_target:string option Signal.signal ->
  ?first_section:int Signal.signal ->
  ?reset_key:string Signal.signal -> ?window_size:int -> ?identifier:string -> ?item_extent:int ->
  ?on_visible_range:(int -> int -> unit) -> ?on_window:('a list -> unit) ->
  ?on_prefetch:('a list -> unit) -> ?is_pinned:('a -> bool) ->
  source:'a list Signal.signal -> key:('a -> string) ->
  cmp:(string -> string -> int) -> mount:('a Signal.signal -> Lui_elements.t) ->
  unit -> Lui_elements.t

type reference_entry =
  | Result_views of string
  | Reference_heading of string * string
  | Reference_page of string * Model.sidebar_page
  | Empty_tag
  | Reference_row of string * Model.outline_row
val reference_entries : Model.logseq_model -> reference_entry list
val reference_entry_identifier : reference_entry -> string
val reference_entry_row : reference_entry -> Model.outline_row

type placeholder = {
  parent_uuid : string;
  journal_heading : (string * int * bool) option;
  show_button : bool;
}
type page_entry = Outline_entry of retained_row | Reference_entry of reference_entry
  | Placeholder_entry of placeholder
  | Journal_task_gap
  | Journal_task_heading of string
  | Journal_task_row of Yojson.Basic.t * bool
  | Journal_task_error
val task_field : string -> Yojson.Basic.t -> Yojson.Basic.t
val journal_task_scope : string -> string
val journal_task_editing_row : Model.logseq_model -> Model.outline_row option
val task_rows : Model.logseq_model -> page_entry list
val page_entries : ?include_tasks:bool -> retained_row list -> Model.logseq_model -> page_entry list
val page_entry_identifier : page_entry -> string
val page_entry_outline : page_entry -> retained_row
val page_entry_reference : page_entry -> reference_entry

val first_journal_section_count : ?include_tasks:bool -> Model.logseq_model -> int

val unloaded_entry_id : page_entry -> string option

val page_entry_ready : page_entry -> bool

val page_entry_pinned_ : page_entry -> bool
val retain_page_entry_pin : string option -> page_entry list -> string option * page_entry list
