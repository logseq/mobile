open Test_util
open Host_update

let settings_fields () =
  match
    decode "settings"
      "{\"appearance\":\"dark\",\"language\":\"zh-CN\",\"spellCheck\":false,\"autoCorrection\":true,\"sidebarTabs\":[\"journals\",\"graphs\"],\"baseURL\":\"https://example.com\",\"version\":\"1.2.3\",\"revision\":\"abc123\"}"
  with
  | Ok (Settings settings) ->
    check_eq "dark" settings.appearance;
    check_eq "zh-CN" settings.language;
    check (not settings.spell_check);
    check settings.auto_correction;
    check_eq [ "journals"; "graphs" ] settings.sidebar_tabs;
    check_eq "https://example.com" settings.base_url;
    check_eq "1.2.3" settings.version;
    check_eq "abc123" settings.revision
  | _ -> check ~msg:"settings update rejected" false

let runtime_log_preserves_unicode_and_newlines () =
  match
    decode "runtime-log"
      "[{\"id\":\"7\",\"level\":\"ERROR\",\"source\":\"ui\",\"timestamp\":\"12:34\",\"message\":\"\xE7\xAC\xAC\xE4\xB8\x80\xE8\xA1\x8C\\nsecond line\"}]"
  with
  | Ok (Runtime_log (entries, _)) ->
    let entry = List.nth entries 0 in
    check_eq 1 (List.length entries);
    check_eq "7" entry.id;
    check_eq "ERROR" entry.level;
    check_eq "ui" entry.source;
    check_eq "12:34" entry.timestamp;
    check_eq "\xE7\xAC\xAC\xE4\xB8\x80\xE8\xA1\x8C\nsecond line" entry.message
  | _ -> check ~msg:"runtime log update rejected" false

let simple_host_updates () =
  check_eq (Ok (Local_graph_ids [ "a"; "b" ]))
    (decode "local-graph-ids" "[\"a\",\"b\"]");
  check_eq (Ok Open_capture) (decode "open-capture" "{}");
  check_eq (Ok (Open_node "journal")) (decode "open-node" "\"journal\"");
  check_eq (Ok (Composer_draft "\xE7\xA8\x8D\xE5\x90\x8E\xE5\xA4\x84\xE7\x90\x86\nsecond line"))
    (decode "composer-draft" "\"\xE7\xA8\x8D\xE5\x90\x8E\xE5\xA4\x84\xE7\x90\x86\\nsecond line\"");
  check_eq (Ok (Graph_loading true)) (decode "graph-loading" "true");
  check_eq (Ok Save_ui_session) (decode "save-ui-session" "null");
  check_eq (Ok (Open_quick_action "capture"))
    (decode "open-quick-action" "\"capture\"")

let authentication_preserves_nullable_error () =
  (match
     decode "authentication"
       "{\"state\":\"signedOut\",\"errorMessage\":\"Authorization was cancelled\"}"
   with
   | Ok (Authentication authentication) ->
     check_eq "signedOut" authentication.state;
     check_eq (Some "Authorization was cancelled") authentication.error_message
   | _ -> check ~msg:"signed-out authentication rejected" false);
  match
    decode "authentication" "{\"state\":\"signedIn\",\"errorMessage\":null}"
  with
  | Ok (Authentication authentication) ->
    check_eq "signedIn" authentication.state;
    check (authentication.error_message = None)
  | _ -> check ~msg:"signed-in authentication rejected" false

let session_restoration_preserves_every_field () =
  match
    decode "restore-ui-session"
      "{\"graphId\":null,\"destination\":\"graphs\",\"assets\":[{\"uuid\":\"a\",\"title\":\"image\",\"localPath\":\"/tmp/a\",\"payload\":\"raw\"}],\"composerExpanded\":true,\"searchOpen\":false,\"query\":\"q\",\"appPath\":[\"p1\",\"p2\"],\"searchPath\":[],\"selectedPageId\":\"p2\",\"settingsOpen\":true}"
  with
  | Ok (Restore_ui_session session) ->
    check (session.graph_id = None);
    check_eq "graphs" session.destination;
    check session.composer_expanded;
    check (not session.search_open);
    check session.settings_open;
    check_eq "q" session.query;
    check_eq (Some "p2") session.selected_page_id;
    check_eq [ "p1"; "p2" ] session.app_path;
    check_eq [] session.search_path;
    check_eq 1 (List.length session.assets);
    let asset = List.nth session.assets 0 in
    check_eq "a" asset.uuid;
    check_eq "image" asset.title;
    check_eq "/tmp/a" asset.local_path;
    check_eq "raw" asset.payload
  | _ -> check ~msg:"session restoration rejected" false

let asset_preserves_original_payload () =
  let payload = "{\"uuid\":\"a\",\"title\":\"image\",\"localPath\":\"/tmp/a\"}" in
  match decode "composer-asset" payload with
  | Ok (Composer_asset asset) -> check_eq payload asset.payload
  | _ -> check ~msg:"composer asset rejected" false

let invalid_updates_are_classified () =
  List.iter
    (fun (kind, payload, prefix) ->
       match decode kind payload with
       | Error message -> check (String.starts_with ~prefix message)
       | Ok _ -> check ~msg:("invalid update accepted: " ^ kind) false)
    [
      ("open-capture", "{", "Invalid host update JSON: ");
      ("graph-loading", "\"yes\"", "Invalid graph-loading host update: ");
      ("settings", "{}", "Invalid settings host update: ");
      ( "local-graph-ids"
      , "[\"a\",1]"
      , "Invalid local-graph-ids host update: " );
      ("unknown", "{}", "Unsupported host update: unknown");
    ]

let cases =
  [
    case "settings fields" settings_fields;
    case "runtime log preserves unicode and newlines"
      runtime_log_preserves_unicode_and_newlines;
    case "simple host updates" simple_host_updates;
    case "authentication preserves nullable error"
      authentication_preserves_nullable_error;
    case "session restoration preserves every field"
      session_restoration_preserves_every_field;
    case "asset preserves original payload" asset_preserves_original_payload;
    case "invalid updates are classified" invalid_updates_are_classified;
  ]
