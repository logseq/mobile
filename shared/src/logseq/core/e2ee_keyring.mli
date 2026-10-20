(** In-memory + persisted graph AES key management for E2EE graphs. *)

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

val create :
  E2ee.e2ee_crypto ->
  (string -> (string option, string) result) ->
  (string -> string -> (unit, string) result) ->
  (unit -> (string option, string) result) ->
  (string -> (unit, string) result) ->
  (Api.api_request -> (Api.api_response, string) result) ->
  e2ee_keyring
val response_body :
  string -> (Api.api_response, string) result -> (string, string) result
val protect : string -> (unit -> 'a) -> ('a, string) result
val unlock_with_private_key :
  e2ee_keyring -> Api.api_config -> string -> (string, string) result
val unlock_with_password :
  e2ee_keyring -> Api.api_config -> string -> bool -> (string, string) result
val unlock_cached_account :
  e2ee_keyring -> Api.api_config -> (string, string) result
val load_cached : e2ee_keyring -> Api.api_config -> (string, string) result
val unlock : e2ee_keyring -> Api.api_config -> string -> (string, string) result
val provision : e2ee_keyring -> Api.api_config -> (string, string) result
val graph_key : e2ee_keyring -> string -> (string, string) result
val encrypt_title :
  e2ee_keyring -> string -> string -> (string, string) result
val encrypt_asset :
  e2ee_keyring -> string -> string -> (string, string) result
val decrypt_title :
  e2ee_keyring -> string -> string -> (string, string) result

val password_required_message : string
val ensure_user_keys : e2ee_keyring -> Api.api_config -> string option -> (unit, string) result
