(* Search presentation and opening a hit. Scripts live in logseq/drive/search/. *)

let handle (host : Drive_host.host) model = function
  | Model.SearchNodesEffect (id, query) ->
    Some
      (Model.DequeueEffect id
      :: Model.ApplySearchResults (query, Drive_host.search_hits host)
      :: Drive_host.resolved id)
  | Model.OpenSearchResultEffect (id, uuid)
  | Model.OpenSearchNodeEffect (id, uuid)
  | Model.OpenAppNodeEffect (id, uuid) ->
    let rows = Drive_host.node_rows host uuid in
    let title =
      if uuid = "page-1" then "Alpha Doc"
      else if uuid = "block-1" then "alpha block"
      else "Node " ^ uuid
    in
    let page = if uuid = "page-1" then uuid else "page-1" in
    let route =
      {
        (App_test.node_projection uuid page title rows rows) with
        Model.node_outliner_rows = rows;
      }
    in
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             {
               projection with
               Model.node_routes = [ route ];
               pending_reference_uuid = (if uuid = "page-1" then Some uuid else None);
             })
      :: Drive_host.resolved id)
  | Model.LoadPageReferencesEffect (id, uuid) ->
    let row =
      App_test.journal_outline_row "cited-1" uuid "Cited block" "Today" 20260828 0
    in
    Some
      [ Model.DequeueEffect id
      ; Model.ApplyCoreSnapshot
          {
            (App_test.empty_core_projection ()) with
            Model.selected_graph_id = model.Model.selected_graph_id;
            reference_update = Some (uuid, [ row ]);
          }
      ; Model.ResolveEffect (id, true, "") ]
  | Model.CloseAppNodeEffect (id, _) | Model.CloseSearchNodeEffect (id, _) ->
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             { projection with Model.node_routes = [] })
      :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/search"
