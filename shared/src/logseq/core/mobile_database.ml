module Graph = Mobile_graph
module Sqlite = Sqlite
module Model = Cache_model

type mobile_database =
  { graph : Graph.mobile_graph
  ; catalog : Sqlite.session option ref
  ; projection : Sqlite.session option ref
  }

let create (graph : Graph.mobile_graph) =
  { graph; catalog = ref None; projection = ref None }

let close_projection database =
  (match !(database.projection) with
   | Some projection -> Sqlite.close projection
   | None -> ());
  database.projection := None

let close_graph database graph_id =
  (match !(database.graph.current) with
   | Some opened when opened.graph_id = graph_id ->
     close_projection database;
     database.graph.current := None
   | _ -> ());
  Ok ()

let close database =
  (match !(database.catalog) with
   | Some catalog -> Sqlite.close catalog
   | None -> ());
  database.catalog := None;
  close_projection database;
  database.graph.current := None

let open_catalog database path =
  close database;
  let catalog = Sqlite.open_session path in
  database.catalog := Some catalog;
  catalog

let model_for_graph database graph_id =
  match !(database.graph.Graph.current) with
  | Some opened when opened.graph_id = graph_id ->
    close_projection database;
    let path =
      Filename.concat
        (Filename.dirname opened.Graph.checkpoint_path)
        "projection.sqlite"
    in
    let projection = Sqlite.open_session path in
    (try
       let storage = Sqlite.storage projection in
       (if Datascript.storage_addresses storage = [] then
          match !(database.catalog) with
          | Some catalog -> Sqlite.migrate_datascript_storage catalog projection
          | None -> ());
       let model = Model.create (Some storage) in
       database.projection := Some projection;
       model
     with error ->
       Sqlite.close projection;
       raise error)
  | _ -> Model.create None
