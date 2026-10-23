(** Pending outliner operations: intent model, JSON codec, and the
    sqlite-backed queue shared with the mobile app. *)

type pending_state =
  | Queued
  | Submitted
  | Accepted of int
  | Retryable
  | Applied
  | Conflicted of string

type semantic_value =
  | Nil_value
  | Uuid_value of string
  | Vector_value of semantic_value list
  | Set_value of semantic_value list
  | String_value of string
  | Int_value of int
  | Instant_value of int
  | Float_value of float
  | Bool_value of bool
  | Keyword_value of string
  | Map_value of (string * semantic_value) list
  | Ref_uuid of string
  | Ref_ident of string

type property_change =
  { attr : string
  ; expected : semantic_value option
  ; value : semantic_value option
  }

type pending_move =
  { uuid : string
  ; page_uuid : string
  ; parent_uuid : string
  ; order : string
  }

type pending_title =
  { uuid : string
  ; expected_title : string
  ; title : string
  }

type pending_property =
  { uuid : string
  ; attr : string
  ; expected : semantic_value option
  ; value : semantic_value option
  }

type pending_properties =
  { uuid : string
  ; changes : property_change list
  }

type pending_insert =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; parent_uuid : string
  ; order : string
  ; created_at : int
  }

type pending_asset =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; parent_uuid : string
  ; order : string
  ; created_at : int
  ; asset_type : string
  ; asset_size : int
  ; asset_checksum : string
  ; transcript : pending_insert option
  }

type pending_moves =
  { moves : pending_move list
  }

type pending_split =
  { uuid : string
  ; expected_title : string
  ; before : string
  ; after : string
  ; new_uuid : string
  ; new_order : string
  ; created_at : int
  }

type pending_merge =
  { uuid : string
  ; expected_title : string
  ; title : string
  ; previous_uuid : string
  ; expected_previous_title : string
  ; merged_title : string option
  }

type pending_delete =
  { uuids : string list
  }

type pending_create =
  { uuid : string
  ; title : string
  ; created_at : int
  }

type pending_journal =
  { page_uuid : string
  ; block_uuid : string
  ; block_title : string
  ; title : string
  ; journal_day : int
  ; created_at : int
  }

type pending_tag =
  { uuid : string
  ; tag_uuid : string
  }

type pending_favorite =
  { page_uuid : string
  ; favorite_uuid : string
  ; favorite : bool
  ; order : string
  ; created_at : int
  }

type pending_page_delete =
  { page_uuid : string
  ; order : string
  ; deleted_at : int
  }

type pending_property_value =
  { uuid : string
  ; owner_uuid : string
  ; property_ident : string
  ; content : semantic_value
  ; created_at : int
  }

type pending_intent =
  | Atomic of pending_intent list
  | Create_property_value of pending_property_value
  | Save_title of pending_title
  | Set_property of pending_property
  | Set_properties of pending_properties
  | Insert_block of pending_insert
  | Create_asset of pending_asset
  | Move_block of pending_move
  | Move_blocks of pending_moves
  | Split_block of pending_split
  | Merge_backward of pending_merge
  | Delete_blocks of pending_delete
  | Create_tag of pending_create
  | Create_page of pending_create
  | Create_property of pending_create
  | Create_journal of pending_journal
  | Add_tag of pending_tag
  | Set_favorite of pending_favorite
  | Delete_page of pending_page_delete

type pending_operation =
  { operation_id : string
  ; base_t : int
  ; state : pending_state
  ; intent : pending_intent
  }

val semantic_value_from_datascript :
  Datascript.value -> (semantic_value, string) result
val normalize_operation :
  Datascript.db -> pending_operation -> (pending_operation, string) result
val subtree_uuids : Datascript.db -> string list -> string list
val search_visible_property : string -> bool
val affected_uuids : Datascript.db -> pending_intent -> string list
val safe_to_rebase : pending_intent -> bool
val committed_despite_later_changes :
  int -> Datascript.db -> pending_operation -> bool
val outliner_op : pending_intent -> string
val state_string : pending_state -> string
val state_of_string : string -> pending_state
val semantic_value_json : semantic_value -> Yojson.Basic.t
val semantic_value_of_json : Yojson.Basic.t -> semantic_value
val intent_json : pending_intent -> Yojson.Basic.t
val intent_of_json : Yojson.Basic.t -> pending_intent
val raw_title :
  Datascript.db -> string -> (string, string) result
val json_object : (string * Yojson.Basic.t) list -> Yojson.Basic.t
val option_json : ('a -> Yojson.Basic.t) -> 'a option -> Yojson.Basic.t
val option_value : (Yojson.Basic.t -> 'a) -> Yojson.Basic.t -> 'a option
val save : string -> pending_operation -> unit
val list : string -> pending_operation list
val set_state : string -> string -> pending_state -> unit
val remove : string -> string -> unit
val confirm : string -> string list -> unit
val store_raw : string -> string -> int -> string -> string -> unit
val list_raw : string -> (string * int * string * string) list
val normalize_expected_title :
  Datascript.db -> string -> string -> (string, string) result
