
type open_graph_request =
  { graph_id : string
  ; active_path : string
  ; checkpoint_path : string
  ; e2ee : bool
  }

type import_snapshot_request =
  { graph_id : string
  ; active_path : string
  ; checkpoint_path : string
  ; metadata_body : string
  ; download_path : string
  ; e2ee : bool
  }

let field fields name =
  List.find_map (fun (key, value) -> if key = name then Some value else None)
    fields

let database_open_path payload =
  try
    match Yojson.Basic.from_string payload with
    | `Assoc fields ->
      (match (field fields "method", field fields "params") with
       | Some (`String "open"), Some (`Assoc params) ->
         (match field params "path" with
          | Some (`String path) -> Some path
          | _ -> None)
       | _ -> None)
    | _ -> None
  with _ -> None

let required_string fields name =
  match field fields name with
  | Some (`String value) ->
    if value = "" then Error ("graph sync payload requires " ^ name)
    else Ok value
  | _ -> Error ("graph sync payload requires " ^ name)

let optional_bool fields name =
  match field fields name with
  | Some (`Bool value) -> Ok value
  | None -> Ok false
  | _ -> Error ("graph sync payload requires a boolean " ^ name)

let decode_open payload =
  let ( let* ) = Result.bind in
  try
    match Yojson.Basic.from_string payload with
    | `Assoc fields ->
      let* graph_id = required_string fields "graphId" in
      let* active_path = required_string fields "activePath" in
      let* checkpoint_path = required_string fields "checkpointPath" in
      let* e2ee = optional_bool fields "isEncrypted" in
      Ok { graph_id; active_path; checkpoint_path; e2ee }
    | _ -> Error "openGraph payload must be an object"
  with error -> Error (Printexc.to_string error)

let decode_import payload =
  let ( let* ) = Result.bind in
  try
    match Yojson.Basic.from_string payload with
    | `Assoc fields ->
      let* graph_id = required_string fields "graphId" in
      let* active_path = required_string fields "activePath" in
      let* checkpoint_path = required_string fields "checkpointPath" in
      let* metadata_body = required_string fields "metadataBody" in
      let* download_path = required_string fields "downloadPath" in
      let* e2ee = optional_bool fields "isEncrypted" in
      Ok { graph_id; active_path; checkpoint_path; metadata_body; download_path; e2ee }
    | _ -> Error "importSnapshot payload must be an object"
  with error -> Error (Printexc.to_string error)

let decode_sync_event = Journal_sync.decode
