(** DataScript-backed model cache for journal/outliner blocks. *)

type entity_summary =
  { uuid : string
  ; title : string
  }

type status =
  { uuid : string
  ; ident : string option
  ; title : string
  ; icon_type : string option
  ; icon_id : string option
  ; icon_color : string option
  }

type block =
  { uuid : string
  ; title : string
  ; page_id : string
  ; parent_id : string option
  ; order : string option
  ; created_at : int
  ; updated_at : int
  ; sync_status : string
  ; tags : entity_summary list
  ; references : entity_summary list
  ; breadcrumbs : entity_summary list
  ; priority : status option
  ; status : status option
  ; display_type : string option
  ; is_asset : bool
  ; asset_type : string option
  ; asset_size : int option
  ; asset_checksum : string option
  ; local_path : string option
  ; journal : (string * int) option
  }

type model_caches =
  { cache_revision : int ref
  ; cached_blocks : (string, block option) Hashtbl.t
  ; cached_journals : (string, (string * int) option) Hashtbl.t
  }

type model =
  { mutable db : Datascript.db
  ; mutable selected_block_uuid : string option
  ; mutable last_refresh_at : int option
  ; mutable revision : int
  ; caches : model_caches
  }

val schema : Datascript.schema
val block_ref : string -> Datascript.entity_ref
val create : Datascript.storage option -> model
val summaries_json : entity_summary list -> string
val summaries_of_json : string -> entity_summary list
val status_json : status -> string
val status_of_json : string -> status option
val block_exists : model -> string -> bool
val read_block : model -> string -> block option
val journal_metadata : model -> string -> (string * int) option
val all_block_uuids : model -> string list
val all_blocks : model -> block list
val all_statuses : model -> status list
val journal_day_for_ms : int -> int
val journal_page_id_for_ms : int -> string
val block_journal_metadata : model -> block -> (string * int) option
val journal_feed_block : model -> block -> bool
val recent_feed_block : model -> block -> bool
val compare_recent : block -> block -> int
val compare_outliner : block -> block -> int
val outliner_preorder : string -> block list -> block list
val journal_blocks : bool -> model -> block list -> block list
val recent_blocks : model -> block list
val visible_blocks : model -> block list
val visible_from : model -> block list -> block list
val selected_block : model -> block option
val commit : model -> Datascript.tx_op list -> unit
val upsert_statuses : model -> status list -> unit
val prefer_local_asset : block -> block -> block
val upsert_blocks : model -> block list -> int -> unit
val select : model -> string -> (unit, string) result
val clear_selection : model -> unit
val upsert_journal_page : model -> string -> int -> string -> unit
val local_block :
  string -> string -> string -> string option -> int -> block
val local_journal : model -> int -> string
val cache_local_message : model -> string -> string -> int -> unit
val cache_local_task : model -> string -> string -> status -> int -> unit
val cache_local_asset :
  model ->
  string ->
  string ->
  string ->
  int ->
  string ->
  string ->
  int ->
  string option ->
  unit
val cache_local_child :
  model -> string -> string -> string -> int -> (unit, string) result
val pending_blocks : model -> block list
val unsynced_blocks : model -> block list
val update_sync_status :
  model -> string -> string -> (unit, string) result
val mark_block_synced : model -> string -> (unit, string) result
val mark_block_submitted : model -> string -> (unit, string) result
val mark_block_sync_failed : model -> string -> (unit, string) result
val reconcile_created_block :
  model -> string -> string -> string -> (unit, string) result
val update_block_title :
  model -> string -> string -> int -> (unit, string) result
val update_block_status :
  model -> string -> status -> int -> (unit, string) result
