(** Interpret outliner commands into pending operations and platform calls. *)

type outliner_platform_command =
  | Platform_haptic of Outliner_state.outliner_haptic
  | Focus_block of string
  | Confirm_delete of string list
  | Set_clipboard_blocks of string
  | Set_clipboard_text of string
  | Set_clipboard_references of string list
  | Set_clipboard_urls of string list
  | Platform_pick_attachment of string
  | Platform_take_photo of string
  | Platform_record_audio of string

type outliner_effects =
  { operations : Pending_ops.pending_operation list
  ; platform : outliner_platform_command list
  }

val result :
  Pending_ops.pending_operation list ->
  outliner_platform_command list ->
  outliner_effects
val find_block :
  Outliner_state.outliner_context -> string -> Cache_model.block option
val sorted_siblings :
  Outliner_state.outliner_context -> string option -> Cache_model.block list
val next_order :
  Outliner_state.outliner_context -> Cache_model.block -> string option
val operation :
  int ->
  (unit -> string) ->
  Pending_ops.pending_intent ->
  Pending_ops.pending_operation
val status_reference : Cache_model.status -> Pending_ops.semantic_value
val next_status_value : Cache_model.block -> Pending_ops.semantic_value option
val append_result : outliner_effects -> outliner_effects -> outliner_effects
val command :
  int ->
  (unit -> int) ->
  (unit -> string) ->
  Outliner_state.outliner_context ->
  Outliner_state.outliner_command ->
  (outliner_effects, string) result
val interpret :
  int ->
  (unit -> int) ->
  (unit -> string) ->
  Outliner_state.outliner_context ->
  Outliner_state.outliner_command list ->
  (outliner_effects, string) result
