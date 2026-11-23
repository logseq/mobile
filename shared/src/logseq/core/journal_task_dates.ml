module Ds = Datascript
module Read = Graph_read
module Json = Yojson.Basic

let scheduled = "logseq.property/scheduled"
let deadline = "logseq.property/deadline"
let fields = ["scheduled", scheduled; "deadline", deadline]
let member = Json.Util.member
let json_int = function Some value -> `Int value | None -> `Null
let identity value = Ok value
let week_days = 7

let configuration db =
  let read_config datom =
    if datom.Ds.v <> Ds.String "logseq/config.edn" then None
    else Read.string_value (Read.value db datom.e "file/content") in
  let config = Ds.Db.datoms db Ds.Aevt ~a:"file/path" () |> Seq.find_map read_config in
  match Option.map (fun text -> try Dev_query.Edn_util.read_string text with _ -> Ds.Map []) config with
  | Some (Ds.Map entries) ->
    let setting key = List.assoc_opt (Ds.Keyword key) entries in
    let days = match setting "scheduled/future-days" with
      | Some (Ds.Int64 days) when days >= 0L -> Int64.to_int (min (Int64.of_int week_days) days)
      | _ -> week_days in
    setting "feature/disable-scheduled-and-deadline-query?" = Some (Ds.Bool true), days
  | _ -> false, week_days

let valid_date value =
  value >= -62135596800000 && value <= 253402300799999

let date db eid attr =
  match Read.int_value (Read.value db eid attr) with
  | Some value when valid_date value -> Some value
  | _ -> None

let status_attr = "logseq.property/status"
let doing_ident = "logseq.property/status.doing"

type section = Overdue | Doing | Planned

let rows db today lookahead =
  let offset_day days =
    Option.value ~default:today (Dev_query.Date_time_util.journal_day_plus today days) in
  let first_day = offset_day (-week_days) in
  let last_day = offset_day week_days in
  let end_day = Option.map offset_day lookahead in
  let midnight = Dev_query.Date_time_util.journal_day_to_local_ms in
  let start = midnight first_day in
  let stop = Int64.pred (midnight (offset_day (week_days + 1))) in
  let within_window = function
    | Some timestamp as value ->
      let day = Cache_model.journal_day_for_ms timestamp in
      if day >= first_day && day <= last_day then value else None
    | None -> None in
  let last_activity eid =
    let activity attr = match Read.int_value (Read.value db eid attr) with
      | Some timestamp as value when valid_date timestamp -> value
      | _ -> None in
    match activity "block/updated-at" with
    | Some _ as updated -> updated
    | None -> activity "block/created-at" in
  let seen = Hashtbl.create 32 in
  let page_titles = Hashtbl.create 16 in
  let decorate = Node_presentation.decorate db in
  let default_status_eid = Read.default_task_status_eid db in
  let default_status = Option.bind default_status_eid (Read.choice_metadata identity db) in
  let page_title page =
    match Hashtbl.find_opt page_titles page with
    | Some title -> title
    | None ->
      let title = match Read.entity_summary identity db page with
        | Some summary -> summary.title | None -> "" in
      Hashtbl.add page_titles page title;
      title in
  let eids_with_ref attr value =
    Datascript_value.datoms_by_ref db Ds.Aevt attr value |> Seq.map (fun datom -> datom.Ds.e) in
  let doing_eids = match Ds.entid db "db/ident" (Ds.Keyword doing_ident) with
    | None -> Seq.empty
    | Some doing ->
      let explicit = eids_with_ref status_attr doing in
      if default_status_eid <> Some doing then explicit
      else
        let classes = match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Task") with
          | Some task -> Read.class_descendants db task
          | None -> [] in
        Seq.append explicit (List.to_seq classes |> Seq.flat_map (eids_with_ref "block/tags")) in
  let dated_eids = match end_day with
    | None -> Seq.empty
    | Some _ -> List.to_seq fields |> Seq.flat_map (fun (_, attr) ->
      let datoms = if Ds.Schema.schema_attr_is_avet_accessible (Ds.schema db) attr then
          Ds.index_range db attr ~start:(Ds.Int64 start) ~stop:(Ds.Int64 stop) ()
        else Ds.Db.datoms db Ds.Aevt ~a:attr () in
      Seq.filter_map (fun (datom : Ds.datom) ->
        match datom.v with
        | Ds.Int64 time | Ds.Instant time when time >= start && time <= stop -> Some datom.e
        | _ -> None) datoms) in
  let candidates = Seq.filter_map (fun eid ->
    if Hashtbl.mem seen eid then None else (
      Hashtbl.add seen eid ();
      let scheduled_at = date db eid scheduled in
      let deadline_at = date db eid deadline in
      let earliest = match within_window scheduled_at, within_window deadline_at with
        | Some a, Some b -> Some (min a b)
        | Some a, None | None, Some a -> Some a
        | None, None -> None in
      let activity = lazy (last_activity eid) in
      let doing_qualifies = if scheduled_at = None && deadline_at = None then
          within_window (Lazy.force activity) <> None
        else earliest <> None in
      if not doing_qualifies then None else
      let status = Read.status_for_eid identity db eid in
      let ident = Option.bind status (fun status -> status.Cache_model.ident) in
      let dated_section = match earliest, end_day with
        | Some earliest, Some end_day ->
          let day = Cache_model.journal_day_for_ms earliest in
          if day < today then Some (Overdue, earliest)
          else if day <= end_day then Some (Planned, earliest)
          else None
        | _ -> None in
      let section = match ident, dated_section with
        | (Some "logseq.property/status.done" | Some "logseq.property/status.canceled"), _ -> None
        | _, Some (Overdue, _) -> dated_section
        | Some ident, _ when ident = doing_ident ->
          Some (Doing, -(Option.value ~default:0 (Lazy.force activity)))
        | _, _ -> dated_section in
      Option.bind section (fun (section, order) ->
        if Read.recycled db eid then None
        else match Read.block ~with_breadcrumbs:false identity db eid, Read.ref_eids db eid "block/page" with
          | Some block, page :: _
            when Read.int_value (Read.value db page "block/journal-day") <> Some today ->
            let status = match status with Some _ -> status | None -> default_status in
            let render_block = {block with Cache_model.status} in
            Some (order, block.uuid, section,
              `Assoc ["uuid", `String block.uuid; "block", decorate block.uuid (Rpc_encode.block_json render_block);
                "page", `String (page_title page);
                "scheduled", json_int scheduled_at; "deadline", json_int deadline_at])
          | _ -> None))) (Seq.append dated_eids doing_eids) in
  let ordered = List.of_seq candidates |> List.sort (fun (a, u, _, _) (b, v, _, _) ->
    compare (a, u) (b, v)) in
  let json section = `List (List.filter_map (fun (_, _, bucket, row) ->
    if bucket = section then Some row else None) ordered) in
  json Overdue, json Doing, json Planned

type cached_projection = {
  day : int;
  timezone : string;
  db : Ds.db Weak.t;
  result : Json.t;
}

type cache = (string * cached_projection) list ref

let create_cache () : cache = ref []
let remove_cached_graph cache graph = cache := List.remove_assoc graph !cache
let clear_cache cache = cache := []

let project ?(read_rows = rows) cache ~graph ~now ~force db =
  let day = Cache_model.journal_day_for_ms now in
  let timezone = Int64.to_string (Dev_query.Date_time_util.journal_day_to_local_ms day) in
  let previous = match List.assoc_opt graph !cache with
    | Some value when value.day = day && value.timezone = timezone -> Some value
    | _ -> None in
  let remember value =
    let remaining = List.remove_assoc graph !cache in
    (* Keep the three quick-switch graphs and the active graph. *)
    cache := (graph, value) :: List.filteri (fun index _ -> index < 3) remaining;
    value.result in
  match previous with
  | Some value when not force && Option.exists ((==) db) (Weak.get value.db 0) ->
    remember value
  | _ ->
    let fallback_page = Journal.page_uuid day in
    let result =
      try
        let page = Option.value ~default:fallback_page (Read.journal_page_uuid db day) in
        let disabled, days = configuration db in
        let overdue, doing, planned = read_rows db day (if disabled then None else Some days) in
        `Assoc ["graphId", `String graph; "page", `String page; "day", `Int day; "error", `Bool false; "success", `Bool true;
          "enabled", `Bool (not disabled || doing <> `List []); "retained", `Bool false;
          "overdue", overdue; "doing", doing; "planned", planned]
      with error ->
        prerr_endline ("journal task query: " ^ Printexc.to_string error);
        let prior name = match previous with Some value -> member name value.result | None -> `List [] in
        let page = match previous with Some value -> member "page" value.result | None -> `String fallback_page in
        `Assoc ["graphId", `String graph; "page", page; "day", `Int day; "error", `Bool true;
          "enabled", `Bool true; "retained", `Bool (Option.exists (fun value -> member "success" value.result = `Bool true || member "retained" value.result = `Bool true) previous);
          "overdue", prior "overdue"; "doing", prior "doing"; "planned", prior "planned"] in
    let source = Weak.create 1 in
    Weak.set source 0 (Some db);
    remember {day; timezone; db = source; result}

let targets db uuids =
  List.map (function
    | `String uuid ->
      (match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
       | Some eid when Read.ref_eids db eid "block/page" <> [] && not (Read.recycled db eid) -> uuid, eid
       | _ -> invalid_arg "A selected block is no longer available")
    | _ -> invalid_arg "Invalid task date target") uuids

let values db targets =
  if targets = [] then invalid_arg "Select a block";
  `Assoc ["targets", `List (List.map (fun (uuid, eid) ->
    `Assoc (("uuid", `String uuid) :: List.map (fun (name, attr) ->
      name, json_int (date db eid attr)) fields)) targets)]

let mutation db input =
  let expected = Json.Util.to_list (member "targets" input) in
  let targets = targets db (List.map (member "uuid") expected) in
  if targets = [] then invalid_arg "Select a block";
  let changes = Json.Util.to_assoc (member "changes" input) in
  let edits = List.map (fun (name, value) ->
    let attr = List.assoc name fields in
    let next = match value with
      | `Null -> None
      | `Int value when valid_date value -> Some value
      | _ -> invalid_arg "Choose a valid date and time" in
    name, attr, next) changes in
  let writes = List.map2 (fun (uuid, eid) expected ->
    let changes = List.filter_map (fun (name, attr, next) ->
      let current = date db eid attr in
      if member name expected <> json_int current then
        invalid_arg "A task date changed. Reopen Task dates and try again";
      if current = next then None else
        let value = Option.map (fun value -> Pending_ops.Int_value value) in
        Some {Pending_ops.attr; expected = value current; value = value next}) edits in
    if changes = [] then None else Some (Pending_ops.Set_properties {uuid; updated_at = None; changes})) targets expected
    |> List.filter_map Fun.id in
  match writes with
  | [] -> None
  | [write] -> Some write
  | _ -> Some (Pending_ops.Atomic writes)
