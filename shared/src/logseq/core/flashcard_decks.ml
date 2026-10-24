module D = Datascript
module G = Graph_read
module Ops = Pending_ops

type state = {
  graph_id : string option;
  selected : string option;
  choices : Cache_model.entity_summary list;
  target_kind : string;
  target_query : string;
  targets : Cache_model.entity_summary list;
  created : string option;
  error : string option;
}

let empty = {graph_id = None; selected = None; choices = []; target_kind = "page";
  target_query = ""; targets = []; created = None; error = None}
let for_graph graph_id state = if state.graph_id = graph_id then state else {empty with graph_id}
let to_yojson state =
  let optional = function Some value -> `String value | None -> `Null in
  let summaries values = `List (List.map (fun (v : Cache_model.entity_summary) ->
    `Assoc ["uuid", `String v.uuid; "title", `String v.title]) values) in
  `Assoc ["selectedUuid", optional state.selected; "items", summaries state.choices;
    "createdUuid", optional state.created; "error", optional state.error;
    "targetSearch", `Assoc ["kind", `String state.target_kind; "query", `String state.target_query;
      "items", summaries state.targets]]

let choices db =
  match D.entid db "db/ident" (D.Keyword "logseq.class/Cards") with
  | None -> []
  | Some root ->
    let seen = Hashtbl.create 16 in
    G.class_descendants db root |> List.concat_map (fun tag ->
      Datascript_value.datoms_by_ref db D.Aevt "block/tags" tag |> Seq.filter_map (fun (d : D.datom) ->
        if Hashtbl.mem seen d.e || G.page_is_hidden db d.e then None else begin
          Hashtbl.add seen d.e ();
          Option.bind (G.entity_summary (fun s -> Ok s) db d.e) (fun summary ->
            let title = if String.trim summary.title <> "" then summary.title else
              match G.ref_eids db d.e "logseq.property/query" with
              | source :: _ -> G.display_title (fun s -> Ok s) db
                  (Option.value ~default:"" (G.entity_title (fun s -> Ok s) db source))
              | [] -> "" in
            if String.trim title = "" then None else Some {summary with title})
        end) |> List.of_seq)
    |> List.sort (fun (a : Cache_model.entity_summary) b -> compare (a.title, a.uuid) (b.title, b.uuid))

let due_cards db now uuid =
  match D.entid db "block/uuid" (D.Uuid uuid) with
  | None -> Error "This card group is no longer available"
  | Some id when not (G.entity_is_instance_of db id "logseq.class/Cards") || G.page_is_hidden db id ->
    Error "This node is not an available card group"
  | Some id ->
    let source = match G.ref_eids db id "logseq.property/query" with
      | definition :: _ -> Option.value ~default:"" (G.entity_title (fun s -> Ok s) db definition)
      | [] -> "" in
    if String.trim source = "" then Ok (Flashcards.due_cards db now)
    else try
      let opts : Dev_query.Db_query_dsl.exec_opts = {
        opt_cards = true; opt_block_attrs = Some "[:db/id]"; opt_current_page_title = None;
        opt_today_day = Dev_query.Time.local_date_of_journal_day (Dev_query.Time.local_tz ())
          (Cache_model.journal_day_for_ms now)} in
      match Dev_query.Db_query_dsl.execute_query db source opts with
      | None -> Error "This card group has an invalid query"
      | Some rows ->
        let matched = Hashtbl.create (List.length rows) in
        List.iter (function
          | [D.Result_entity eid] -> Hashtbl.replace matched eid ()
          | [D.Result_pull entity] -> Hashtbl.replace matched entity.D.pulled_id ()
          | _ -> ()) rows;
        Ok (Flashcards.due_cards ~include_eid:(Hashtbl.mem matched) db now)
    with Invalid_argument message | Failure message -> Error message
       | _ -> Error "This card group's query could not be evaluated"

let target_allowed db kind id =
  not (G.page_is_hidden db id) && match kind with
  | "page" -> Node_title.is_page db id
  | "tag" -> Node_title.is_class db id
  | _ -> false

let search_targets db ~kind ~query ~search =
  let candidates = if kind = "tag" then G.tag_pages (fun s -> Ok s) db else
    if String.trim query = "" then
      D.Db.datoms db D.Avet ~a:"block/name" () |> Seq.filter_map (fun (d : D.datom) ->
        if target_allowed db kind d.e then G.entity_summary (fun s -> Ok s) db d.e else None)
      |> Seq.take 20 |> List.of_seq
    else search query |> List.filter_map (fun (hit : Search_index.indexed_search_hit) ->
      Option.bind (D.entid db "block/uuid" (D.Uuid hit.uuid)) (fun eid ->
        if target_allowed db kind eid then G.entity_summary (fun s -> Ok s) db eid else None)) in
  let query = Dev_query.Unicode.lowercase (String.trim query) in
  candidates |> List.filter (fun (v : Cache_model.entity_summary) ->
    String_kit.includes ~sub:query (Dev_query.Unicode.lowercase v.title))
  |> List.sort_uniq compare |> List.to_seq |> Seq.take 20 |> List.of_seq

let create db ~now ~kind ~target ~title ~fresh_uuid =
  let ( let* ) = Result.bind in
  let title = String.trim title in
  if title = "" then Error "Enter a card group name"
  else match D.entid db "block/uuid" (D.Uuid target) with
  | None -> Error "The selected page or tag is no longer available"
  | Some target_eid when not (target_allowed db kind target_eid) -> Error "Select a valid page or tag"
  | Some _ ->
    let uuid = fresh_uuid () in
    let definition = fresh_uuid () in
    let day = Cache_model.journal_day_for_ms now in
    let* insert = match G.journal_page_uuid db day with
      | None -> Ok (Ops.Create_journal {page_uuid = Journal.page_uuid day; block_uuid = uuid;
          block_title = title; title = Journal.title db day; journal_day = day; created_at = now})
      | Some page_uuid ->
        let parent = Option.get (D.entid db "block/uuid" (D.Uuid page_uuid)) in
        let lower = Datascript_value.datoms_by_ref db D.Aevt "block/parent" parent |> Seq.fold_left (fun lower (d : D.datom) ->
          match lower, G.string_value (G.value db d.e "block/order") with
          | None, value -> value | value, None -> value | Some a, Some b -> Some (max a b)) None in
        let* order = Fractional_order.between lower None in
        Ok (Ops.Insert_block {uuid; title; page_uuid; parent_uuid = page_uuid; order; created_at = now}) in
    let source = if kind = "tag" then "(tags [[" ^ target ^ "]])" else "[[" ^ target ^ "]]" in
    Ok (uuid, Ops.Atomic [insert;
      Ops.Set_property {uuid; attr = "block/tags"; expected = None;
        value = Some (Ops.Set_value [Ops.Ref_ident "logseq.class/Cards"])};
      Ops.Create_property_value {uuid = definition; owner_uuid = uuid; property_ident = "logseq.property/query";
        content = Ops.String_value source; created_at = now};
      Ops.Set_property {uuid; attr = "logseq.property/query"; expected = None; value = Some (Ops.Ref_uuid definition)}])
