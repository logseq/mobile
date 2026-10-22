module Ds = Datascript
module Ops = Pending_ops
module Read = Graph_read
type picker = Embed | Template | Link | Image | Date | Deadline | Scheduled | Youtube
type action =
  | Insert of string * int
  | Properties of (string * Ops.semantic_value option) list
  | Choice of string * string option
  | Code of string option
  | Number of bool
  | Journal of int
  | Time
  | Pick of picker
type entry = { id : string; label : string; action : action }
type operation =
  | Insert_code of string * string option
  | Ensure_journal of int
  | Apply of string * action | Embed_node of string * string * bool | Apply_template of string * string * string
let entry id label action = {id = "command:" ^ id; label; action}
let picker_name = function Embed -> "embed" | Template -> "template" | Link -> "link"
  | Image -> "image" | Date -> "date" | Deadline -> "deadline" | Scheduled -> "scheduled" | Youtube -> "youtube"
let picker_of_name = function "embed" -> Some Embed | "template" -> Some Template | "link" -> Some Link
  | "image" -> Some Image | "date" -> Some Date | "deadline" -> Some Deadline | "scheduled" -> Some Scheduled
  | "youtube" -> Some Youtube | _ -> None
let catalog db =
  let choices attr = match db with None -> [] | Some db -> Read.property_choices (fun x -> Ok x) db attr
    |> List.map (fun (v : Cache_model.status) -> entry (attr ^ ":" ^ v.uuid) v.title (Choice (attr, Some v.uuid))) in
  [entry "embed" "Node embed" (Pick Embed); entry "link" "Link" (Pick Link);
   entry "image" "Image link" (Pick Image); entry "underline" "Underline" (Insert ("<ins></ins>", 6));
   entry "code" "Code block" (Code None);
   entry "quote" "Quote" (Properties ["logseq.property.node/display-type", Some (Ops.Keyword_value "quote")]);
   entry "math" "Math block" (Properties ["logseq.property.node/display-type", Some (Ops.Keyword_value "math")])]
  @ List.init 6 (fun i -> let n = i + 1 in entry ("heading-" ^ string_of_int n) ("Heading " ^ string_of_int n)
      (Properties ["logseq.property/heading", Some (Ops.Int_value n)]))
  @ [entry "clear-heading" "Clear heading" (Properties ["logseq.property/heading", None])]
  @ choices "logseq.property/status"
  @ [entry "deadline" "Deadline" (Pick Deadline); entry "scheduled" "Scheduled" (Pick Scheduled)]
  @ choices "logseq.property/priority"
  @ [entry "no-priority" "No priority" (Choice ("logseq.property/priority", None))]
  @ [
     entry "tomorrow" "Tomorrow" (Journal 1); entry "yesterday" "Yesterday" (Journal (-1));
     entry "today" "Today" (Journal 0); entry "time" "Current time" Time; entry "date" "Date picker" (Pick Date);
     entry "number" "Number list" (Number false); entry "number-children" "Number children" (Number true);
     entry "calculator" "Calculator" (Code (Some "calc")); entry "template" "Template" (Pick Template);
     entry "html" "Embed HTML" (Insert ("@@html: @@", 2));
     entry "video" "Embed Video URL" (Insert ("{{video }}", 2));
     entry "youtube" "Embed YouTube timestamp" (Pick Youtube);
     entry "tweet" "Embed Twitter tweet" (Insert ("{{tweet }}", 2));
     entry "cloze" "Cloze" (Insert ("{{cloze }}", 2))]

let group value =
  if not (String.starts_with ~prefix:"command:" value) then None else
  let id = String.sub value 8 (String.length value - 8) in
  Some (if id = "embed" then "BASIC"
    else if List.mem id ["link"; "image"; "underline"; "code"; "quote"; "math"] then "FORMAT"
    else if id = "clear-heading" || String.starts_with ~prefix:"heading-" id then "Heading"
    else if String.starts_with ~prefix:"logseq.property/status:" id then "TASK STATUS"
    else if List.mem id ["deadline"; "scheduled"] then "TASK DATE"
    else if id = "no-priority" || String.starts_with ~prefix:"logseq.property/priority:" id then "PRIORITY"
    else if List.mem id ["tomorrow"; "yesterday"; "today"; "time"; "date"] then "TIME & DATE"
    else if List.mem id ["number"; "number-children"] then "LIST TYPE"
    else "ADVANCED")

let candidates db query =
  let query = String.lowercase_ascii (String.trim query) in
  let entries = catalog db in
  if query = "" then entries else
    List.filter_map (fun entry ->
      let score = Search_index.fuzzy_score query entry.label in
      if score > 0. then Some (entry, score) else None) entries
    |> List.stable_sort (fun (_, a) (_, b) -> compare b a)
    |> List.map fst

let journal_reference db ms =
  let day = Cache_model.journal_day_for_ms ms in
  let title = Option.bind db (fun db -> Option.bind (Read.journal_page_uuid db day)
    (fun uuid -> Option.bind (Ds.entid db "block/uuid" (Ds.Uuid uuid))
      (fun eid -> Read.string_value (Read.value db eid "block/title")))) in
  "[[" ^ Option.value ~default:(Journal.day_title day) title ^ "]]"

let date_ms value =
  try
    if String.length value <> 10 || value.[4] <> '-' || value.[7] <> '-' then invalid_arg "date";
    let y = int_of_string (String.sub value 0 4) and m = int_of_string (String.sub value 5 2)
    and d = int_of_string (String.sub value 8 2) in
    let seconds, tm = Unix.mktime { (Unix.localtime 0.) with tm_year = y - 1900; tm_mon = m - 1; tm_mday = d;
      tm_hour = 0; tm_min = 0; tm_sec = 0; tm_isdst = false } in
    if tm.Unix.tm_year <> y - 1900 || tm.tm_mon <> m - 1 || tm.tm_mday <> d then invalid_arg "date";
    Ok (int_of_float (seconds *. 1000.))
  with _ -> Error "Choose a valid date"

let timestamp value =
  try
    let parts = String.split_on_char ':' (String.trim value) |> List.map int_of_string in
    let seconds = match parts with [s] -> s | [m;s] when s < 60 -> m*60+s
      | [h;m;s] when m < 60 && s < 60 -> h*3600+m*60+s | _ -> invalid_arg "time" in
    if seconds < 0 then invalid_arg "time";
    Ok seconds
  with _ -> Error "Enter a timestamp such as 1:32"

let link ~image value =
  try
    let json = Yojson.Basic.from_string value in
    let field key = match json with `Assoc fields -> (match List.assoc_opt key fields with Some (`String x) -> x | _ -> "") | _ -> "" in
    let url = String.trim (field "url") in
    if url = "" then invalid_arg "Enter a URL";
    let lower = String.lowercase_ascii url in
    if not (List.exists (fun prefix -> String_kit.starts_with ~prefix lower)
      ["https://"; "http://"; "mailto:"; "logseq://"]) then invalid_arg "Enter a valid URL";
    let escape v = String_kit.replace v ~match_:" " ~replacement:"%20" in
    let url = String_kit.replace (escape url) ~match_:")" ~replacement:"%29" in
    let label = field "label" in
    let label = if label = "" then if image then "Image" else url else label in
    let label = String_kit.replace label ~match_:"]" ~replacement:"\\]" in
    Ok ((if image then "!" else "") ^ "[" ^ label ^ "](" ^ url ^ ")")
  with Invalid_argument error -> Error error | _ -> Error "Enter a URL and label"
