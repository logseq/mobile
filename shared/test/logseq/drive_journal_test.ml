(* Journal history, navigation chrome, and sync status. Scripts live in
   logseq/drive/journal/. *)

let handle (host : Drive_host.host) model = function
  | Model.SyncNowEffect id | Model.SyncPendingEffect id ->
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             { projection with Model.sync_connected = true })
      :: Drive_host.resolved id)
  | Model.PresentJournalCalendarEffect id ->
    Some
      (Model.DequeueEffect id
      :: (Drive_host.resolved id @ [ Model.RequestAppNode Drive_host.calendar_journal ]))
  | Model.OpenAppNodeEffect (id, uuid) when uuid = Drive_host.calendar_journal ->
    let row =
      App_test.journal_outline_row "calendar-note" Drive_host.calendar_journal
        "Calendar journal note" "Aug 27th, 2026" 20260827 0
    in
    let route =
      {
        (App_test.node_projection uuid uuid "Aug 27th, 2026" [] []) with
        Model.node_outliner_rows = [ row ];
      }
    in
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             { projection with Model.node_routes = [ route ] })
      :: Drive_host.resolved id)
  | Model.LoadOlderJournalsEffect id ->
    Drive_host.append_older_journal host id;
    host.Drive_host.has_older <- false;
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             projection)
      :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/journal"
