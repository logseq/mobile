open Test_util
module J = Yojson.Basic
module Ds = Datascript
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let result response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true); member "result" response

let code_language_can_be_changed_and_cleared () = R.with_runtime (fun session runtime conn ->
  Editor_command_test.rebase runtime conn [Q.put Q.alpha "logseq.property.node/display-type" (Ds.Keyword "code")];
  List.iter (fun language ->
    ignore (result (Rpc_test.dispatch_json session "nodeProperty" (J.to_string (`Assoc [
      "action", `String "setCodeLanguage"; "blockUuid", `String Q.alpha; "value", `String language]))));
    let id = Option.get (Ds.entid (Graph_runtime.db runtime) "block/uuid" (Ds.Uuid Q.alpha)) in
    check_eq (Graph_read.value (Graph_runtime.db runtime) id "logseq.property.code/lang")
      (if language = "" then None else Some (Ds.String language))
  ) ["python"; "ocaml"; ""];
  check_eq (member "ok" (Rpc_test.dispatch_json session "nodeProperty" (J.to_string (`Assoc [
    "action", `String "setCodeLanguage"; "blockUuid", `String Q.beta; "value", `String "python"])))) (`Bool false))

let code_commands_keep_one_block_and_its_language_control () =
  List.iter (fun backend -> List.iter (fun label -> R.with_runtime (fun session runtime _ ->
    let block_ids () = Graph_runtime.blocks_for_page runtime Q.page
      |> List.map (fun (block : Cache_model.block) -> block.uuid) |> List.sort compare in
    let before = block_ids () in
    ignore (Editor_command_test.run session label);
    check_eq ~msg:"A code command on an empty draft converts the existing block" (block_ids ()) before;
    check_eq (Editor_command_test.value runtime Q.alpha "block/title") (Some (Ds.String ""));
    check_eq (Editor_command_test.value runtime Q.alpha "logseq.property.node/display-type") (Some (Ds.Keyword "code"));
    let inspect ~editing =
      Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
        App_test.send app (Model.ChooseSettingsLanguage "zh-CN"); App_test.flush app;
        let host = Lui_app.runtime app in
        let owner = App_test.descendant_with_identifier host (Lui_app.root_node app) ("outliner.block." ^ Q.alpha) in
        if owner <> -1 && App_test.native_row app owner <> -1 then (
          let payload = App_test.native_row_payload app owner in
          check_eq ~msg:"Native rows distinguish an editor from a code preview child"
            (member "editing" payload) (`Bool editing));
        let panel = App_test.descendant_with_identifier host (Lui_app.root_node app) ("outliner.code." ^ Q.alpha) in
        check ~msg:"The language selector belongs to the code surface, rather than a separate prose row" (panel <> -1);
        let language = App_test.descendant_with_identifier host panel ("button.outliner.code-language." ^ Q.alpha) in
        check ~msg:"The code surface retains its language menu" (language <> -1);
        check_eq ~msg:"Code mode names remain English in a Chinese app"
          (App_test.property_string host language Lui_protocol.TextValue) (if label = "Calculator" then "calc" else "Plain text");
        let calculator = App_test.descendant_with_identifier host language "button.outliner.code-language.option.calc" in
        check_eq ~msg:"The Calculator code mode is not localized"
          (App_test.property_string host calculator Lui_protocol.TextValue) "Calculator";
        check_eq ~msg:"The language header shares a visible code container background"
          (App_test.property_string host panel Lui_protocol.BackgroundValue) "code-container";
        let header = App_test.descendant_with_identifier host panel ("outliner.code.language-header." ^ Q.alpha) in
        check_eq ~msg:"Code mode stays in the left corner"
          (App_test.property_string host header Lui_protocol.MainAlignment) "start";
        check_eq ~msg:"The language selector is a compact caption"
          (App_test.property_string host language Lui_protocol.StyleClass) "caption";
        if editing then
          check ~msg:"The same code surface contains the active editor"
            (App_test.descendant_with_extension host app panel "outliner-editor" <> -1)
        else (
          let content = App_test.descendant_with_identifier host panel ("outliner.code.content." ^ Q.alpha) in
          check ~msg:"The code surface retains a tappable rendered body" (content <> -1);
          App_test.dispatch app (Lui_protocol.Press content); App_test.flush app;
          check ~msg:"Tapping code reopens that block's editor"
            (List.exists (function Model.TapOutlinerBlockEffect (_, uuid) -> uuid = Q.alpha | _ -> false)
              (App.model app).pending_effects));
        let option = App_test.descendant_with_identifier host language "button.outliner.code-language.option.python" in
        App_test.dispatch app (Lui_protocol.Press option); App_test.flush app;
        check ~msg:"The embedded language menu still updates the same code block"
          (List.exists (function Model.NodePropertyEffect (_, uuid, payload) ->
            uuid = Q.alpha && member "value" (J.from_string payload) = `String "python" | _ -> false)
            (App.model app).pending_effects)) in
    inspect ~editing:true;
    ignore (Editor_command_test.type_at session "print(42)" 9);
    Editor_command_test.save session;
    ignore (Editor_command_test.event session "cancelEditing" []);
    inspect ~editing:false;
    ignore (Editor_command_test.event session "longPressBlock" ["uuid", `String Q.alpha]);
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      let panel = App_test.descendant_with_identifier host (Lui_app.root_node app) ("outliner.code." ^ Q.alpha) in
      check_eq ~msg:"A selected code surface lets the block selection highlight show through"
        (App_test.property_string host panel Lui_protocol.BackgroundValue) "#00000000";
      check ~msg:"Code and Calculator long press expose block selection actions"
        (App_test.descendant_with_identifier host (Lui_app.root_node app) "button.outliner.selection.copy" <> -1));
    check_eq ~msg:"Finishing code editing does not add a language block" (block_ids ()) before))
    ["Code block"; "Calculator"]) [App_test.ios_backend; App_test.kotlin_backend]

let calculator_results_follow_the_unsaved_editor () =
  List.iter (fun backend -> R.with_runtime (fun session runtime _ ->
    ignore (Editor_command_test.run session "Calculator");
    Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
      let host = Lui_app.runtime app in
      List.iter (fun (source, expected) ->
        App_test.send app (Model.ChangeOutlinerText (Q.alpha, source, Outliner_state.utf16_length source));
        App_test.flush app;
        let layout = App_test.descendant_with_identifier host (Lui_app.root_node app) ("outliner.calculator." ^ Q.alpha) in
        check_eq ~msg:"Calculator expressions and results use a horizontal layout"
          (App_test.node host layout) (Some Lui_protocol.Row);
        let results = App_test.descendant_with_identifier host layout ("outliner.calculator.results." ^ Q.alpha) in
        check_eq ~msg:"The right column recalculates before saving or waiting for the core"
          (App_test.property_string host results Lui_protocol.TextValue) expected;
        let editor = App_test.descendant_with_extension host app layout "outliner-editor" in
        check_eq ~msg:"The left editor retains only the source expressions"
          (App_test.extension_property app editor "title") (Some (Lui_protocol.StringValue source));
        check_eq ~msg:"A live calculation does not persist an intermediate draft"
          (Editor_command_test.value runtime Q.alpha "block/title") (Some (Ds.String "")))
        ["6*7\nlast*3", "42\n126"; "a=2\n\n# comment\na*3", "2\n\n\n6";
         "2*3\ninvalid(2)\nlast*2\n4", "6\nError\nError\n4"; "", ""])))
    [App_test.ios_backend; App_test.kotlin_backend]

let cases = [case "calculator results follow the unsaved editor" calculator_results_follow_the_unsaved_editor;
  case "code language" code_language_can_be_changed_and_cleared;
  case "code command keeps its language control inside the block" code_commands_keep_one_block_and_its_language_control]
