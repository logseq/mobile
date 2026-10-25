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

let property_titles_preserve_graph_names () =
  List.iter (fun language ->
    let current = { (Model.initial ()) with language; system_language = "zh-CN" } in
    List.iter (fun (attr, title) ->
      check_eq ~msg:("property titles preserve graph names: " ^ attr)
        (View_base.property_title current ~attr ~title) title)
      ["logseq.property/assignee", "Assignee"; "logseq.property/status", "Status";
       "logseq.property.class/properties", "Properties"; "block/tags", "Tags";
       "user.property/Status", "Status"; "logseq.property/status", "Workflow 状态";
       "logseq.property/custom", "Custom"; "user.property/Empty", ""])
    ["system"; "zh-CN"; "ja"; "en"]

let native_property_labels_and_editors_preserve_graph_names () =
  let db = Ds.db_with [Q.put Q.project "logseq.property.class/properties"
    (Ds.Ref_to (Ds.Ident "logseq.property/description"))] (R.fixture ()) in
  let session, _ = R.make_session db in
  let properties = member "nodeProperties" (result (Rpc_test.dispatch_json session "nodeProperties" Q.alpha)) in
  let property = List.find (fun value -> member "attr" value = `String "logseq.property/description")
    (Q.items "properties" properties) in
  let title = R.text (member "title" property) in
  let response = J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
    "selectedGraphId", `String "test-graph"; "selectedPage", `Assoc [
      "uuid", `String Q.alpha; "title", `String "Alpha"];
    "nodeProperties", properties; "outlinerRows", `List []]]) in
  List.iter (fun backend -> Q.with_ui backend response (fun app ->
    send app (Model.ApplySettingsSnapshot { (settings []) with Model.language = "zh-CN" });
    flush app;
    let runtime = Lui_app.runtime app in
    let find id = descendant_with_identifier runtime (Lui_app.root_node app) id in
    let click id = let node = find id in check ~msg:id (node <> -1);
      dispatch app (Lui_protocol.Press node); flush app in
    if find ("properties.expand." ^ Q.alpha) <> -1 then click ("properties.expand." ^ Q.alpha);
    let suffix = Q.alpha ^ ".logseq.property/description" in
    check_eq ~msg:"native property label preserves its graph title"
      (property_string runtime (find ("property.label." ^ suffix)) Lui_protocol.TextValue) title;
    click ("property.value." ^ suffix);
    check_eq ~msg:"property editor preserves the same graph title"
      (property_string runtime (find ("view.edit.sheet.property." ^ suffix)) Lui_protocol.TextValue) title;
    check_eq ~msg:"editor actions remain localized"
      (property_string runtime (find ("view.edit.cancel.property." ^ suffix)) Lui_protocol.TextValue) "取消"))
    [ios_backend; kotlin_backend]

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

let confirmation_cancel_actions_are_semantic_and_localized () =
  List.iter (fun backend -> List.iter (fun language ->
    List.iter (fun (identifier, request) ->
      let app = App.create (backend ()) in
      let local = graph "local" "Local graph" false true in
      start app;
      send app (Model.ApplyCoreSnapshot { (empty_core_projection ()) with
        graphs = [local]; selected_graph_id = Some "local";
        sidebar = { (empty_sidebar_projection ()) with
          selected_page = Some {Model.uuid = "page"; title = "Project"} } });
      send app (Model.ApplyLocalGraphIds ["local"]);
      send app (Model.ApplySettingsSnapshot { (settings []) with Model.language = language });
      send app request;
      flush app;
      let runtime = Lui_app.runtime app in
      let cancel = descendant_with_identifier runtime (Lui_app.root_node app) identifier in
      check ~msg:("dialog exposes its cancellation action: " ^ identifier) (cancel <> -1);
      check_eq ~msg:"cancel labels remain localized"
        (property_string runtime cancel Lui_protocol.TextValue)
        (Localization.translate ~language ~system_language:"en" "Cancel");
      check ~msg:"native cancellation is explicit rather than inferred from translated text"
        (String.split_on_char ' ' (property_string runtime cancel Lui_protocol.StyleClass)
         |> List.mem "cancellation-action");
      dispatch app (Lui_protocol.Press cancel); flush app;
      check_eq ~msg:"cancelling never deletes a graph or page"
        (List.filter (function Model.DeleteLocalGraphEffect _ | Model.DeletePageEffect _ -> true | _ -> false)
          (App.model app).pending_effects) [])
      ["button.graph-delete.cancel", Model.RequestDeleteGraph "local";
       "button.page-delete.cancel", Model.RequestDeleteActivePage;
       "button.sign-out.cancel", Model.RequestSignOut])
    ["en"; "zh-CN"; "ja"]) [ios_backend; kotlin_backend]

let cases = [case "confirmation cancel actions are semantic and localized" confirmation_cancel_actions_are_semantic_and_localized;
  case "native search controls receive translated labels" native_search_controls_receive_translated_labels;
  case "localization" language_settings_translate_controls_without_translating_notes;
  case "tag and property editors use desktop translations" tag_and_property_editors_use_desktop_translations;
  case "property titles preserve graph names" property_titles_preserve_graph_names;
  case "native property labels and editors preserve graph names" native_property_labels_and_editors_preserve_graph_names;
  case "native labels supplement the desktop dictionary" native_labels_and_desktop_dictionary_share_the_same_locale]
