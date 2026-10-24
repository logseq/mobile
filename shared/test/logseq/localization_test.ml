open App_test
open Test_util
module J = Yojson.Basic
module Ds = Datascript
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let result response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true); member "result" response

let language_settings_translate_controls_without_translating_notes () =
  let app = App.create (kotlin_backend ()) in
  start app;
  send app (Model.ApplyCoreSnapshot { (empty_core_projection ()) with graph_name = Some "Graph";
    selected_graph_id = Some "test-graph"; outliner_rows = [journal_outline_row "note" "page" "Settings" "Today" 20261024 0] });
  send app Model.OpenSettings;
  List.iter (fun (language, system_language, expected) ->
    send app (Model.ApplySettingsSnapshot { (settings []) with Model.language; system_language = Some system_language });
    flush app;
    let runtime = Lui_app.runtime app in
    let root = main_root runtime app in
    check_eq ~msg:"Settings follow the chosen app language"
      (property_string runtime (descendant_with_identifier runtime root "sheet.settings") Lui_protocol.TextValue) expected
  ) ["system", "zh-CN", "设置"; "en", "zh-CN", "Settings"; "zh-CN", "en-US", "设置"; "system", "en-US", "Settings"]

let native_labels_and_desktop_dictionary_share_the_same_locale () =
  List.iter (fun (source, expected) ->
    check_eq ~msg:("System Chinese translation: " ^ source)
      (Localization.translate ~language:"system" ~system_language:"zh-Hans-CN" source) expected)
    ["Settings", "设置"; "Theme", "主题"; "Auto-correction", "自动更正";
     "Export Graph SQLite DB", "导出图谱数据库"; "Unknown note title", "Unknown note title"]

let cases = [case "localization" language_settings_translate_controls_without_translating_notes;
  case "native labels supplement the desktop dictionary" native_labels_and_desktop_dictionary_share_the_same_locale]
