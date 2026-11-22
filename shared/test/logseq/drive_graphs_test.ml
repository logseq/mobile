(* Graph catalog, create, open, unlock, and delete. Scripts live in
   logseq/drive/graphs/. *)

let open_graph (host : Drive_host.host) id (graph : Model.graph) =
  Model.DequeueEffect id
  :: Model.ApplyCoreSnapshot
       (Drive_host.project host ~graph_id:graph.Model.id ~graph_name:graph.name
          ~encrypted:graph.is_encrypted ~unlocked:(not graph.is_encrypted)
          ~rows:host.Drive_host.rows ~sidebar:(Drive_host.host_sidebar host)
          ~flashcards:host.flashcards ~task_statuses:host.task_statuses
          host.graphs)
  :: Drive_host.resolved id

let reveal_remote (host : Drive_host.host) =
  let add id name role =
    if not (List.exists (fun (g : Model.graph) -> g.id = id) host.graphs) then
      host.graphs <-
        host.graphs @ [ { (Drive_host.graph_entry id name false) with Model.role } ]
  in
  add "SyncedGraph" "Synced Graph" None;
  add "RemoteGraph" "Remote Graph" None;
  add "SharedGraph" "Shared Graph" (Some "reader")

let password_required_message =
  "Set an E2EE password before creating your first encrypted graph."

let reload_settings (host : Drive_host.host) =
  Model.ApplySettingsSnapshot
    (Option.value host.Drive_host.saved_settings ~default:Drive_host.default_settings)

let handle (host : Drive_host.host) model = function
  | Model.RefreshGraphsEffect id ->
    reveal_remote host;
    let snapshot =
      match
        Option.map (Drive_host.find_graph host) model.Model.selected_graph_id
        |> Option.join
      with
      | Some _ ->
        Drive_host.current_graph_projection host model ~extra:(fun projection ->
            projection)
      | None -> Model.ApplyCoreSnapshot (Drive_host.catalog_projection host.graphs)
    in
    Some
      (Model.DequeueEffect id
      :: Model.ApplyLocalGraphIds (Drive_host.graph_ids host)
      :: snapshot
      :: reload_settings host
      :: Drive_host.resolved id)
  | Model.CreateGraphEffect (id, name, encrypted, password)
    when name = "Password Graph" && password = "" ->
    Some
      [ Model.DequeueEffect id
      ; Model.ResolveEffect (id, false, password_required_message) ]
  | Model.CreateGraphEffect (id, name, encrypted, _password) ->
    let graph = Drive_host.graph_entry name name encrypted in
    host.graphs <- host.graphs @ [ graph ];
    Some
      (Model.DequeueEffect id
      :: Model.ApplyLocalGraphIds (Drive_host.graph_ids host)
      :: Model.ApplyCoreSnapshot
           (Drive_host.project host ~graph_id:name ~graph_name:name ~encrypted
              ~unlocked:(not encrypted) ~rows:host.rows
              ~sidebar:(Drive_host.host_sidebar host) ~flashcards:host.flashcards
              ~task_statuses:host.task_statuses host.graphs)
      :: Drive_host.resolved id)
  | Model.DeleteLocalGraphEffect (id, graph_id) ->
    host.graphs <-
      List.filter (fun (g : Model.graph) -> g.id <> graph_id) host.graphs;
    Some
      (Model.DequeueEffect id
      :: Model.ApplyLocalGraphIds (Drive_host.graph_ids host)
      :: Model.ApplyCoreSnapshot (Drive_host.catalog_projection host.graphs)
      :: Drive_host.resolved id)
  | Model.OpenGraphEffect (id, graph_id) ->
    Some
      (match Drive_host.find_graph host graph_id with
      | Some graph -> open_graph host id graph
      | None ->
        [ Model.DequeueEffect id
        ; Model.ResolveEffect (id, false, "unknown graph") ])
  | Model.UnlockGraphEffect (id, "wrong") ->
    Some
      [ Model.DequeueEffect id
      ; Model.ResolveEffect (id, false, "authenticationFailure") ]
  | Model.UnlockGraphEffect (id, _) ->
    Some
      (match
         Option.map (Drive_host.find_graph host) model.Model.selected_graph_id
         |> Option.join
       with
      | Some graph ->
        Model.DequeueEffect id
        :: Model.ApplyCoreSnapshot
             (Drive_host.project host ~graph_id:graph.id ~graph_name:graph.name
                ~encrypted:graph.is_encrypted ~unlocked:true ~rows:host.rows
                ~sidebar:(Drive_host.host_sidebar host)
                ~flashcards:host.flashcards host.graphs)
        :: Drive_host.resolved id
      | None -> Model.DequeueEffect id :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/graphs"
