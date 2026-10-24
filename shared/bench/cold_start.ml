(* Use an isolated copy of a downloaded graph. Each invocation is a fresh
   process and DataScript cache; the operating system's file cache is retained. *)
module Json = Yojson.Basic

let timings = ref []
let measure name f =
  let started = Unix.gettimeofday () in
  let value = f () in
  let elapsed = (Unix.gettimeofday () -. started) *. 1000. in
  timings := (name, `Float elapsed) :: !timings;
  Printf.eprintf "COLD_START stage=%s elapsed_ms=%.3f\n%!" name elapsed;
  value

let () =
  if Array.length Sys.argv <> 2 then failwith "usage: cold_start <graph-directory>";
  let directory = Sys.argv.(1) in
  let catalog_path = Filename.concat directory "catalog.sqlite" in
  if not (Sys.file_exists catalog_path) then begin
    let catalog = Sqlite.open_session catalog_path in
    Sqlite.store_string catalog Mobile_session.graph_catalog_address
      {|{"graphs":[{"graph-id":"lambda-latency","graph-name":"Lambda","graph-e2ee?":false,"graph-ready-for-use?":true}]}|};
    Sqlite.close catalog
  end;
  let host = measure "create_host" (fun () ->
    Mobile_session.create (fun _ -> failwith "unexpected crypto request")) in
  let call method_ params =
    let body = Json.to_string (`Assoc ["apiVersion", `Int 1;
      "method", `String method_; "params", `Assoc params]) in
    let response = Mobile_session.call host body in
    let json = Json.from_string response in
    if Json.Util.member "ok" json <> `Bool true then failwith response;
    response in
  let dispatch action payload = call "dispatch" ["action", `String action;
    "payload", `String (Json.to_string (`Assoc payload))] in
  ignore (measure "catalog_open" (fun () ->
    call "open" ["path", `String catalog_path]));
  ignore (measure "configure" (fun () -> dispatch "configure" [
    "graphId", `String "lambda-latency"; "token", `String "";
    "baseUrl", `String "https://api.logseq.io"]));
  let response = measure "graph_open_and_snapshot" (fun () -> dispatch "openGraph" [
    "graphId", `String "lambda-latency";
    "activePath", `String (Filename.concat directory "graph.sqlite");
    "checkpointPath", `String (Filename.concat directory "sync.checkpoint");
    "isEncrypted", `Bool false]) in
  let output = open_out (Filename.concat directory "snapshot.json") in
  output_string output response;
  close_out output;
  ignore (measure "ui_initialize" (fun () -> Native_bridge.initialize 2 2 3));
  ignore (measure "ui_apply_snapshot" (fun () -> Native_bridge.apply_response response));
  let sidebar = measure "load_sidebar" (fun () -> dispatch "loadSidebar" []) in
  ignore (measure "ui_apply_sidebar" (fun () -> Native_bridge.apply_response sidebar));
  let older = measure "load_older_journals" (fun () -> dispatch "loadOlderJournals" []) in
  ignore (measure "ui_apply_older_journals" (fun () -> Native_bridge.apply_response older));
  let output = open_out (Filename.concat directory "older-snapshot.json") in
  output_string output older;
  close_out output;
  print_endline (Json.pretty_to_string (`Assoc [
    "runtime", `String "native OCaml / Dune release profile";
    "cache", `String "fresh process and DataScript cache; OS file cache retained";
    "response_bytes", `Int (String.length response);
    "stages_ms", `Assoc (List.rev !timings)]));
  Native_bridge.dispose () |> ignore;
  Mobile_database.close host.database
