open App_test
open Test_util
module J = Yojson.Basic
module Ds = Datascript
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let result response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true); member "result" response

let multiline_blocks_keep_a_way_to_continue_editing () =
  List.iter (fun backend -> List.iter (fun typ ->
    let app = App.create (backend ()) in
    start app;
    let row = { (journal_outline_row "last" "page" "x^2" "Today" 20261024 0) with Model.row_display_type = Some typ } in
    send app (Model.ApplyCoreSnapshot { (empty_core_projection ()) with
      graph_name = Some "Work"; selected_graph_id = Some "test-graph";
      outliner_rows = [row]; projection_outliner_editing = Some {
        Model.editing_uuid = "last"; editing_title = "x^2"; caret_utf16_offset = 3} });
    flush app;
    let runtime = Lui_app.runtime app in
    check ~msg:("A multiline " ^ typ ^ " editor must leave the following block tappable")
      (descendant_with_identifier runtime (main_root runtime app) "button.outliner.placeholder.page" <> -1)
  ) ["math"; "code"]) [ios_backend; kotlin_backend]

let cases = [case "special block continuation" multiline_blocks_keep_a_way_to_continue_editing]
