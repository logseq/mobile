module J = Yojson.Basic

let () =
  let graph = Sys.argv.(1) in
  let catalog = J.to_string (`Assoc ["graphs", `List [`Assoc [
    "graph-id", `String graph; "graph-name", `String "Transport check";
    "graph-e2ee?", `Bool false; "graph-ready-for-use?", `Bool true]]]) in
  let session = Rpc_session.create_session
    { Rpc_session.default_options with
      load_graph_catalog = Some (fun () -> Some catalog);
      send = (fun _ -> Error "The native test host executes HTTP requests");
      sync_cursor = Some (fun () -> Some 41);
      journal_page_id = Some (fun _ -> Some "journal-page");
      stage_operation = Some (fun _ -> Ok ());
      prepare_operation = Some (fun operation -> Ok (Pending_ops.outliner_op operation.Pending_ops.intent, "[]")) } in
  try while true do
    let request = input_line stdin in
    let response = Rpc_session.call session request in
    print_endline response;
    flush stdout
  done with End_of_file -> ()
