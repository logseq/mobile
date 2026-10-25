open Test_util
module R = Result_view_test
module Q = Query_block_test
module J = Yojson.Basic
module Ds = Datascript
let member = Q.member
let items = Q.items
let text = R.text
let input app id value =
  let host = Lui_app.runtime app in
  let node = App_test.descendant_with_identifier host (Lui_app.root_node app) id in
  check ~msg:id (node <> -1);
  App_test.dispatch app (Lui_protocol.TextChanged (node, value)); App_test.flush app
let find app id = App_test.descendant_with_identifier (Lui_app.runtime app) (Lui_app.root_node app) id
let click app id =
  let node = find app id in check ~msg:id (node <> -1);
  App_test.dispatch app (Lui_protocol.Press node); App_test.flush app
let prefix part key = "view.filter." ^ part ^ "." ^ R.list_view ^ "." ^ string_of_int key
let set_filters session clauses =
  let response = R.action session (R.base_action "save" R.list_view @ ["config", `Assoc [
    "filters", `Assoc ["or", `Bool false; "clauses", `List clauses]]]) in
  check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true)
let clause attr op value = `List [`String attr; `String op; value]
let with_sheet backend session clauses f =
  set_filters session clauses;
  Q.with_ui backend (Rpc_session.snapshot_visible session) (fun app ->
    click app ("view.filter." ^ R.list_view);
    R.load_property_values session app;
    f app)
let pending app =
  let pending_effect = List.find (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects in
  J.from_string (Native_bridge.encode_effect pending_effect) |> member "text" |> text |> J.from_string
let clauses app = pending app |> member "config" |> member "filters" |> items "clauses"
let save app = click app ("view.settings.save." ^ R.list_view)
let apply session app =
  let response = R.action session (match pending app with `Assoc fields -> fields | _ -> []) in
  check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true)

let operators_match_every_master_property_type () = R.with_runtime (fun session runtime conn ->
  let types = ["default"; "url"; "node"; "date"; "datetime"; "number"; "checkbox"; "page"; "entity"; "class"; "property"; "keyword"] in
  let tx = List.mapi (fun index typ ->
    let uuid = Printf.sprintf "80000000-0000-4000-8000-%012d" index in
    R.entity (400 + index) uuid typ @ [Q.put uuid "db/ident" (Ds.Keyword ("user.property/filter-" ^ typ));
      Q.put uuid "logseq.property/type" (Ds.Keyword typ)]) types
    |> List.fold_left (fun acc tx -> List.rev_append tx acc) [] |> List.rev in
  ignore (Ds.transact_conn conn tx); Graph_runtime.rebase runtime 43 [] [];
  let view = R.find_view R.list_view (R.read session) in
  let property attr = List.find (fun p -> member "attr" p = `String attr) (items "properties" view) in
  List.iter (fun typ ->
    let expected = ["is"; "is-not"] @ (match typ with
      | "default" | "url" | "node" -> ["text-contains"; "text-not-contains"]
      | "date" -> ["date-before"; "date-after"]
      | "datetime" -> ["before"; "after"]
      | "number" -> ["number-gt"; "number-lt"; "number-gte"; "number-lte"; "between"]
      | _ -> []) in
    check_eq ~msg:("master operators for " ^ typ) (items "filterOperators" (property ("user.property/filter-" ^ typ)))
      (List.map (fun value -> `String value) expected)) types;
  List.iter (fun attr ->
    check_eq ~msg:"built-in timestamps expose only Before and After" (items "filterOperators" (property attr)) [`String "before"; `String "after"];
    check_eq (member "filterTimestamp" (property attr)) (`Bool true)) ["block/created-at"; "block/updated-at"])

let recent_objects_shortcut_persists_a_relative_calendar_month () =
  List.iter (fun backend -> R.with_runtime (fun session runtime conn ->
    let now = Dev_query.Date_time_util.time_ms () in
    let month = Dev_query.Date_time_util.minus Months 1 now in
    ignore (Ds.transact_conn conn [Q.put R.alpha "block/created-at" (Ds.Int64 (Int64.sub now 86400000L));
      Q.put R.beta "block/created-at" (Ds.Int64 (Int64.sub month 86400000L));
      Q.put R.gamma "block/created-at" (Ds.Int64 (Int64.sub now 172800000L))]);
    Graph_runtime.rebase runtime 43 [] [];
    with_sheet backend session [] (fun app ->
      click app ("view.filter.recent." ^ R.list_view);
      check ~msg:"the common recent-objects filter has a direct shortcut" (find app (prefix "timestamp" 1) <> -1);
      save app;
      check_eq ~msg:"relative dates stay dynamic in the saved master filter" (clauses app)
        [clause "block/created-at" "after" (`String "1 month ago")];
      apply session app;
      let actual = R.find_view R.list_view (R.read session) |> R.ids |> List.sort compare in
      check_eq actual (List.sort compare [`String R.alpha; `String R.gamma]);
      let saved = R.find_view R.list_view (R.read session) |> member "filters" |> items "filters" in
      check_eq saved [clause "block/created-at" "after" (`String "1 month ago")])))
    [App_test.ios_backend; App_test.kotlin_backend]

let native_inputs_follow_property_and_operator () =
  List.iter (fun backend -> R.with_runtime (fun session _ _ ->
    with_sheet backend session [clause R.score "between" (`List [`Null; `Null])] (fun app ->
      check ~msg:"one compact row owns property and operator" (find app (prefix "row" 0) <> -1);
      input app (prefix "minimum" 0) "bad";
      check ~msg:"invalid numbers have a local recovery hint" (find app (prefix "error" 0) <> -1);
      check_eq ~msg:"invalid numeric drafts cannot be saved"
        (App_test.property_bool (Lui_app.runtime app) (find app ("view.settings.save." ^ R.list_view)) Lui_protocol.Enabled) false;
      input app (prefix "minimum" 0) "15"; input app (prefix "maximum" 0) "25";
      save app; apply session app;
      R.expected_ids [R.alpha] (R.find_view R.list_view (R.read session)));
    with_sheet backend session [clause R.ready "is" `Null] (fun app ->
      click app (prefix "values" 0);
      click app (prefix "choice" 0 ^ ".false"); click app (prefix "values.done" 0);
      save app; check_eq (clauses app) [clause R.ready "is" (`Bool false)]);
    with_sheet backend session [clause R.summary "is" `Null] (fun app ->
      click app (prefix "values" 0);
      input app (prefix "values.search" 0) "search";
      let option = prefix "choice" 0 ^ ".0" in
      check ~msg:"reference/text choices can be searched" (find app option <> -1);
      click app option; click app (prefix "values.done" 0);
      save app;
      check_eq (clauses app) [clause R.summary "is" (`List [`String R.text_a])]);
    with_sheet backend session [clause R.due "date-after" `Null] (fun app ->
      let node = App_test.extension_node app "native-property-date" in
      check ~msg:"date comparisons use the native day picker" (node <> -1);
      Alcotest.(check string) "native day picker kind" "date"
        (match App_test.extension_property app node "kind" with Some (Lui_protocol.StringValue value) -> value | _ -> "missing");
      App_test.dispatch app (Lui_protocol.ExtensionEvent (node, "native-property-date", "change",
        Lui_protocol.String_map.singleton "value" (Lui_protocol.StringValue "2026-10-23")));
      App_test.flush app; save app;
      check_eq (clauses app) [clause R.due "date-after" (`Assoc ["block/journal-day", `Int 20261023])]);
    with_sheet backend session [clause "block/created-at" "after" `Null] (fun app ->
      click app (prefix "preset" 0 ^ ".month");
      click app (prefix "operator" 0 ^ ".before");
      check ~msg:"changing temporal operator resets an incompatible relative value" (find app (prefix "timestamp" 0) <> -1);
      click app (prefix "custom" 0);
      let node = App_test.extension_node app "native-property-date" in
      check ~msg:"custom timestamp uses a datetime picker" (node <> -1);
      check_eq (App_test.extension_property app node "kind") (Some (Lui_protocol.StringValue "datetime"));
      App_test.dispatch app (Lui_protocol.ExtensionEvent (node, "native-property-date", "change",
        Lui_protocol.String_map.singleton "value" (Lui_protocol.StringValue "1792719000000")));
      App_test.flush app; save app;
      check_eq (clauses app) [clause "block/created-at" "before" (`Int 1792719000000)])))
    [App_test.ios_backend; App_test.kotlin_backend]

let changing_properties_and_cancelling_preserve_the_saved_view () =
  List.iter (fun backend -> R.with_runtime (fun session _ _ ->
    with_sheet backend session [clause R.score "number-gt" (`Int 10)] (fun app ->
      click app (prefix "property" 0 ^ "." ^ R.ready);
      check_eq ~msg:"old numeric controls disappear for checkboxes" (find app ("view.filter.value." ^ R.list_view ^ ".0")) (-1);
      click app (prefix "values" 0); click app (prefix "choice" 0 ^ ".empty");
      click app (prefix "values.done" 0);
      click app ("view.settings.cancel." ^ R.list_view);
      check ~msg:"Cancel never submits a view mutation" (not (List.exists (function Model.ResultViewEffect _ -> true | _ -> false) (App.model app).pending_effects));
      let saved = R.find_view R.list_view (R.read session) |> member "filters" |> items "filters" in
      check_eq saved [clause R.score "number-gt" (`Int 10)]))) [App_test.ios_backend; App_test.kotlin_backend]

let cases = [
  case "operators match every master property type" operators_match_every_master_property_type;
  case "recent objects stay relative to a calendar month" recent_objects_shortcut_persists_a_relative_calendar_month;
  case "native filter inputs follow property and operator" native_inputs_follow_property_and_operator;
  case "property changes and Cancel preserve saved configuration" changing_properties_and_cancelling_preserve_the_saved_view;
]
