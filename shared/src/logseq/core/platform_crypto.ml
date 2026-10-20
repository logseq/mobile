module Json = Yojson.Basic

let hex value =
  let result = Buffer.create (String.length value * 2) in
  let digits = "0123456789abcdef" in
  String.iter
    (fun ch ->
      let code = Char.code ch in
      Buffer.add_char result digits.[code / 16];
      Buffer.add_char result digits.[code mod 16])
    value;
  Buffer.contents result

let unhex value =
  if String.length value land 1 = 1 then
    Error "platform crypto returned invalid hex"
  else
    try
      let result = Bytes.create (String.length value / 2) in
      for index = 0 to Bytes.length result - 1 do
        Bytes.set result index
          (Char.chr
             (int_of_string
                ("0x" ^ String.sub value (index * 2) 2)))
      done;
      Ok (Bytes.to_string result)
    with _ -> Error "platform crypto returned invalid hex"

let field name fields = Yojson.Basic.Util.member name fields

let invoke call operation fields =
  try
    let request =
      `Assoc ([ ("operation", `String operation) ] @ fields)
    in
    let response = Json.from_string (call (Json.to_string request)) in
    match response with
    | `Assoc _ ->
      (match field "ok" response with
       | `Bool true -> Ok response
       | _ ->
         (match field "error" response with
          | `String message -> Error message
          | _ -> Error "platform crypto failed"))
    | _ -> Error "platform crypto returned invalid JSON"
  with error -> Error (Printexc.to_string error)

let binary_field name fields =
  match field name fields with
  | `String value -> unhex value
  | _ -> Error ("platform crypto response is missing " ^ name)

let crypto call : E2ee.e2ee_crypto =
  {
    generate_rsa_key_pair = (fun () ->
      let ( let* ) = Result.bind in
      let* fields = invoke call "generateRSAKeyPair" [] in
      let* public_key = binary_field "publicKey" fields in
      let* private_key = binary_field "privateKey" fields in
      Ok (public_key, private_key));
    encrypt_private_key = (fun password private_key ->
      let ( let* ) = Result.bind in
      let* fields = invoke call "encryptPrivateKey"
        ["password", `String password; "privateKey", `String (hex private_key)] in
      let* salt = binary_field "salt" fields in
      let* iv = binary_field "iv" fields in
      let* ciphertext = binary_field "ciphertext" fields in
      Ok (salt, iv, ciphertext));
    decrypt_private_key =
      (fun password iterations salt iv ciphertext ->
        let ( let* ) = Result.bind in
        let* fields =
          invoke call "decryptPrivateKey"
            [
              ("password", `String password);
              ("iterations", `Int iterations);
              ("salt", `String (hex salt));
              ("iv", `String (hex iv));
              ("ciphertext", `String (hex ciphertext));
            ]
        in
        binary_field "value" fields);
    decrypt_graph_key =
      (fun private_key ciphertext ->
        let ( let* ) = Result.bind in
        let* fields =
          invoke call "decryptGraphKey"
            [
              ("privateKey", `String (hex private_key));
              ("ciphertext", `String (hex ciphertext));
            ]
        in
        binary_field "value" fields);
    encrypt_graph_key =
      (fun public_key plaintext ->
        let ( let* ) = Result.bind in
        let* fields =
          invoke call "encryptGraphKey"
            [
              ("publicKey", `String (hex public_key));
              ("plaintext", `String (hex plaintext));
            ]
        in
        binary_field "value" fields);
    random_bytes =
      (fun size ->
        let ( let* ) = Result.bind in
        let* fields = invoke call "randomBytes" [ ("count", `Int size) ] in
        binary_field "value" fields);
    encrypt_aes_gcm =
      (fun key plaintext ->
        let ( let* ) = Result.bind in
        let* fields =
          invoke call "encryptAES"
            [
              ("key", `String (hex key));
              ("plaintext", `String (hex plaintext));
            ]
        in
        let* iv = binary_field "iv" fields in
        let* ciphertext = binary_field "ciphertext" fields in
        Ok (iv, ciphertext));
    decrypt_aes_gcm =
      (fun key iv ciphertext ->
        let ( let* ) = Result.bind in
        let* fields =
          invoke call "decryptAES"
            [
              ("key", `String (hex key));
              ("iv", `String (hex iv));
              ("ciphertext", `String (hex ciphertext));
            ]
        in
        binary_field "value" fields);
  }

let save_graph_key call graph_id key =
  let ( let* ) = Result.bind in
  let* _fields =
    invoke call "saveGraphKey"
      [ ("graphID", `String graph_id); ("key", `String (hex key)) ]
  in
  Ok ()

let cached_value fields message =
  let ( let* ) = Result.bind in
  match field "value" fields with
  | `String value ->
    let* decoded = unhex value in
    Ok (Some decoded)
  | `Null -> Ok None
  | _ -> Error message

let load_graph_key call graph_id =
  let ( let* ) = Result.bind in
  let* fields =
    invoke call "loadGraphKey" [ ("graphID", `String graph_id) ]
  in
  cached_value fields "platform crypto returned invalid cached graph key"

let save_e2ee_password call password =
  let ( let* ) = Result.bind in
  let* _fields =
    invoke call "saveE2EEPassword" [ ("password", `String (hex password)) ]
  in
  Ok ()

let load_e2ee_password call =
  let ( let* ) = Result.bind in
  let* fields = invoke call "loadE2EEPassword" [] in
  cached_value fields "platform crypto returned invalid cached E2EE password"

let create_keyring call fetch =
  E2ee_keyring.create (crypto call)
    (fun graph_id -> load_graph_key call graph_id)
    (fun graph_id key -> save_graph_key call graph_id key)
    (fun () -> load_e2ee_password call)
    (fun password -> save_e2ee_password call password)
    fetch
