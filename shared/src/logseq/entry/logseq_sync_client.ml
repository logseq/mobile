(* JSON-lines adapter for exercising the real mobile session against a local server. *)
module J = Yojson.Basic
module U = Yojson.Basic.Util
module Ds = Datascript

let host = ref (Mobile_session.create (fun _ -> failwith "Plain sync fixture cannot call crypto"))
let field name input = U.member name input
let text name input = field name input |> U.to_string
let require = function Ok value -> value | Error message -> failwith message
let graph () = (!host).Mobile_session.database.Mobile_database.graph
let runtime () = (Option.get !((graph ()).Mobile_graph.current)).read_runtime
let dispatch action payload =
  let request = `Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String action; "payload", `String (match payload with `String value -> value | _ -> J.to_string payload)]] in
  Mobile_session.call !host (J.to_string request) |> J.from_string

let identity db eid =
  match Graph_read.uuid_for_eid db eid with
  | Some uuid -> uuid
  | None -> match Graph_read.value db eid "db/ident" with
    | Some (Ds.Keyword ident) -> ":" ^ ident
    | _ -> "eid:" ^ string_of_int eid

let rec value_json db = function
  | Ds.Nil -> `Null
  | Ds.Int64 value | Ds.Instant value -> `Int (Int64.to_int value)
  | Ds.Float value -> `Float value
  | Ds.String value | Ds.Uuid value | Ds.Symbol value | Ds.Regex value -> `String value
  | Ds.Keyword value -> `String (":" ^ value)
  | Ds.Bool value -> `Bool value
  | Ds.Ref eid -> `Assoc ["ref", `String (identity db eid)]
  | Ds.Ref_to (Ds.Entity_id eid) -> `Assoc ["ref", `String (identity db eid)]
  | Ds.List values | Ds.Vector values | Ds.Set values -> `List (List.map (value_json db) values)
  | Ds.Map fields -> `Assoc (List.map (fun (key, value) ->
      (match key with Ds.String key | Ds.Keyword key -> key | _ -> J.to_string (value_json db key)), value_json db value) fields |> List.sort compare)
  | Ds.Tuple values -> `List (List.map (Option.fold ~none:`Null ~some:(value_json db)) values)
  | _ -> failwith "Unexpected unresolved reference in sync fixture"

let inspect_runtime runtime =
  let db = Graph_runtime.db runtime in
  let datoms = Ds.Db.datoms db Ds.Eavt () |> List.of_seq |> List.map (fun (d : Ds.datom) ->
    let value = match Datascript_value.ref_eid db d.a d.v with
      | Some eid -> `Assoc ["ref", `String (identity db eid)]
      | None -> value_json db d.v in
    `List [`String (identity db d.e); `String d.a; value]) |> List.sort compare in
  `Assoc ["serverT", `Int (Graph_runtime.state runtime).server_t;
    "datoms", `List datoms;
    "pending", `List (List.map (fun (op : Pending_ops.pending_operation) ->
      `Assoc ["id", `String op.operation_id; "state", `String (Pending_ops.state_string op.state);
        "intent", Pending_ops.intent_json op.intent]) (Pending_ops.list runtime.path))]

let inspect () = inspect_runtime (runtime ())

let open_graph input =
  let root = text "root" input in
  if not (Sys.file_exists root) then Unix.mkdir root 0o700;
  Mobile_database.close (!host).database;
  host := Mobile_session.create (fun _ -> failwith "Plain sync fixture cannot call crypto");
  let catalog = Filename.concat root "catalog.sqlite" in
  ignore (Mobile_session.call !host (J.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "open";
    "params", `Assoc ["path", `String catalog]])));
  let cfg = Live_sync.config (text "baseUrl" input) (text "token" input) (text "graphId" input) in
  ignore (dispatch "configure" (`Assoc ["baseUrl", `String cfg.base_url; "token", `String cfg.token; "graphId", `String cfg.graph_id; "graphName", field "name" input]));
  let active = Filename.concat root "graph.sqlite" in
  if not (Sys.file_exists active) then begin
    let metadata, downloaded = Live_sync.download_snapshot cfg in
    ignore (Live_sync.import_downloaded cfg.graph_id None root metadata downloaded);
    Sys.remove downloaded
  end;
  dispatch "bootstrapGraph" (`Assoc ["graphId", `String cfg.graph_id; "activePath", `String active;
    "checkpointPath", `String (Filename.concat root "sync.checkpoint")])

let handle input =
  match text "command" input with
  | "create" ->
    let cfg = Live_sync.config (text "baseUrl" input) (text "token" input) "" in
    let cfg = Live_sync.create_and_upload cfg (text "name" input) false (fun text -> Ok text) in
    `Assoc ["graphId", `String cfg.graph_id]
  | "open" -> open_graph input
  | "dispatch" -> dispatch (text "action" input) (field "payload" input)
  | "snapshot" -> Mobile_session.call !host {|{"apiVersion":1,"method":"snapshot","params":{}}|} |> J.from_string
  | "inspect" -> inspect ()
  | "inspectFile" ->
    let path = text "path" input in
    let conn = require (Graph_store.restore_conn path) in
    inspect_runtime (Graph_runtime.create_base path 0 conn Graph_runtime.default_options)
  | "stage" ->
    let runtime = runtime () in
    let operation = Graph_runtime.queued_operation runtime (text "operationId" input)
      (Pending_ops.intent_of_json (field "intent" input)) in
    require (Mobile_graph.stage (graph ()) operation);
    inspect ()
  | "order" ->
    let optional name = match field name input with `String value -> Some value | _ -> None in
    `String (require (Fractional_order.between (optional "left") (optional "right")))
  | "close" -> Mobile_database.close (!host).database; `Null
  | _ -> failwith "Unknown local sync fixture command"

let () =
  try while true do
    let line = read_line () in
    let output = try `Assoc ["ok", `Bool true; "result", handle (J.from_string line)]
      with exn -> `Assoc ["ok", `Bool false; "error", `String (Printexc.to_string exn)] in
    print_endline (J.to_string output)
  done with End_of_file -> Mobile_database.close (!host).database
