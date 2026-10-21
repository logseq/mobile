module Json = Yojson.Basic
module Json_util = Yojson.Basic.Util

type api_config =
  { base_url : string
  ; graph_id : string
  ; graph_name : string option
  ; token : string
  }

type api_request =
  { method_ : string
  ; url : string
  ; body : string option
  ; token : string
  }

type api_response =
  { status : int
  ; body : string
  }

type api_file_upload =
  { request : api_request
  ; file_path : string
  ; content_type : string
  ; headers : (string * string) list
  }

type api_graph =
  { id : string
  ; name : string
  ; schema_version : string option
  ; role : string option
  ; e2ee : bool
  ; ready : bool
  }

type api_user_keys =
  { public_key : string
  ; encrypted_private_key : string
  }

let response status body = { status; body }
let epoch_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let trim_slash value =
  if String_kit.ends_with ~suffix:"/" value then
    String.sub value 0 (String.length value - 1)
  else value

let api_root config =
  let base = trim_slash config.base_url in
  if String_kit.ends_with ~suffix:"/api" base then
    String.sub base 0 (String.length base - 4)
  else base

let unreserved ch =
  let code = Char.code ch in
  (code >= 65 && code <= 90)
  || (code >= 97 && code <= 122)
  || (code >= 48 && code <= 57)
  || List.mem code [ 45; 95; 46; 126 ]

let url_encode value =
  let result = Buffer.create (String.length value) in
  let hex = "0123456789ABCDEF" in
  String.iter
    (fun ch ->
      if unreserved ch then Buffer.add_char result ch
      else begin
        let code = Char.code ch in
        Buffer.add_string result "%";
        Buffer.add_char result hex.[code / 16];
        Buffer.add_char result hex.[code mod 16]
      end)
    value;
  Buffer.contents result

let request config method_ path body =
  {
    method_;
    url = api_root config ^ path;
    body;
    token = config.token;
  }

let graph_path config suffix =
  "/api/v1/graphs/" ^ url_encode config.graph_id ^ suffix

let json_body fields = Some (Json.to_string (`Assoc fields))

let graphs_request config = request config "GET" "/graphs" None

let create_graph_request config name schema_version e2ee =
  request config "POST" "/graphs"
    (json_body
       [
         ("graph-name", `String name);
         ("schema-version", `String schema_version);
         ("graph-e2ee?", `Bool e2ee);
         ("graph-ready-for-use?", `Bool false);
       ])

let initial_snapshot_upload_request config file_path checksum =
  {
    request =
      request config "POST"
        ("/sync/" ^ url_encode config.graph_id
         ^ "/snapshot/upload?reset=true&finished=true&checksum="
         ^ url_encode checksum)
        None;
    file_path;
    content_type = "application/transit+json";
    headers = [];
  }

let upsert_user_keys_request config public_key encrypted_private_key =
  request config "POST" "/e2ee/user-keys"
    (json_body ["public-key", `String public_key;
                "encrypted-private-key", `String encrypted_private_key])

let user_keys_request config = request config "GET" "/e2ee/user-keys" None

let graph_key_path config =
  "/e2ee/graphs/" ^ url_encode config.graph_id ^ "/aes-key"

let graph_key_request config = request config "GET" (graph_key_path config) None

let upsert_graph_key_request config encrypted_key =
  request config "POST" (graph_key_path config)
    (json_body [ ("encrypted-aes-key", `String encrypted_key) ])

let encrypted_journal_page_request config uuid title name journal_day =
  request config "POST" (graph_path config "/pages")
    (json_body
       [
         ("uuid", `String uuid);
         ("title", `String title);
         ("name", `String name);
         ("journal-day", `Int journal_day);
       ])

let page_fields page_id =
  match page_id with
  | None -> []
  | Some id -> [ ("page-id", `String id) ]

let block_json uuid text = `Assoc [ ("uuid", `String uuid); ("title", `String text) ]

let capture_request page_id config uuid text =
  request config "POST" (graph_path config "/capture")
    (json_body
       (page_fields page_id @ [ ("blocks", `List [ block_json uuid text ]) ]))

let child_block_request config parent_uuid uuid text =
  request config "POST"
    (graph_path config ("/blocks/" ^ url_encode parent_uuid ^ "/children"))
    (json_body
       [
         ("position", `String "append");
         ("blocks", `List [ block_json uuid text ]);
       ])

let task_request page_id config uuid status text =
  request config "POST" (graph_path config "/tasks")
    (json_body
       ([
          ("uuid", `String uuid);
          ("title", `String text);
          ("status", `String status);
        ]
        @ page_fields page_id))

let asset_upload_request page_id config uuid file_name size checksum file_path
    content_type =
  {
    request =
      request config "POST"
        (graph_path config
           ("/assets?uuid=" ^ url_encode uuid ^ "&file-name="
            ^ url_encode file_name ^ "&size=" ^ string_of_int size ^ "&checksum="
            ^ url_encode checksum
            ^
            match page_id with
            | None -> ""
            | Some id -> "&page-id=" ^ url_encode id))
        None;
    file_path;
    content_type;
    headers = [];
  }

let move_block_request config uuid target_uuid =
  request config "POST" (graph_path config "/block-moves")
    (json_body
       [
         ("block-ids", `List [ `String uuid ]);
         ("target-id", `String target_uuid);
         ("position", `String "last-child");
       ])

let encrypted_asset_upload_request config uuid file_name title page_id size
    upload_size checksum file_path =
  {
    request =
      request config "POST"
        (graph_path config
           ("/assets?uuid=" ^ url_encode uuid ^ "&file-name="
            ^ url_encode file_name ^ "&size=" ^ string_of_int size
            ^ "&upload-size=" ^ string_of_int upload_size ^ "&checksum="
            ^ url_encode checksum ^ "&title=" ^ url_encode title ^ "&page-id="
            ^ url_encode page_id))
        None;
    file_path;
    content_type = "text/plain";
    headers = [];
  }

let member name input =
  match input with `Assoc _ -> Json_util.member name input | _ -> `Null

let option_string_member name input =
  match member name input with `String value -> Some value | _ -> None

let string_member name input =
  match option_string_member name input with
  | Some value -> value
  | None -> ""

let int_member name input =
  match member name input with `Int value -> value | _ -> 0

let list_member name input =
  match member name input with `List values -> values | _ -> []

let created_block_uuid_from_body body =
  let input = Json.from_string body in
  match input with
  | `Assoc _ ->
    let uuid = string_member "uuid" input in
    if String.trim uuid <> "" then uuid
    else
      (match list_member "blocks" input with
       | (`Assoc fields) :: _ ->
         let uuid = string_member "uuid" (`Assoc fields) in
         if String.trim uuid = "" then
           failwith "creation response block is missing uuid"
         else uuid
       | _ -> failwith "creation response is missing uuid")
  | _ -> failwith "creation response must be an object"

let normalize_asset_type value =
  let value = String.lowercase_ascii (String.trim value) in
  match value with
  | "image/jpeg" | "image/jpg" -> "jpeg"
  | "image/png" -> "png"
  | "image/gif" -> "gif"
  | "image/heic" -> "heic"
  | "image/webp" -> "webp"
  | "audio/mp4" | "audio/m4a" | "audio/x-m4a" -> "m4a"
  | "audio/mpeg" -> "mp3"
  | "audio/wav" | "audio/x-wav" -> "wav"
  | "application/pdf" -> "pdf"
  | "application/octet-stream" -> "bin"
  | _ ->
    (match String.index_opt value '/' with
     | Some index ->
       if index + 1 < String.length value then
         let suffix = String.sub value (index + 1) (String.length value - index - 1) in
         if String_kit.starts_with ~prefix:"x-" suffix then
           String.sub suffix 2 (String.length suffix - 2)
         else suffix
       else value
     | None -> value)

let asset_file_name file_name asset_type =
  let extension = normalize_asset_type asset_type in
  if Filename.extension file_name <> "" || extension = "" then file_name
  else file_name ^ "." ^ extension

let content_type_for_asset_type asset_type =
  match normalize_asset_type asset_type with
  | "jpg" | "jpeg" -> "image/jpeg"
  | "png" -> "image/png"
  | "gif" -> "image/gif"
  | "heic" -> "image/heic"
  | "webp" -> "image/webp"
  | "m4a" -> "audio/mp4"
  | "mp3" -> "audio/mpeg"
  | "wav" -> "audio/wav"
  | "pdf" -> "application/pdf"
  | _ -> "application/octet-stream"

let raw_asset_upload_request config uuid asset_type checksum file_path
    content_type =
  let asset_type = normalize_asset_type asset_type in
  {
    request =
      request config "PUT"
        ("/assets/" ^ url_encode config.graph_id ^ "/" ^ url_encode uuid ^ "."
         ^ url_encode asset_type)
        None;
    file_path;
    content_type;
    headers =
      [ ("x-amz-meta-checksum", checksum); ("x-amz-meta-type", asset_type) ];
  }

let update_block_request config uuid title =
  request config "PATCH" (graph_path config ("/blocks/" ^ url_encode uuid))
    (json_body [ ("title", `String title) ])

let tx_batch_request config t_before tx_id outliner_op tx =
  request config "POST"
    ("/sync/" ^ url_encode config.graph_id ^ "/tx/batch")
    (json_body
       [
         ("t-before", `Int t_before);
         ( "txs"
         , `List
             [
               `Assoc
                 [
                   ("tx-id", `String tx_id);
                   ("tx", `String tx);
                   ("outliner-op", `String outliner_op);
                 ];
             ] );
       ])

let update_block_status_request config uuid status =
  request config "PUT"
    (graph_path config ("/blocks/" ^ url_encode uuid ^ "/properties/Status"))
    (json_body [ ("value", `String status) ])

let bool_member default name input =
  match member name input with `Bool value -> value | _ -> default

let nonempty_string_member name input =
  match option_string_member name input with
  | Some value -> if value = "" then None else Some value
  | None -> None

let graph_of_json input =
  match nonempty_string_member "graph-id" input with
  | None -> None
  | Some id ->
    Some
      {
        id;
        name =
          (match nonempty_string_member "graph-name" input with
           | Some name -> name
           | None -> id);
        schema_version = nonempty_string_member "schema-version" input;
        role = nonempty_string_member "role" input;
        e2ee = bool_member true "graph-e2ee?" input;
        ready = bool_member false "graph-ready-for-use?" input;
      }

let graphs_from_graphs_body body =
  List.filter_map graph_of_json (list_member "graphs" (Json.from_string body))

let graph_from_graphs_body body =
  match graphs_from_graphs_body body with
  | graph :: _ -> Some (graph.id, Some graph.name)
  | [] -> None

let user_keys_from_body body =
  let input = Json.from_string body in
  match input with
  | `Assoc _ ->
    let required name =
      match nonempty_string_member name input with
      | Some value -> value
      | None -> failwith ("user keys response is missing " ^ name)
    in
    {
      public_key = required "public-key";
      encrypted_private_key = required "encrypted-private-key";
    }
  | _ -> failwith "user keys response must be an object"

let graph_key_from_body body =
  let input = Json.from_string body in
  match input with
  | `Assoc _ ->
    (match nonempty_string_member "encrypted-aes-key" input with
     | Some value -> value
     | None -> failwith "graph key response is missing encrypted-aes-key")
  | _ -> failwith "graph key response must be an object"
