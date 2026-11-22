(* Search presentation and opening a hit. Scripts live in logseq/drive/search/. *)

let handle (host : Drive_host.host) model = function
  | Model.SearchNodesEffect (id, query) ->
    Some
      (Model.DequeueEffect id
      :: Model.ApplySearchResults
           ( query
           , [
               {
                 Model.hit_uuid = "page-1";
                 hit_title = "Alpha Doc";
                 breadcrumb = "";
                 breadcrumbs = [];
                 is_page = true;
               };
               {
                 Model.hit_uuid = "block-1";
                 hit_title = "alpha block";
                 breadcrumb = "Alpha Doc";
                 breadcrumbs = [ { Model.uuid = "page-1"; title = "Alpha Doc" } ];
                 is_page = false;
               };
             ] )
      :: Drive_host.resolved id)
  | Model.OpenSearchResultEffect (id, uuid)
  | Model.OpenSearchNodeEffect (id, uuid)
  | Model.OpenAppNodeEffect (id, uuid) ->
    let route =
      {
        (App_test.node_projection uuid "page-1" ("Node " ^ uuid) host.Drive_host.rows
           host.rows)
        with
        Model.node_outliner_rows = host.rows;
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
