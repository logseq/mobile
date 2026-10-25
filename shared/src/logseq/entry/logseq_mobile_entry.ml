let () =
  if not (Native_bridge.linked ()) then
    failwith "OCaml/LUI native bridge failed to link";
  let host = Mobile_session.start Native_crypto.call_raw in
  Native_bridge.set_search_index_source (fun () ->
    Mobile_graph.pending_search_index host.database.graph)
