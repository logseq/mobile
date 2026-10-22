val native_input_policy : string

(** Outliner reducer state, commands, and pure editing operations. *)

module Sset : Set.S with type elt = string

type reducer_autocomplete_kind = Node | Tag | Property

type reducer_autocomplete =
  { kind : reducer_autocomplete_kind
  ; query : string
  }

type outliner_candidate =
  { label : string
  ; value : string
  }

type editor_draft =
  { uuid : string
  ; expected_title : string
  ; title : string
  ; caret : int
  }

type outliner_state =
  { editing : editor_draft option
  ; selected : Sset.t
  ; pending_deletion : string list
  ; autocomplete : reducer_autocomplete option
  ; collapsed : Sset.t
  ; zoomed : string list
  }

type outliner_toolbar =
  | Task
  | Outdent
  | Indent
  | Move_up
  | Move_down
  | Tag_action
  | Page_reference
  | Camera
  | Audio
  | Attachment
  | Hide_keyboard
  | Copy
  | Delete
  | Copy_reference
  | Copy_url
  | Unselect

type outliner_placement = Before | Inside | After

type outliner_text =
  { title : string
  ; caret : int
  }

type outliner_selection =
  { selection_length : int
  }

type outliner_backspace =
  { backspace_title : string
  ; backspace_selection_length : int
  }

type outliner_drop =
  { target_uuid : string
  ; placement : outliner_placement
  }

type outliner_status =
  { status_uuid : string
  ; status : Pending_ops.semantic_value
  }

type outliner_priority =
  { priority_uuid : string
  ; priority : Pending_ops.semantic_value option
  }

type outliner_message =
  | Tap_block of string
  | Long_press_block of string
  | Text_changed of outliner_text
  | Caret_moved of int
  | Return_pressed
  | Return_pressed_with_text of outliner_text
  | Backspace_pressed of outliner_selection
  | Backspace_pressed_with_text of outliner_backspace
  | Toolbar of outliner_toolbar
  | Drop_blocks of outliner_drop
  | Choose_autocomplete of string
  | Confirm_delete
  | Save_editing
  | Cancel_editing
  | Set_task_status of outliner_status
  | Set_task_priority of outliner_priority
  | Toggle_collapsed of string
  | Zoom_in of string
  | Zoom_out
  | Add_root_block of string
  | Operation_staged of Pending_ops.pending_intent

type outliner_haptic = Selection | Impact

type outliner_split =
  { split_uuid : string
  ; split_expected_title : string
  ; before : string
  ; after : string
  }

type outliner_merge =
  { merge_uuid : string
  ; merge_expected_title : string
  ; merge_title : string
  ; previous_uuid : string
  ; expected_previous_title : string
  }

type outliner_tag =
  { tag_target_uuid : string
  ; value : string
  }

type outliner_root =
  { page_uuid : string
  }

type outliner_command =
  | Haptic of outliner_haptic
  | Commit_title of Pending_ops.pending_title
  | Split_at of outliner_split
  | Merge_into_previous of outliner_merge
  | Reparent_blocks of Pending_ops.pending_move list
  | Request_delete_confirmation of string list
  | Remove_blocks of string list
  | Cycle_task_status of string
  | Set_task_status_value of outliner_status
  | Set_task_priority_value of outliner_priority
  | Create_linked_page of string
  | Assign_tag of outliner_tag
  | Pick_attachment of string
  | Take_photo of string
  | Record_audio of string
  | Insert_root_block of outliner_root
  | Copy_text of string
  | Copy_references of string list
  | Copy_urls of string list

type outliner_context =
  { blocks : Cache_model.block list
  ; pages : outliner_candidate list
  ; tags : outliner_candidate list
  ; label_values : (string, Sset.t) Hashtbl.t
  ; dup_labels : Sset.t
  ; search_nodes : string -> outliner_candidate list
  ; is_block_reference : string -> bool
  }

type outliner_row =
  { block : Cache_model.block
  ; depth : int
  ; has_children : bool
  ; is_collapsed : bool
  }

val empty : outliner_state
val editing_uuid : outliner_state -> string option
val editing_title : outliner_state -> string option
val selected_uuids : outliner_state -> string list
val collapsed_uuids : outliner_state -> string list
val autocomplete : outliner_state -> reducer_autocomplete option
val zoom_path : outliner_state -> string list
val find_block : outliner_context -> string -> Cache_model.block option
val duplicated_labels : outliner_candidate list -> Sset.t
val context :
  ?search_nodes:(string -> outliner_candidate list) ->
  ?is_block_reference:(string -> bool) ->
  Cache_model.block list ->
  outliner_candidate list ->
  outliner_candidate list ->
  outliner_context
val summary_candidates : Cache_model.entity_summary list -> outliner_candidate list
val summary_title :
  Sset.t -> Cache_model.entity_summary list -> string -> string option
val display_block_title : outliner_context -> Cache_model.block -> string
val utf8_sequence_length : int -> int
val utf16_units : int -> int
val byte_index_of_utf16 : string -> int -> int
val utf16_length : string -> int
val prefix_at : string -> int -> string
val last_substring : string -> string -> int option
val contains_substring : string -> string -> bool
val includes_normalized_query : string -> string -> bool
val includes_case_insensitive : string -> string -> bool
val autocomplete_candidates :
  outliner_context -> reducer_autocomplete -> outliner_candidate list
val contains_from : string -> int -> string -> bool
val token_request :
  reducer_autocomplete_kind -> char -> string -> reducer_autocomplete option
val autocomplete_for : string -> int -> reducer_autocomplete option
val replace_range : string -> int -> int -> string -> string
val candidate_label :
  outliner_context -> outliner_candidate list -> string -> string option
val reference_token_end : string -> int -> int
val complete :
  outliner_context ->
  editor_draft ->
  reducer_autocomplete_kind ->
  string ->
  editor_draft option
val trim_right : string -> string
val remove_tag_token : editor_draft -> editor_draft option
val commit_effect :
  outliner_context -> editor_draft option -> outliner_command list
val insert_at_caret : editor_draft -> string -> int -> editor_draft
val compare_blocks : Cache_model.block -> Cache_model.block -> int
val compare_root_blocks : Cache_model.block -> Cache_model.block -> int
val sorted_siblings :
  outliner_context -> string option -> Cache_model.block list
val visible_rows : outliner_context -> outliner_state -> outliner_row list
val selected_roots : outliner_context -> Sset.t -> Cache_model.block list
val moves_with_orders :
  Cache_model.block list ->
  string ->
  string option ->
  string option ->
  Pending_ops.pending_move list option
val index_of_uuid : string -> Cache_model.block list -> int option
val selection_indices : Cache_model.block list -> Cache_model.block list -> int list
val selection_is_contiguous :
  Cache_model.block list -> Cache_model.block list -> bool
val same_parent : Cache_model.block list -> string option -> bool
val indent : outliner_context -> Sset.t -> Pending_ops.pending_move list option
val outdent : outliner_context -> Sset.t -> Pending_ops.pending_move list option
val move :
  outliner_context ->
  Sset.t ->
  bool ->
  Pending_ops.pending_move list option
val ancestor_uuids : outliner_context -> Cache_model.block -> Sset.t
val drop :
  outliner_context ->
  Sset.t ->
  string ->
  outliner_placement ->
  Pending_ops.pending_move list option
val step : outliner_state -> outliner_command list -> outliner_state * outliner_command list
val leave_interaction :
  outliner_context -> outliner_state -> outliner_state * outliner_command list
val split_or_outdent :
  outliner_context ->
  outliner_state ->
  editor_draft ->
  outliner_state * outliner_command list
val start_editing :
  outliner_context -> outliner_state -> Cache_model.block -> int -> outliner_state
val merge_backward :
  outliner_context ->
  outliner_state ->
  editor_draft ->
  outliner_state * outliner_command list
val toggle_member : Sset.t -> string -> Sset.t
val interaction_targets : outliner_state -> Sset.t
val toolbar_insert :
  outliner_state -> string -> int -> outliner_state * outliner_command list
val toolbar_move :
  outliner_context ->
  outliner_state ->
  bool ->
  outliner_state * outliner_command list
val toolbar_reorder :
  outliner_context ->
  outliner_state ->
  bool ->
  outliner_state * outliner_command list
val choose_completion :
  outliner_context ->
  outliner_state ->
  string ->
  outliner_state * outliner_command list
val staged_editing :
  outliner_context ->
  outliner_state ->
  string ->
  string ->
  bool ->
  outliner_state * outliner_command list
val take_while : ('a -> bool) -> 'a list -> 'a list
val take_n : int -> 'a list -> 'a list
val update :
  outliner_context ->
  outliner_state ->
  outliner_message ->
  outliner_state * outliner_command list
