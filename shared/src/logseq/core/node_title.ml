module D = Datascript
module G = Graph_read
module U = Dev_query.Unicode

let get db id attr = G.value db id attr
let text = function Some (D.String value) -> value | _ -> ""
let ident db id = match get db id "db/ident" with Some (D.Keyword value) -> value | _ -> ""
let tags db id = G.ref_eids db id "block/tags"
let tagged db id kind = List.exists (fun tag -> ident db tag = kind) (tags db id)
let is_property db id = tagged db id "logseq.class/Property"
let is_class db id = tagged db id "logseq.class/Tag"
let is_page db id = get db id "block/name" <> None ||
  List.exists (tagged db id) ["logseq.class/Page"; "logseq.class/Tag"; "logseq.class/Property"; "logseq.class/Journal"]
let builtin db id = get db id "logseq.property/built-in?" = Some (D.Bool true)
  || get db id "file/path" <> None
  || List.exists (fun prefix -> String.starts_with ~prefix (ident db id))
    ["block/"; "db/"; "logseq.class/"; "logseq.kv/"; "logseq.property/"; "logseq.property."]
let journal db id = get db id "block/journal-day" <> None || tagged db id "logseq.class/Journal"
let can_edit db id = not (builtin db id || journal db id)
let can_rename_page db id = is_page db id && can_edit db id
let can_delete ?(now = int_of_float (Unix.gettimeofday () *. 1000.)) db id =
  not (builtin db id)
  && get db id "logseq.property/hide?" <> Some (D.Bool true)
  && G.int_value (get db id "block/journal-day") <> Some (Cache_model.journal_day_for_ms now)

let nfc text =
  let normalizer = Uunf.create `NFC in
  let result = Buffer.create (String.length text) in
  let rec add value = match Uunf.add normalizer value with
    | `Uchar value -> Buffer.add_utf_8_uchar result value; add `Await
    | `Await | `End -> () in
  let rec loop index =
    if index < String.length text then (
      let value = String.get_utf_8_uchar text index in
      add (`Uchar (Uchar.utf_decode_uchar value));
      loop (index + Uchar.utf_decode_length value)) in
  loop 0; add `End; Buffer.contents result

let name title =
  let title = U.lowercase title in
  let title = if String.starts_with ~prefix:"/" title then String.sub title 1 (String.length title - 1) else title in
  let title = if String.ends_with ~suffix:"/" title then String.sub title 0 (String.length title - 1) else title in
  nfc title

let duplicate db id title =
  let property = is_property db id in
  let exact = property || is_class db id in
  let attr, lookup = if exact then "block/title", title else "block/name", name title in
  let own_tags = tags db id in
  let own_idents = List.map (ident db) own_tags |> List.sort_uniq String.compare in
  let parent = G.ref_eids db id "block/parent" in
  own_tags <> [] && Seq.exists (fun (datom : D.datom) ->
    let other = datom.e in
    other <> id
    && (not property || get db other "logseq.property/built-in?" = None)
    && (property || (if parent <> [] then G.ref_eids db other "block/parent" = parent
      else exact || G.ref_eids db other "block/parent" = []))
    && let other_tags = tags db other in
       if not (List.exists (fun tag -> List.mem tag own_tags) other_tags) then false
       else let other_idents = List.map (ident db) other_tags |> List.sort_uniq String.compare in
         let common = List.filter (fun value -> List.mem value other_idents) own_idents in
         not (common = ["logseq.class/Page"] && List.length own_idents > 1 && List.length other_idents > 1))
    (D.Db.datoms db D.Avet ~a:attr ~v:(D.String lookup) ())

(* Keep these guards at the mutation boundary, matching outliner/validate.cljs. *)
let validate db id title =
  if builtin db id then Error "Built-in names cannot be changed"
  else if journal db id then Error "Journal pages cannot be renamed"
  else if not (is_page db id) then Ok ()
  else if U.trim title = "" then Error "Page name cannot be blank"
  else if String.contains title '#' then Error "Page name cannot include #"
  else if String.contains title '/' && not (Dev_query.Date_time_util.valid_journal_title title) then
    Error "Page name cannot include /"
  else if is_property db id && String.starts_with ~prefix:"[[" title then
    Error "Property name cannot start with [["
  else if Dev_query.Date_time_util.valid_journal_title title then Error "A page cannot be renamed to a journal"
  else if duplicate db id title then Error "Another page, tag or property with this name already exists"
  else Ok ()
