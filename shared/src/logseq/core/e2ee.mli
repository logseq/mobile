(** E2EE key package decoding and graph-key value (de|en)cryption helpers. *)

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

val protect : string -> (unit -> 'a) -> ('a, string) result
val private_key_package : string -> (e2ee_private_key_package, string) result
val binary : string -> (string, string) result
val prepare_graph_key :
  e2ee_crypto -> string -> (string * string, string) result
val decrypt_private_key :
  e2ee_crypto -> string -> string -> (string, string) result
val decrypt_graph_key :
  e2ee_crypto -> string -> string -> (string, string) result
val unlock_graph_key :
  e2ee_crypto -> string -> string -> string -> (string, string) result
val encrypt_value :
  e2ee_crypto -> string -> Transit_core.Json.value -> (string, string) result
val decrypt_value :
  e2ee_crypto -> string -> string -> (Transit_core.Json.value, string) result
val decrypt_string :
  e2ee_crypto -> string -> string -> (string, string) result

val encrypt_bytes : e2ee_crypto -> string -> string -> (string, string) result
val decrypt_bytes : e2ee_crypto -> string -> string -> (string, string) result

val prepare_user_keys : e2ee_crypto -> string -> (string * string, string) result
