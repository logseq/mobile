module J = Yojson.Basic
let field fields key = List.assoc_opt key fields
let string fields key = match field fields key with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error ("Snapshot download requires " ^ key)
let config fields =
  let ( let* ) = Result.bind in
  let* base_url = string fields "baseUrl" in
  let* graph_id = string fields "graphId" in
  Ok { Api.base_url = String.trim base_url; graph_id; graph_name = None; token = "" }

let plan fields =
  let ( let* ) = Result.bind in
  let* config = config fields in
  let root = Api.api_root config ^ "/sync/" ^ Api.url_encode config.graph_id in
  Ok (`Assoc ["metadataURL", `String (root ^ "/snapshot/download")])

let resolve fields =
  let ( let* ) = Result.bind in
  try
    let* body = string fields "metadataBody" in
    let* metadata = match J.from_string body with
      | `Assoc fields -> Ok fields | _ -> Error "Snapshot metadata must be an object" in
    let* () = match field metadata "t" with
      | Some (`Int t) when t >= 0 -> Ok ()
      | _ -> Error "Snapshot cursor metadata is invalid" in
    let* () = if field metadata "ok" = Some (`Bool true) then Ok ()
      else Error "Snapshot metadata did not report success" in
    let* url = string metadata "url" in
    let* encoding = match field metadata "content-encoding" with
      | None | Some `Null -> Ok "identity"
      | Some (`String value) ->
        let value = String.lowercase_ascii (String.trim value) in
        if value = "identity" || value = "gzip" then Ok value
        else Error ("Unsupported snapshot content encoding: " ^ value)
      | _ -> Error "Snapshot content encoding must be a string" in
    let schema = List.find_map (function Some (`String value) when String.trim value <> "" ->
      Some (`String (String.trim value)) | _ -> None)
      [field metadata "schema-version"; field fields "graphSchemaVersion"] in
    let metadata = ("schema-version", Option.value ~default:`Null schema)
      :: List.remove_assoc "schema-version" metadata in
    Ok (`Assoc ["metadataBody", `String (J.to_string (`Assoc metadata));
      "downloadURL", `String url; "contentEncoding", `String encoding])
  with Yojson.Json_error message -> Error message
