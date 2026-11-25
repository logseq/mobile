module Ds = Datascript
module Read = Graph_read
module Ops = Pending_ops

let scheduled = "logseq.property/scheduled"
let deadline = "logseq.property/deadline"
let fields = ["scheduled", scheduled; "deadline", deadline]
let status_attr = "logseq.property/status"
let member = Yojson.Basic.Util.member

let valid_date value =
  value >= -62135596800000 && value <= 253402300799999

let date db eid attr =
  match Read.int_value (Read.value db eid attr) with
  | Some value when valid_date value -> Some value
  | _ -> None

let done_ident = "logseq.property/status.done"
let todo_ident = "logseq.property/status.todo"
let repeat_attr name = "logseq.property.repeat/" ^ name

let referenced_ident db eid attr =
  match Read.ref_eids db eid attr with
  | first :: _ -> (match Read.value db first "db/ident" with Some (Ds.Keyword value) -> Some value | _ -> None)
  | [] -> (match Read.value db eid attr with Some (Ds.Keyword value) -> Some value | _ -> None)

type repeat_mode = From_completion | From_scheduled | Skip_to_future
type recurrence = { unit_name : string; frequency : int; mode : repeat_mode }

let repeat_period = function
  | "minute" -> Some Dev_query.Date_time_util.Minutes
  | "hour" -> Some Hours
  | "day" -> Some Days
  | "week" -> Some Weeks
  | "month" -> Some Months
  | "year" -> Some Years
  | _ -> None

let repeat_unit_ident name = repeat_attr ("recur-unit." ^ name)

let recurrence db eid =
  if Read.value db eid (repeat_attr "repeated?") <> Some (Ds.Bool true) then None else
  let unit_name = match referenced_ident db eid (repeat_attr "recur-unit") with
    | None -> "day"
    | Some ident when String.starts_with ~prefix:(repeat_unit_ident "") ident ->
      String.sub ident (String.length (repeat_unit_ident "")) (String.length ident - String.length (repeat_unit_ident ""))
    | Some _ -> "" in
  let frequency_attr = repeat_attr "recur-frequency" in
  let frequency_value = match Read.ref_eids db eid frequency_attr with
    | ref_eid :: _ ->
      (match Read.value db ref_eid "logseq.property/value" with
       | None -> Read.value db ref_eid "block/title"
       | value -> value)
    | [] -> Read.value db eid frequency_attr in
  let frequency = match frequency_value with
    | None -> Some 1
    | Some (Ds.String value) -> int_of_string_opt value
    | value -> Read.int_value value in
  let mode = match referenced_ident db eid (repeat_attr "repeat-type") with
    | Some "logseq.property.repeat/repeat-type.dotted-plus" -> From_completion
    | Some "logseq.property.repeat/repeat-type.plus" -> From_scheduled
    | _ -> Skip_to_future in
  Option.bind frequency (fun frequency ->
    if frequency > 0 && repeat_period unit_name <> None
    then Some {unit_name; frequency; mode} else None)

let recurrence_json db eid =
  match recurrence db eid with
  | None -> `Null
  | Some {unit_name; frequency; mode} ->
    let mode = match mode with
      | From_completion -> "from-completion"
      | From_scheduled -> "from-scheduled"
      | Skip_to_future -> "skip-to-future" in
    let custom = match referenced_ident db eid (repeat_attr "checked-property"),
      referenced_ident db eid (repeat_attr "temporal-property") with
      | (None | Some "logseq.property/status"), (None | Some "logseq.property/scheduled" | Some "logseq.property/deadline") -> false
      | _ -> true in
    `Assoc ["unit", `String unit_name; "frequency", `Int frequency; "mode", `String mode;
      "custom", `Bool custom]

let repetition_shift {unit_name; frequency; _} anchor count =
  let module Date = Dev_query.Date_time_util in
  let period = Option.get (repeat_period unit_name) in
  let max_units = match period with
    | Minutes -> 5_300_000_000 | Hours -> 88_000_000 | Days -> 3_660_000
    | Weeks -> 525_000 | Months -> 120_000 | Years -> 10_000 in
  if count > max_units / frequency then None
  else
    let next = Int64.to_int (Date.plus period (frequency * count) (Int64.of_int anchor)) in
    if valid_date next && next > anchor then Some next else None

let repetitions_until_future ~now ~current rule =
  let shift = repetition_shift rule current in
  let after_now = function None -> true | Some next -> next > now in
  let rec first_after low high =
    if high - low = 1 then high
    else
      let middle = low + (high - low) / 2 in
      if after_now (shift middle) then first_after low middle
      else first_after middle high in
  let rec find_upper low high =
    if after_now (shift high) then first_after low high
    else find_upper high (high * 2) in
  find_upper 0 1

let next_repetition ~now ~current rule =
  let anchor, count = match rule.mode with
    | From_completion -> now, 1
    | From_scheduled -> current, 1
    | Skip_to_future -> current, repetitions_until_future ~now ~current rule in
  repetition_shift rule anchor count

let next_dates ~now rule dates =
  let change attr current next =
    {Ops.attr; expected = Some (Ops.Int_value current); value = Some (Ops.Int_value next)} in
  match dates with
  | [] -> []
  | [attr, current] ->
    Option.to_list (Option.map (change attr current) (next_repetition ~now ~current rule))
  | (_, first) :: rest ->
    let anchor = List.fold_left (fun earliest (_, value) -> min earliest value) first rest in
    let count = match rule.mode with
      | Skip_to_future -> repetitions_until_future ~now ~current:anchor rule
      | From_completion | From_scheduled -> 1 in
    let changes = List.map (fun (attr, current) ->
      let base = match rule.mode with
        | From_completion -> now + (current - anchor)
        | From_scheduled | Skip_to_future -> current in
      Option.map (change attr current) (repetition_shift rule base count)) dates in
    List.fold_right (fun change acc ->
      Option.bind change (fun change -> Option.map (List.cons change) acc)) changes (Some [])
    |> Option.value ~default:[]

let complete_repetition db ~uuid ~expected ~now =
  let temporal_attrs = match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
    | None -> None
    | Some eid ->
      let checked = referenced_ident db eid (repeat_attr "checked-property") in
      if checked <> None && checked <> Some status_attr then None else
      Option.map (fun rule ->
        let attrs = match referenced_ident db eid (repeat_attr "temporal-property") with
          | Some attr -> [attr]
          | None -> [scheduled; deadline] in
        List.filter_map (fun attr -> Option.map (fun value -> attr, value) (date db eid attr)) attrs
        |> next_dates ~now rule)
        (recurrence db eid) in
  match temporal_attrs with
  | Some (_ :: _ as changes) when Ds.entid db "db/ident" (Ds.Keyword todo_ident) <> None ->
    let status = {Ops.attr = status_attr; expected; value = Some (Ops.Ref_ident todo_ident)} in
    let repeated = Some (Ops.Bool_value true) in
    let guard = {Ops.attr = repeat_attr "repeated?"; expected = repeated; value = repeated} in
    Some (Ops.Set_properties {uuid; changes = status :: guard :: changes; updated_at = Some now})
  | _ -> None

let status_edit ?db ~now ~uuid ~expected ~value fallback =
  let status_ident db = function
    | Some (Ops.Ref_ident ident) -> Some ident
    | Some (Ops.Ref_uuid uuid) ->
      Option.bind (Ds.entid db "block/uuid" (Ds.Uuid uuid)) (fun eid ->
        match Read.value db eid "db/ident" with Some (Ds.Keyword ident) -> Some ident | _ -> None)
    | _ -> None in
  match db with
  | Some db when status_ident db value = Some done_ident && status_ident db expected <> Some done_ident ->
    Option.value ~default:fallback (complete_repetition db ~uuid ~expected ~now)
  | _ -> fallback

let stored_property db eid attr =
  match Read.value db eid attr with
  | None -> None
  | Some value ->
    let ref_eid = Datascript_value.optional_ref_eid db attr (Some value) in
    match ref_eid with
    | Some id ->
      (match Read.value db id "db/ident" with
       | Some (Ds.Keyword ident) -> Some (Ops.Ref_ident ident)
       | _ -> Option.map (fun uuid -> Ops.Ref_uuid uuid) (Read.uuid_for_eid db id))
    | None -> Some (Result.get_ok (Ops.semantic_value_from_datascript value))

let repeat_changes db eid expected input =
  let change field value =
    let attr = repeat_attr field in
    let expected = stored_property db eid attr in
    if expected = value then None else Some {Ops.attr; expected; value} in
  match member "repeat" input with
  | `Null -> []
  | `String unit ->
    if member "repeat" expected <> recurrence_json db eid then
      invalid_arg "The task repetition changed. Reopen Task dates and try again";
    let writes = match unit with
      | "none" -> ["repeated?", Some (Ops.Bool_value false)]
      | "day" | "week" | "month" | "year" ->
        if not (List.exists (fun (_, attr) -> date db eid attr <> None) fields) then
          invalid_arg "Set a scheduled date or deadline before repeating a task";
        ["repeated?", Some (Ops.Bool_value true);
         "recur-unit", Some (Ops.Ref_ident (repeat_unit_ident unit));
         "recur-frequency", None; "repeat-type", None;
         "checked-property", None; "temporal-property", None]
      | _ -> invalid_arg "Choose a valid repeat interval" in
    List.filter_map (fun (field, value) -> change field value) writes
  | _ -> invalid_arg "Choose a valid repeat interval"
