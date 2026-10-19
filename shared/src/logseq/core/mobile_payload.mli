(** JSON payload decoding for mobile open-graph / snapshot-import / sync
    events received from the host app. *)

type open_graph_request =
  { graph_id : string
  ; active_path : string
  ; checkpoint_path : string
  ; e2ee : bool
  }

type import_snapshot_request =
  { graph_id : string
  ; active_path : string
  ; checkpoint_path : string
  ; metadata_body : string
  ; download_path : string
  ; e2ee : bool
  }

val database_open_path : string -> string option
val decode_open : string -> (open_graph_request, string) result
val decode_import : string -> (import_snapshot_request, string) result
val decode_sync_event : string -> (Journal_sync.journal, string) result
