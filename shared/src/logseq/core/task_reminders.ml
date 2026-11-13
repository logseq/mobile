module Ds = Datascript
module G = Graph_read
module Model = Cache_model

type temporal = Date of int | Datetime of int64
type task = { uuid : string; page_id : string; temporal : temporal }

let value db id attr = G.value db id attr
let ident db id = match value db id "db/ident" with Some (Ds.Keyword name) -> name | _ -> ""
let uuid db id = Option.value ~default:"" (G.uuid_for_eid db id)
let ref_id db attr = function
  | Some (Ds.Ref id) -> Some id
  | Some (Ds.Ref_to reference) -> Option.map (fun entity -> entity.Ds.id) (Ds.entity db reference)
  | _ -> None

(* Keep the same precedence as Result_view.content for typed property values:
   wrapper entities store text in block/title and non-text scalars in value. *)
let content db attr raw =
  match ref_id db attr (Some raw) with
  | None -> Some raw
  | Some eid ->
    (match value db eid "block/title" with
     | None | Some Ds.Nil -> value db eid "logseq.property/value"
     | Some wrapped -> Some wrapped)

let repeat_metadata_present db id =
  let metadata = Ds.Db.datoms db Ds.Eavt ~e:id ()
    |> Seq.filter (fun (d : Ds.datom) -> String.starts_with ~prefix:"logseq.property.repeat/" d.a)
    |> List.of_seq in
  let repeated_value = List.find_map (fun (d : Ds.datom) ->
    if d.a = "logseq.property.repeat/repeated?" then Some d.v else None) metadata in
  match repeated_value with
  | Some (Ds.Bool true) -> true
  | Some (Ds.Bool false) -> List.exists (fun (d : Ds.datom) ->
      not (List.mem d.a ["logseq.property.repeat/repeated?";
        "logseq.property.repeat/recur-frequency"; "logseq.property.repeat/recur-unit";
        "logseq.property.repeat/repeat-type"; "logseq.property.repeat/temporal-property";
        "logseq.property.repeat/checked-property"])) metadata
  | _ -> metadata <> []

let empty_placeholder db = function
  | Some (Ds.Ref eid) -> ident db eid = "logseq.property/empty-placeholder"
  | Some (Ds.Ref_to reference) -> Option.fold ~none:false ~some:(fun eid -> ident db eid = "logseq.property/empty-placeholder")
      (Option.map (fun entity -> entity.Ds.id) (Ds.entity db reference))
  | _ -> false

let scheduled_or_deadline db id =
  let scheduled = value db id "logseq.property/scheduled" in
  let attr, raw = match scheduled with
    | Some value when not (empty_placeholder db (Some value)) -> "logseq.property/scheduled", Some value
    | None | Some _ -> "logseq.property/deadline", value db id "logseq.property/deadline" in
  match raw with
  | None -> None
  | Some raw ->
    let typ = Option.bind (Ds.entid db "db/ident" (Ds.Keyword attr))
      (fun property -> match value db property "logseq.property/type" with
        | Some (Ds.Keyword typ) -> Some typ | _ -> None) in
    (match typ with
     | Some "date" ->
       Option.bind (ref_id db attr (Some raw)) (fun eid ->
         let day = match value db eid "block/journal-day" with Some day -> Some day | None -> value db eid "logseq.property/value" in
         match day with
         | Some (Ds.Int64 day) when Journal.valid_day (Int64.to_int day) -> Some (Date (Int64.to_int day))
         | Some (Ds.Instant day) when Journal.valid_day (Int64.to_int day) -> Some (Date (Int64.to_int day))
         | _ -> None)
     | Some "datetime" ->
       let unwrapped = match ref_id db attr (Some raw) with
         | Some eid when ident db eid = "logseq.property/empty-placeholder" -> None
         | _ -> content db attr raw in
       (match unwrapped with
        | None -> None
        | Some (Ds.Int64 timestamp | Ds.Instant timestamp) -> Some (Datetime timestamp)
        | Some (Ds.Float timestamp) when Float.is_finite timestamp && abs_float timestamp <= 8.64e15 -> Some (Datetime (Int64.of_float timestamp))
        | _ -> None)
     | _ -> None)

let terminal_status db id =
  match G.status_for_eid (fun text -> Ok text) db id with
  | Some status -> List.mem status.Model.ident [Some "logseq.property/status.done"; Some "logseq.property/status.canceled"]
  | None -> false

let task_for_eid db id =
  if G.recycled db id || terminal_status db id || repeat_metadata_present db id
  then None
  else
    match G.uuid_for_eid db id, ref_id db "block/page" (value db id "block/page"), scheduled_or_deadline db id with
    | Some task_uuid, page, Some temporal when task_uuid <> "" ->
      let page = Option.value ~default:id page in
      if page = id && not (G.entity_is_instance_of db id "logseq.class/Page") then None else
      if uuid db page = "" then None else
      Some {uuid = task_uuid; page_id = uuid db page; temporal}
    | _ -> None

let inventory db =
  match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Task") with
  | None -> []
  | Some task_class ->
    (* Match the indexed tag-object reader: discover Task descendants once,
       then inspect only their objects, not every tagged entity in the graph. *)
    G.class_descendants db task_class
    |> List.concat_map (fun eid ->
      Datascript_value.datoms_by_ref db Ds.Aevt "block/tags" eid
      |> Seq.map (fun (d : Ds.datom) -> d.e) |> List.of_seq)
    |> List.sort_uniq compare
    |> List.filter_map (task_for_eid db)
    |> List.sort (fun a b -> compare (a.temporal, a.uuid) (b.temporal, b.uuid))

let temporal_json = function
  | Date day -> `Assoc ["kind", `String "date"; "day", `Int day]
  | Datetime timestamp -> `Assoc ["kind", `String "datetime"; "timestampMs", `Int (Int64.to_int timestamp)]

let task_json task = `Assoc [
  "uuid", `String task.uuid; "pageId", `String task.page_id;
  "temporal", temporal_json task.temporal]
