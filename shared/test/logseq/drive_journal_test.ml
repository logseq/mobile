(* Journal history, navigation chrome, and sync status. Scripts live in
   logseq/drive/journal/. *)

let handle (host : Drive_host.host) model = function
  | Model.SyncNowEffect id | Model.SyncPendingEffect id ->
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             { projection with Model.sync_connected = true })
      :: Drive_host.resolved id)
  | Model.LoadOlderJournalsEffect id ->
    Drive_host.append_capture host id "Older journal note" ();
    host.Drive_host.has_older <- false;
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             projection)
      :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/journal"
