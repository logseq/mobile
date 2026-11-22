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
    let route =
      {
        (App_test.node_projection uuid "page-1" ("Node " ^ uuid) rows rows) with
        Model.node_outliner_rows = rows;
      }
    in
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             { projection with Model.node_routes = [ route ] })
      :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/search"
