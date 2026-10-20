module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type e2ee_crypto =
  { generate_rsa_key_pair : unit -> (string * string, string) result
  ; encrypt_private_key : string -> string -> (string * string * string, string) result
  ; decrypt_private_key :
      string -> int -> string -> string -> string -> (string, string) result
  ; decrypt_graph_key : string -> string -> (string, string) result
  ; encrypt_graph_key : string -> string -> (string, string) result
  ; random_bytes : int -> (string, string) result
  ; encrypt_aes_gcm : string -> string -> (string * string, string) result
  ; decrypt_aes_gcm : string -> string -> string -> (string, string) result
  }

type e2ee_private_key_package =
  { iterations : int
  ; salt : string
  ; iv : string
  ; ciphertext : string
  }

let protect operation f =
  try Ok (f ()) with
  | Value.Decode_error message -> Error (operation ^ ": " ^ message)
  | Failure message -> Error (operation ^ ": " ^ message)
  | Invalid_argument message -> Error (operation ^ ": " ^ message)
  | error -> Error (operation ^ ": " ^ Printexc.to_string error)

let private_key_package source =
  let ( let* ) = Result.bind in
  let* value =
    protect "decode encrypted private key" (fun () -> Codec.of_string source)
  in
  match value with
  | Value.Array
      [ Value.String version; Value.Binary salt; Value.Binary iv;
        Value.Binary ciphertext ] ->
    Ok
      {
        iterations =
          (if String.compare version "20251210" >= 0 then 600000 else 100000);
        salt;
        iv;
        ciphertext;
      }
  | Value.Array [ Value.Binary salt; Value.Binary iv; Value.Binary ciphertext ]
    ->
    Ok { iterations = 100000; salt; iv; ciphertext }
  | _ -> Error "encrypted private key has an invalid Transit envelope"

let binary source =
  let ( let* ) = Result.bind in
  let* value =
    protect "decode encrypted graph key" (fun () -> Codec.of_string source)
  in
  match value with
  | Value.Binary value -> Ok value
  | _ -> Error "encrypted graph key is not Transit binary"

let prepare_graph_key crypto public_key_package =
  let ( let* ) = Result.bind in
  let* public_key = binary public_key_package in
  let* graph_key = crypto.random_bytes 32 in
  let* encrypted = crypto.encrypt_graph_key public_key graph_key in
  Ok (graph_key, Codec.to_string (Value.Binary encrypted))

let decrypt_private_key crypto password private_source =
  let ( let* ) = Result.bind in
  let* package = private_key_package private_source in
  crypto.decrypt_private_key password package.iterations package.salt
    package.iv package.ciphertext

let decrypt_graph_key crypto private_key encrypted_graph_key =
  let ( let* ) = Result.bind in
  let* ciphertext = binary encrypted_graph_key in
  crypto.decrypt_graph_key private_key ciphertext

let unlock_graph_key crypto password private_source encrypted_graph_key =
  let ( let* ) = Result.bind in
  let* private_key = decrypt_private_key crypto password private_source in
  decrypt_graph_key crypto private_key encrypted_graph_key

let encrypt_bytes crypto graph_key plaintext =
  let ( let* ) = Result.bind in
  let* iv, ciphertext = crypto.encrypt_aes_gcm graph_key plaintext in
  Ok (Codec.to_string (Value.Array [ Value.Binary iv; Value.Binary ciphertext ]))

let decrypt_bytes crypto graph_key source =
  match (try Some (Codec.of_string source) with _ -> None) with
  | Some (Value.Array [ Value.Binary iv; Value.Binary ciphertext ]) ->
    crypto.decrypt_aes_gcm graph_key iv ciphertext
  | _ -> Error "Asset has an invalid Transit AES-GCM envelope"

let encrypt_value crypto graph_key value =
  let ( let* ) = Result.bind in
  let plaintext = Codec.to_string value in
  let* iv, ciphertext = crypto.encrypt_aes_gcm graph_key plaintext in
  Ok (Codec.to_string (Value.Array [ Value.Binary iv; Value.Binary ciphertext ]))

let decrypt_value crypto graph_key source =
  let decoded = try Some (Codec.of_string source) with _ -> None in
  match decoded with
  | None -> Ok (Value.String source)
  | Some (Value.Array [ Value.Binary iv; Value.Binary ciphertext ]) ->
    let ( let* ) = Result.bind in
    let* plaintext = crypto.decrypt_aes_gcm graph_key iv ciphertext in
    protect "decode decrypted value" (fun () -> Codec.of_string plaintext)
  | Some (Value.Array (_ :: _ :: _)) ->
    Error "encrypted value has an invalid Transit AES-GCM envelope"
  | Some (Value.String value) ->
    (try Ok (Codec.of_string value) with _ -> Ok (Value.String value))
  | Some value -> Ok value

let decrypt_string crypto graph_key source =
  let ( let* ) = Result.bind in
  let* value = decrypt_value crypto graph_key source in
  match value with
  | Value.String value -> Ok value
  | _ -> Error "decrypted protected value is not a string"

let prepare_user_keys crypto password =
  let ( let* ) = Result.bind in
  let* public_key, private_key = crypto.generate_rsa_key_pair () in
  let* salt, iv, ciphertext = crypto.encrypt_private_key password private_key in
  Ok (Codec.to_string (Value.Binary public_key),
      Codec.to_string (Value.Array [Value.String "20251210"; Value.Binary salt;
                                   Value.Binary iv; Value.Binary ciphertext]))
