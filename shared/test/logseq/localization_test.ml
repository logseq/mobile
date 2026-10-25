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

let tag_and_property_editors_use_desktop_translations () =
  List.iter (fun (language, tags, properties, open_named) ->
    let translate source = Localization.translate ~language ~system_language:"en" source in
    check_eq (translate "Set tags") tags;
    check_eq (translate "Tag properties") properties;
    check_eq (translate "Open {1}") open_named)
    ["zh-CN", "设置标签", "标签属性", "打开 {1}";
     "zh-Hant", "設定標籤", "標籤屬性", "開啟 {1}";
     "ja", "タグを設定", "タグプロパティ", "{1}を開く"]

let builtin_property_titles_use_master_identifiers () =
  let translate source = Localization.translate ~language:"zh-CN" ~system_language:"en" source in
  check_eq (translate "property.built-in/assignee") "负责人";
  check_eq (translate "property.built-in/status") "状态";
  check_eq (translate "property.built-in/class-properties") "标签属性";
  let current = { (Model.initial ()) with language = "zh-CN" } in
  check_eq (View_base.property_title current ~attr:"logseq.property.class/properties" ~title:"Properties") "标签属性";
  check_eq ~msg:"user property names are not translated"
    (View_base.property_title current ~attr:"user.property/Status" ~title:"Status") "Status"

let native_search_controls_receive_translated_labels () =
  List.iter (fun backend ->
    let app = App.create (backend ()) in
    start app;
    send app (Model.SelectGraph "Work");
    send app (Model.ApplySettingsSnapshot { (settings []) with Model.language = "zh-CN" });
    send app Model.OpenSearch;
    flush app;
    let search = extension_node app "native-search-presentation" in
    List.iter (fun (name, expected) ->
      check_eq ~msg:("native search localizes " ^ name)
        (extension_property app search name) (Some (Lui_protocol.StringValue expected)))
      ["back-title", "返回"; "close-title", "关闭"; "clear-title", "清空"])
    [ios_backend; kotlin_backend]

let cases = [case "native search controls receive translated labels" native_search_controls_receive_translated_labels;
  case "localization" language_settings_translate_controls_without_translating_notes;
  case "tag and property editors use desktop translations" tag_and_property_editors_use_desktop_translations;
  case "built-in property titles use master identifiers" builtin_property_titles_use_master_identifiers;
  case "native labels supplement the desktop dictionary" native_labels_and_desktop_dictionary_share_the_same_locale]
