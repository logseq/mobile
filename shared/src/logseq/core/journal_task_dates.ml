module Ds = Datascript
module Read = Graph_read
module Json = Yojson.Basic

let scheduled = Task_recurrence.scheduled
let deadline = Task_recurrence.deadline
let fields = Task_recurrence.fields
let member = Json.Util.member
let json_int = function Some value -> `Int value | None -> `Null
let identity value = Ok value
let week_days = 7
let max_upcoming_days = 31

let task_group_key section page = "task-page:" ^ section ^ ":" ^ page

let task_field key = function
  | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields)
  | _ -> `Null

let visible_in_tasks ~section ~show_completed ~show_past task =
  let status = task_field "ident" (task_field "status" (task_field "block" task)) in
  (show_completed || status <> `String Task_recurrence.done_ident)
  && (section = "upcoming" || show_past || task_field "past" task <> `Bool true)

let task_is_visible agenda ~section ~collapsed ~group_by_page ~show_completed ~show_past uuid =
  match task_field section agenda with
  | `List tasks ->
    List.exists (fun task ->
      task_field "uuid" task = `String uuid
      && visible_in_tasks ~section ~show_completed ~show_past task
      && (not group_by_page ||
        match task_field "pageId" (task_field "block" task) with
        | `String page -> not (List.mem (task_group_key section page) collapsed)
        | _ -> true)) tasks
  | _ -> false

let configuration db =
  let read_config datom =
    if datom.Ds.v <> Ds.String "logseq/config.edn" then None
    else Read.string_value (Read.value db datom.e "file/content") in
  let config = Ds.Db.datoms db Ds.Aevt ~a:"file/path" () |> Seq.find_map read_config in
  match Option.map (fun text -> try Dev_query.Edn_util.read_string text with _ -> Ds.Map []) config with
  | Some (Ds.Map entries) ->
    let setting key = List.assoc_opt (Ds.Keyword key) entries in
    let days = match setting "scheduled/future-days" with
      | Some (Ds.Int64 days) when days >= 0L -> Int64.to_int (min (Int64.of_int max_upcoming_days) days)
      | _ -> max_upcoming_days in
    setting "feature/disable-scheduled-and-deadline-query?" = Some (Ds.Bool true), days
  | _ -> false, max_upcoming_days

let valid_date = Task_recurrence.valid_date
let date = Task_recurrence.date

let status_attr = "logseq.property/status"
let doing_ident = "logseq.property/status.doing"

let rows ?actor db today lookahead =
  let offset_day days =
    Option.value ~default:today (Dev_query.Date_time_util.journal_day_plus today days) in
  let first_today = offset_day (1 - week_days) in
  let first_upcoming = offset_day 1 in
  let module Date = Dev_query.Date_time_util in
  let midnight = Date.journal_day_to_local_ms today in
  let last_upcoming = Cache_model.journal_day_for_ms (Int64.to_int (Date.plus Months 1 midnight)) in
  let upcoming_end = Option.map (fun days -> min last_upcoming (offset_day days)) lookahead in
  let last_activity eid =
    let activity attr = match Read.int_value (Read.value db eid attr) with
      | Some timestamp as value when valid_date timestamp -> value
      | _ -> None in
    match activity "block/updated-at" with
    | Some _ as updated -> updated
    | None -> activity "block/created-at" in
  let seen = Hashtbl.create 32 in
  let pages = Hashtbl.create 16 in
  let decorate = Node_presentation.decorate ?actor db in
  let default_status_eid = Read.default_task_status_eid db in
  let default_status = Option.bind default_status_eid (Read.choice_metadata identity db) in
  let page_details page =
    match Hashtbl.find_opt pages page with
    | Some details -> details
    | None ->
      let title = match Read.entity_summary identity db page with
        | Some summary -> summary.title | None -> "" in
      let created = Read.int_value (Read.value db page "block/created-at") in
      let updated = Read.int_value (Read.value db page "block/updated-at") in
      let details = title, created, (if updated = None then created else updated) in
      Hashtbl.add pages page details;
      details in
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
  let start = Date.journal_day_to_local_ms first_today in
  let next_after_upcoming = Option.value ~default:last_upcoming (Date.journal_day_plus last_upcoming 1) in
  let stop = Int64.pred (Date.journal_day_to_local_ms next_after_upcoming) in
  let dated_eids = List.to_seq fields |> Seq.flat_map (fun (_, attr) ->
      let datoms = if Ds.Schema.schema_attr_is_avet_accessible (Ds.schema db) attr then
          Ds.index_range db attr ~start:(Ds.Int64 start) ~stop:(Ds.Int64 stop) ()
        else Ds.Db.datoms db Ds.Aevt ~a:attr () in
      Seq.filter_map (fun (datom : Ds.datom) ->
        match datom.v with
        | Ds.Int64 time | Ds.Instant time when time >= start && time <= stop -> Some datom.e
        | _ -> None) datoms) in
  let recent_eids = Seq.init week_days (fun i -> offset_day (-i)) |> Seq.flat_map (fun day ->
    match Option.bind (Read.journal_page_uuid db day)
      (fun uuid -> Ds.entid db "block/uuid" (Ds.Uuid uuid)) with
    | Some page -> eids_with_ref "block/page" page | None -> Seq.empty) in
  let order_path eid page =
    let rec collect seen path eid =
      if eid = page || List.mem eid seen then path
      else
        let order = Option.value ~default:"" (Read.string_value (Read.value db eid "block/order")) in
        let path = `String order :: path in
        match Read.ref_eids db eid "block/parent" with
        | parent :: _ -> collect (eid :: seen) path parent
        | [] -> path in
    collect [] [] eid in
  let candidates = Seq.filter_map (fun eid ->
    if Hashtbl.mem seen eid then None else (
      Hashtbl.add seen eid ();
      let scheduled_at = date db eid scheduled in
      let deadline_at = date db eid deadline in
      let status = Read.status_for_eid identity db eid in
      let ident = Option.bind status (fun status -> status.Cache_model.ident) in
      let dates = List.filter_map (Option.map Cache_model.journal_day_for_ms) [scheduled_at; deadline_at] in
      let upcoming = Option.exists (fun last -> List.exists (fun day -> day >= first_upcoming && day <= last) dates)
        upcoming_end in
      let recent day = day >= first_today && day <= today in
      let due = lookahead <> None && List.exists recent dates in
      if Read.recycled db eid then None
        else match Read.ref_eids db eid "block/page" with
          | page :: _ ->
            let day = Read.int_value (Read.value db page "block/journal-day") in
            let visible = ident <> Some "logseq.property/status.canceled" in
            let journal_task = dates = [] && status <> None && Option.exists recent day in
            let recently_active = dates = [] && ident = Some doing_ident
              && Option.exists (fun date -> recent (Cache_model.journal_day_for_ms date)) (last_activity eid) in
            let past = (due && not (List.mem today dates)) || (journal_task && day <> Some today) in
            let today_row = visible && (due || journal_task || recently_active) in
            let upcoming_row = visible && upcoming && ident <> Some "logseq.property/status.done" in
            if not today_row && not upcoming_row then None else
            Option.map (fun block ->
              let status = match status with Some _ -> status | None -> default_status in
              let render_block = {block with Cache_model.status} in
              let title, created, updated = page_details page in
              (today_row, upcoming_row, block.uuid,
                `Assoc ["uuid", `String block.uuid; "block", decorate block.uuid (Rpc_encode.block_json render_block);
                  "page", `String title; "pageJournalDay", json_int day;
                  "pageCreated", json_int created; "pageUpdated", json_int updated;
                  "orderPath", `List (order_path eid page); "past", `Bool past;
                  "repeat", Task_recurrence.recurrence_json db eid;
                  "scheduled", json_int scheduled_at; "deadline", json_int deadline_at]))
              (Read.block ~with_breadcrumbs:false identity db eid)
          | _ -> None)) (Seq.concat (List.to_seq [dated_eids; doing_eids; recent_eids]))
    |> List.of_seq
    |> List.sort (fun (_, _, left, _) (_, _, right, _) -> String.compare left right) in
  let today = List.filter_map (fun (today, _, _, row) -> if today then Some row else None) candidates in
  let upcoming = List.filter_map (fun (_, upcoming, _, row) -> if upcoming then Some row else None) candidates in
  `List today, `List upcoming

type cached_projection = {
  day : int;
  timezone : string;
  actor : string option;
  db : Ds.db Weak.t;
  result : Json.t;
}

type cache = (string * cached_projection) list ref

let create_cache () : cache = ref []
let remove_cached_graph cache graph = cache := List.remove_assoc graph !cache
let clear_cache cache = cache := []

let cached_result cache ~graph =
  Option.map (fun cached -> cached.result) (List.assoc_opt graph !cache)

let preserve_for_local_edit cache ~before ~after changes =
  let ordinary_attr = function
    | "block/uuid" | "block/title" | "block/order" | "block/page" | "block/parent"
    | "block/created-at" | "block/updated-at" | "block/refs" | "block/tags"
    | "logseq.property/status" -> true
    | _ -> false in
  let changed = Hashtbl.create 4 in
  let hierarchy = Hashtbl.create 4 in
  if List.for_all (fun (d : Ds.datom) ->
    Hashtbl.replace changed d.e ();
    if List.mem d.a ["block/order"; "block/page"; "block/parent"] then
      Hashtbl.replace hierarchy d.e ();
    ordinary_attr d.a) changes then
    List.iter (fun (_, cached) ->
      if member "success" cached.result = `Bool true
         && Option.exists ((==) before) (Weak.get cached.db 0) then begin
        let today db id = Read.int_value (Read.value db id "block/journal-day") = Some cached.day in
        let unreferenced db eid =
          List.for_all (fun attr -> Seq.is_empty (Datascript_value.datoms_by_ref db Ds.Aevt attr eid))
            ["block/refs"; "block/tags"; "logseq.property/status"; "logseq.property/priority";
             "logseq.property/asset"; "logseq.property/order-list-type"]
          && (not (Hashtbl.mem hierarchy eid)
              || Seq.is_empty (Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" eid)) in
        let local_body db eid = match Read.uuid_for_eid db eid with
          | None -> Seq.is_empty (Ds.Db.datoms db Ds.Eavt ~e:eid ())
          | Some _ ->
            Read.value db eid "db/ident" = None && Read.value db eid "block/name" = None
            && Read.value db eid "block/closed-value-property" = None
            && match Read.ref_eids db eid "block/page" with
            | [id] -> today before id && today after id
            | _ -> false in
        (* Ordinary journal blocks can still render through embeds or references. *)
        let no_embeds db = Seq.is_empty (Ds.Db.datoms db Ds.Aevt ~a:"block/link" ()) in
        if no_embeds before && no_embeds after
           && Hashtbl.fold (fun eid () safe ->
             safe && local_body before eid && local_body after eid
             && Read.status_for_eid identity before eid = None && Read.status_for_eid identity after eid = None
             && unreferenced before eid && unreferenced after eid) changed true
        then Weak.set cached.db 0 (Some after)
      end) !cache

let project ?read_rows ?actor cache ~graph ~now ~force db =
  let read_rows = Option.value ~default:(rows ?actor) read_rows in
  let day = Cache_model.journal_day_for_ms now in
  let timezone = Int64.to_string (Dev_query.Date_time_util.journal_day_to_local_ms day) in
  let previous = match List.assoc_opt graph !cache with
    | Some value when value.day = day && value.timezone = timezone && value.actor = actor -> Some value
    | _ -> None in
  let remember value =
    let remaining = List.remove_assoc graph !cache in
    (* Keep up to four recently viewed graphs. *)
    cache := (graph, value) :: List.filteri (fun index _ -> index < 3) remaining;
    value.result in
  match previous with
  | Some value when not force && Option.exists ((==) db) (Weak.get value.db 0) ->
    remember value
  | _ ->
    let result =
      try
        let disabled, days = configuration db in
        let today, upcoming = read_rows db day (if disabled then None else Some days) in
        `Assoc ["graphId", `String graph; "day", `Int day; "error", `Bool false; "success", `Bool true;
          "retained", `Bool false; "today", today; "upcoming", upcoming]
      with error ->
        prerr_endline ("journal task query: " ^ Printexc.to_string error);
        let prior name = match previous with Some value -> member name value.result | None -> `List [] in
        `Assoc ["graphId", `String graph; "day", `Int day; "error", `Bool true;
          "retained", `Bool (Option.exists (fun value -> member "success" value.result = `Bool true || member "retained" value.result = `Bool true) previous);
          "today", prior "today"; "upcoming", prior "upcoming"] in
    let source = Weak.create 1 in
    Weak.set source 0 (Some db);
    remember {day; timezone; actor; db = source; result}

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
    `Assoc (("uuid", `String uuid) :: ("repeat", Task_recurrence.recurrence_json db eid) :: List.map (fun (name, attr) ->
      name, json_int (date db eid attr)) fields)) targets)]

let reschedule_on_day day current =
  if Option.exists (fun value -> Cache_model.journal_day_for_ms value = day) current then current
  else begin
    let module Date = Dev_query.Date_time_util in
    let midnight = Date.journal_day_to_local_ms day in
    let stamp = match current with
      | None -> midnight
      | Some value ->
        let time = Unix.localtime (floor (float_of_int value /. 1000.)) in
        let millis = (value mod 1000 + 1000) mod 1000 in
        Date.date_at_local_ms midnight time.tm_hour time.tm_min time.tm_sec millis in
    let stamp = Int64.to_int stamp in
    if valid_date stamp then Some stamp else invalid_arg "Choose a valid date and time"
  end

let mutation db input =
  let expected = Json.Util.to_list (member "targets" input) in
  let targets = targets db (List.map (member "uuid") expected) in
  if targets = [] then invalid_arg "Select a block";
  let changes = Json.Util.to_assoc (member "changes" input) in
  let edits = List.map (fun (name, value) ->
    let attr = List.assoc name fields in
    let resolve = match value with
      | `Null -> (fun _ -> None)
      | `Int value when valid_date value -> (fun _ -> Some value)
      | `Assoc ["day", `Int day] when Journal.valid_day day -> reschedule_on_day day
      | _ -> invalid_arg "Choose a valid date and time" in
    name, attr, resolve) changes in
  let writes = List.map2 (fun (uuid, eid) expected ->
    let changes = List.filter_map (fun (name, attr, resolve) ->
      let current = date db eid attr in
      if member name expected <> json_int current then
        invalid_arg "A task date changed. Reopen Task dates and try again";
      let next = resolve current in
      if current = next then None else
        let value = Option.map (fun value -> Pending_ops.Int_value value) in
        Some {Pending_ops.attr; expected = value current; value = value next}) edits
      @ Task_recurrence.repeat_changes db eid expected input in
    if changes = [] then None else Some (Pending_ops.Set_properties {uuid; updated_at = None; changes})) targets expected
    |> List.filter_map Fun.id in
  match writes with
  | [] -> None
  | [write] -> Some write
  | _ -> Some (Pending_ops.Atomic writes)
