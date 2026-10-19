module Transit = Transit_core.Json

type e2ee_keyring =
  { crypto : E2ee.e2ee_crypto
  ; load : string -> (string option, string) result
  ; save : string -> string -> (unit, string) result
  ; load_password : unit -> (string option, string) result
  ; save_password : string -> (unit, string) result
  ; fetch : Api.api_request -> (Api.api_response, string) result
  ; keys : (string, string) Hashtbl.t
  ; private_key : string option ref
  }

let create crypto load save load_password save_password fetch =
  {
    crypto;
    load;
    save;
    load_password;
    save_password;
    fetch;
    keys = Hashtbl.create 16;
    private_key = ref None;
  }

let response_body operation response =
  let ( let* ) = Result.bind in
  let* (response : Api.api_response) = response in
  if response.status >= 200 && response.status < 300 then Ok response.body
  else Error (operation ^ " returned HTTP " ^ string_of_int response.status)

let protect operation f =
  try Ok (f ())
  with
  | Failure message -> Error (operation ^ ": " ^ message)
  | Yojson.Json_error message -> Error (operation ^ ": " ^ message)
  | error -> Error (operation ^ ": " ^ Printexc.to_string error)

let remember keyring graph_id key =
  Hashtbl.replace keyring.keys graph_id key;
  key

let fetch_graph_key keyring config =
  let ( let* ) = Result.bind in
  let* body =
    response_body "fetch graph E2EE key"
      (keyring.fetch (Api.graph_key_request config))
  in
  protect "decode graph E2EE key" (fun () -> Api.graph_key_from_body body)

let remember_graph_key keyring config key =
  let ( let* ) = Result.bind in
  let* () = keyring.save config.Api.graph_id key in
  Ok (remember keyring config.Api.graph_id key)

let unlock_with_private_key keyring config private_key =
  let ( let* ) = Result.bind in
  let* encrypted = fetch_graph_key keyring config in
  let* key =
    E2ee.decrypt_graph_key keyring.crypto private_key encrypted
  in
  remember_graph_key keyring config key

let unlock_with_password keyring config password persist_password =
  let ( let* ) = Result.bind in
  let* body =
    response_body "fetch user E2EE keys"
      (keyring.fetch (Api.user_keys_request config))
  in
  let* user_keys =
    protect "decode user E2EE keys" (fun () -> Api.user_keys_from_body body)
  in
  let* private_key =
    E2ee.decrypt_private_key keyring.crypto password
      user_keys.Api.encrypted_private_key
  in
  let* encrypted = fetch_graph_key keyring config in
  let* key = E2ee.decrypt_graph_key keyring.crypto private_key encrypted in
  let* () = if persist_password then keyring.save_password password else Ok () in
  let* key = remember_graph_key keyring config key in
  keyring.private_key := Some private_key;
  Ok key

let unlock_cached_account keyring config =
  match !(keyring.private_key) with
  | Some private_key -> unlock_with_private_key keyring config private_key
  | None ->
    (match keyring.load_password () with
     | Ok (Some password) ->
       unlock_with_password keyring config password false
     | Ok None -> Error "E2EE password is not cached"
     | Error _ as error -> error)

let load_cached keyring config =
  let graph_id = config.Api.graph_id in
  match Hashtbl.find_opt keyring.keys graph_id with
  | Some key -> Ok key
  | None ->
    (match keyring.load graph_id with
     | Error _ as error -> error
     | Ok (Some key) -> Ok (remember keyring graph_id key)
     | Ok None -> unlock_cached_account keyring config)

let unlock keyring config password =
  unlock_with_password keyring config password true

let provision keyring config =
  let ( let* ) = Result.bind in
  let* body =
    response_body "fetch user E2EE keys"
      (keyring.fetch (Api.user_keys_request config))
  in
  let* user_keys =
    protect "decode user E2EE keys" (fun () -> Api.user_keys_from_body body)
  in
  let* key, encrypted =
    E2ee.prepare_graph_key keyring.crypto user_keys.Api.public_key
  in
  let* _body =
    response_body "upload graph E2EE key"
      (keyring.fetch (Api.upsert_graph_key_request config encrypted))
  in
  remember_graph_key keyring config key

let graph_key keyring graph_id =
  match Hashtbl.find_opt keyring.keys graph_id with
  | Some key -> Ok key
  | None -> Error "encrypted graph is locked"

let encrypt_title keyring graph_id title =
  let ( let* ) = Result.bind in
  let* key = graph_key keyring graph_id in
  E2ee.encrypt_value keyring.crypto key (Transit.String title)

let encrypt_asset keyring graph_id bytes =
  let ( let* ) = Result.bind in
  let* key = graph_key keyring graph_id in
  E2ee.encrypt_bytes keyring.crypto key bytes

let decrypt_title keyring graph_id ciphertext =
  let ( let* ) = Result.bind in
  let* key = graph_key keyring graph_id in
  E2ee.decrypt_string keyring.crypto key ciphertext
