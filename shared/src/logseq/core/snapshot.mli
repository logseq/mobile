(** Framed snapshot streaming codec shared by SQLite bootstrap and sync. *)

type snapshot_row =
  { addr : int
  ; content : string
  ; addresses : string option
  }

type snapshot_parser =
  { max_frame_bytes : int
  ; buffer : string ref
  }

type snapshot_progress =
  { accepted_rows : int
  ; last_addr : int option
  ; has_root : bool
  ; has_tail : bool
  }

type snapshot_import =
  { graph_id : string
  ; schema_version : string
  ; baseline_t : int
  ; expected_rows : int option
  ; progress : snapshot_progress ref
  }

type snapshot_completed_import =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int
  ; row_count : int
  }

val create_parser : int -> snapshot_parser
val feed : snapshot_parser -> string -> (snapshot_row list, string) result
val finish_parser : snapshot_parser -> (unit, string) result
val create_import : string -> string -> int -> int -> snapshot_import
val create_stream_import : string -> string -> int -> int option -> snapshot_import
val validate_rows : snapshot_import -> snapshot_row list -> (snapshot_progress, string) result
val accept_rows : snapshot_import -> snapshot_row list -> (unit, string) result
val finish_import :
  snapshot_import -> (snapshot_completed_import, string) result
