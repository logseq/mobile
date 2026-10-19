open Test_util

module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json
module Payload = Mobile_payload

let open_fields =
  "\"graphId\":\"g\",\"activePath\":\"graph.sqlite\",\"checkpointPath\":\"sync.checkpoint\""

let open_graph_preserves_fields_and_encryption_default () =
  List.iter
    (fun (suffix, encrypted) ->
      match
        Payload.decode_open ("{" ^ open_fields ^ suffix ^ "}")
      with
      | Ok (request : Payload.open_graph_request) ->
        check_eq "g" request.graph_id;
        check_eq "graph.sqlite" request.active_path;
        check_eq "sync.checkpoint" request.checkpoint_path;
        check_eq encrypted request.e2ee
      | Error _ -> check false)
    [ ("", false); (",\"isEncrypted\":false", false)
    ; (",\"isEncrypted\":true", true) ]

let explicit_null_is_not_an_absent_encryption_flag () =
  List.iter
    (fun value ->
      check_eq
        (Error "graph sync payload requires a boolean isEncrypted")
        (Payload.decode_open
           ("{" ^ open_fields ^ ",\"isEncrypted\":" ^ value ^ "}")))
    [ "null"; "0"; "\"true\""; "[]"; "{}" ];
  check_eq (Error "graph sync payload requires graphId")
    (Payload.decode_open "{\"isEncrypted\":null}")

let required_paths_preserve_validation_order () =
  List.iter
    (fun (body, field) ->
      check_eq
        (Error ("graph sync payload requires " ^ field))
        (Payload.decode_open body))
    [
      ("{}", "graphId");
      ("{\"graphId\":\"\"}", "graphId");
      ("{\"graphId\":1}", "graphId");
      ("{\"graphId\":\"g\"}", "activePath");
      ("{\"graphId\":\"g\",\"activePath\":\"a\"}", "checkpointPath");
    ]

let snapshot_import_validates_download_before_encryption () =
  check_eq
    (Error "graph sync payload requires metadataBody")
    (Payload.decode_import ("{" ^ open_fields ^ ",\"isEncrypted\":null}"));
  check_eq
    (Error "graph sync payload requires downloadPath")
    (Payload.decode_import
       ("{" ^ open_fields ^ ",\"metadataBody\":\"{}\",\"isEncrypted\":null}"));
  match
    Payload.decode_import
      ("{" ^ open_fields
      ^ ",\"metadataBody\":\"{}\",\"downloadPath\":\"download.bin\",\"isEncrypted\":true}")
  with
  | Ok (request : Payload.import_snapshot_request) ->
    check_eq "g" request.graph_id;
    check_eq "{}" request.metadata_body;
    check_eq "download.bin" request.download_path;
    check request.e2ee
  | Error _ -> check false

let graph_commands_reject_non_object_and_malformed_json () =
  List.iter
    (fun body ->
      check_eq (Error "openGraph payload must be an object")
        (Payload.decode_open body);
      check_eq (Error "importSnapshot payload must be an object")
        (Payload.decode_import body))
    [ "null"; "[]"; "42"; "\"text\"" ];
  (match Payload.decode_open "{" with
   | Error message -> check (String.contains message 'J')
   | Ok _ -> check false);
  (match Payload.decode_import "{" with
   | Error message -> check (String.length message > 0)
   | Ok _ -> check false)

let sync_event_envelope_preserves_validation_order () =
  List.iter (fun body -> check_error (Payload.decode_sync_event body))
    [ "null"; "[]"; "{}"; "{\"type\":\"pull/ok\",\"t\":-1,\"txs\":[]}" ];
  check_ok (Payload.decode_sync_event "{\"type\":\"pull/ok\",\"t\":42,\"txs\":[]}")

let database_open_preserves_path_without_requiring_api_version () =
  check_eq (Some "graph.sqlite")
    (Payload.database_open_path
       "{\"method\":\"open\",\"params\":{\"path\":\"graph.sqlite\"}}");
  check_eq (Some "")
    (Payload.database_open_path
       "{\"apiVersion\":1,\"method\":\"open\",\"params\":{\"path\":\"\"}}")

let database_open_ignores_other_requests_and_invalid_envelopes () =
  List.iter
    (fun body -> check_eq None (Payload.database_open_path body))
    [
      "{";
      "null";
      "[]";
      "{}";
      "{\"method\":\"snapshot\",\"params\":{\"path\":\"graph.sqlite\"}}";
      "{\"method\":\"open\"}";
      "{\"method\":\"open\",\"params\":null}";
      "{\"method\":\"open\",\"params\":{}}";
      "{\"method\":\"open\",\"params\":{\"path\":null}}";
      "{\"method\":\"open\",\"params\":{\"path\":42}}";
      "{\"method\":\"open\",\"params\":{\"path\":[]}}";
    ]

let database_open_uses_the_first_duplicate_field () =
  check_eq (Some "first.sqlite")
    (Payload.database_open_path
       "{\"method\":\"open\",\"params\":{\"path\":\"first.sqlite\",\"path\":\"second.sqlite\"}}");
  check_eq None
    (Payload.database_open_path
       "{\"method\":null,\"method\":\"open\",\"params\":{\"path\":\"graph.sqlite\"}}");
  check_eq None
    (Payload.database_open_path
       "{\"method\":\"open\",\"params\":null,\"params\":{\"path\":\"graph.sqlite\"}}");
  check_eq None
    (Payload.database_open_path
       "{\"method\":\"open\",\"params\":{\"path\":null,\"path\":\"graph.sqlite\"}}")

let cases =
  [
    case "open graph preserves fields and encryption default"
      open_graph_preserves_fields_and_encryption_default;
    case "explicit null is not an absent encryption flag"
      explicit_null_is_not_an_absent_encryption_flag;
    case "required paths preserve validation order"
      required_paths_preserve_validation_order;
    case "snapshot import validates download before encryption"
      snapshot_import_validates_download_before_encryption;
    case "graph commands reject non-object and malformed json"
      graph_commands_reject_non_object_and_malformed_json;
    case "sync event envelope preserves validation order"
      sync_event_envelope_preserves_validation_order;
    case "database open preserves path without requiring api version"
      database_open_preserves_path_without_requiring_api_version;
    case "database open ignores other requests and invalid envelopes"
      database_open_ignores_other_requests_and_invalid_envelopes;
    case "database open uses the first duplicate field"
      database_open_uses_the_first_duplicate_field;
  ]
