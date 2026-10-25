module Ds = Datascript
module Graph = Graph_read
module Sql = Graph_sqlite
module Ref_text = Ref_text

let search_open = Sql.search_open
let search_upsert = Sql.search_upsert
let search_delete = Sql.search_delete
let search_query = Sql.search_query

type search_index =
  { path : string
  }

type search_result =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; is_page : bool
  }

type indexed_search_hit =
  { uuid : string
  ; title : string
  ; is_page : bool
  ; page : Cache_model.entity_summary option
  ; breadcrumbs : Cache_model.entity_summary list
  }

(* Count UTF-8 code points for search thresholds and editor matching. *)
let utf8_length value =
  let rec loop index length =
    if index = String.length value then length
    else
      loop (index + 1)
        (if Char.code value.[index] land 192 = 128 then length else length + 1)
  in
  loop 0 0

let utf8_chars value =
  let rec loop index start result =
    if index = String.length value then
      if start < index then
        result @ [ String.sub value start (index - start) ]
      else result
    else if index > start && Char.code value.[index] land 192 <> 128 then
      loop (index + 1) index (result @ [ String.sub value start (index - start) ])
    else loop (index + 1) start result
  in
  loop 0 0 []

let clean_str value =
  List.fold_left
    (fun value part -> String_kit.replace value ~match_:part ~replacement:"")
    (String.lowercase_ascii value)
    [ "["; " "; "\\"; "/"; "_"; "]"; "("; ")" ]

let str_len_distance left right =
  let left = float_of_int (utf8_length left) in
  let right = float_of_int (utf8_length right) in
  let longest = max left right in
  let shortest = min left right in
  if longest = 0.0 then 1.0 else 1.0 -. ((longest -. shortest) /. longest)

let fuzzy_score query target =
  let query = clean_str query in
  let target = clean_str target in
  let rec loop query_index target_index mult acc =
    if query_index >= String.length query then
      acc
      +. str_len_distance query target
      +. (if String_kit.starts_with ~prefix:query target then 1010.0
          else if String_kit.includes ~sub:query target then 1000.0
          else 0.0)
      +. (if target_index >= String.length target then 1.0 else 0.0)
    else if target_index >= String.length target then 0.0
    else if query.[query_index] = target.[target_index] then
      loop (query_index + 1) (target_index + 1) (mult + 1)
        (acc +. float_of_int mult)
    else loop query_index (target_index + 1) 1 (acc -. 0.1)
  in
  loop 0 0 1 0.0

let fts_phrase_input input =
  "\"" ^ String_kit.replace input ~match_:"\"" ~replacement:"\"\"" ^ "\"*"

let matches_regex pattern input =
  try
    ignore (Str.search_forward (Str.regexp pattern) input 0);
    true
  with Not_found -> false

let whitespace_char value = List.mem value [ ' '; '\t'; '\n'; '\r'; '\011'; '\012' ]

let dangling_boolean_operator input =
  let input = String.map (fun ch -> if whitespace_char ch then ' ' else ch) input in
  matches_regex "\\(^\\| \\)\\(AND\\|OR\\|NOT\\) *$" input

let word_char value =
  let code = Char.code value in
  (code >= 97 && code <= 122)
  || (code >= 65 && code <= 90)
  || (code >= 48 && code <= 57)
  || code = 95

let has_punctuation query =
  String.exists
    (fun ch -> (not (word_char ch)) && not (whitespace_char ch))
    query

let get_match_input query =
  let input =
    List.fold_left
      (fun input (from, to_) -> String_kit.replace input ~match_:from ~replacement:to_)
      query
      [
        (" and ", " AND ");
        (" & ", " AND ");
        (" or ", " OR ");
        (" | ", " OR ");
        (" not ", " NOT ");
      ]
  in
  let boolean_operator =
    List.exists
      (fun operator -> String_kit.includes ~sub:operator input)
      [ "AND"; "OR"; "NOT" ]
  in
  if dangling_boolean_operator input then fts_phrase_input input
  else if
    has_punctuation query
    && (String_kit.includes ~sub:"\"" input || not boolean_operator
        || String_kit.includes ~sub:"/" query)
  then fts_phrase_input input
  else if query <> input then
    String_kit.replace input ~match_:"," ~replacement:""
  else input

let create path =
  let directory = Filename.dirname path in
  (try
     if not (Sys.file_exists directory) then Unix.mkdir directory 0o755
   with Unix.Unix_error _ -> ());
  search_open path;
  { path }

let row_of_eid db eid =
  let title_for_uuid uuid =
    match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
    | Some eid ->
      (match Graph.entity_title (fun value -> Ok value) db eid with
       | Some title when String.trim title <> "" -> Some title
       | _ -> None)
    | None -> None
  in
  match Graph.uuid_value (Graph.value db eid "block/uuid") with
  | Some uuid ->
    (match Graph.entity_title (fun value -> Ok value) db eid with
     | Some title ->
       let hidden =
         (Graph.value db eid "logseq.property/built-in?" = Some (Ds.Bool true)
          && not (Graph.entity_is_instance_of db eid "logseq.class/Tag"))
         || Option.is_some (Graph.value db eid "block/closed-value-property")
         || Graph.page_is_hidden db eid
       in
       if String.trim title <> "" && (not hidden) && utf8_length title <= 10000
       then
         let is_page =
           Option.is_some
             (Graph.string_value (Graph.value db eid "block/name"))
         in
         let page_uuid =
           if is_page then uuid
           else
             match
               Datascript_value.optional_ref_eid db "block/page"
                 (Graph.value db eid "block/page")
             with
             | Some page_eid ->
               (match
                  Graph.uuid_value (Graph.value db page_eid "block/uuid")
                with
                | Some page_uuid -> page_uuid
                | None -> uuid)
             | None -> uuid
         in
         let title =
           Ref_text.to_text title_for_uuid title_for_uuid title
         in
         let title =
           match Graph.int_value (Graph.value db eid "block/journal-day") with
           | Some day -> title ^ " " ^ string_of_int day
           | None -> title
         in
         Some (uuid, title, page_uuid)
       else None
     | None -> None)
  | None -> None

let row_for_uuid db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> row_of_eid db eid
  | None -> None

let rows_of_db db =
  List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/uuid" ())
  |> List.filter_map (fun (datom : Ds.datom) -> row_of_eid db datom.e)

let referring_uuids db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid ->
    List.of_seq
      (Ds.Db.datoms db Ds.Aevt ~a:"block/refs" ~v:(Ds.Ref eid) ())
    |> List.filter_map (fun (datom : Ds.datom) ->
      Graph.uuid_value (Graph.value db datom.e "block/uuid"))
  | None -> []

let refresh_uuids index before after uuids =
  let uuids =
    if Journal.format before = Journal.format after then uuids
    else
      Seq.fold_left (fun uuids (datom : Ds.datom) ->
        match Graph.uuid_for_eid after datom.e with Some uuid -> uuid :: uuids | None -> uuids)
        uuids (Ds.Db.datoms after Ds.Aevt ~a:"block/journal-day" ()) in
  let seen = Hashtbl.create 32 in
  let affected =
    List.concat_map
      (fun uuid ->
        uuid :: (referring_uuids before uuid @ referring_uuids after uuid))
      uuids
    |> List.filter (fun uuid ->
      if Hashtbl.mem seen uuid then false
      else begin
        Hashtbl.add seen uuid ();
        true
      end)
  in
  let wanted = List.filter_map (fun uuid -> row_for_uuid after uuid) affected in
  if affected <> [] then search_delete index.path affected;
  ignore (if wanted <> [] then search_upsert index.path wanted)

let refresh index db =
  let wanted = rows_of_db db in
  let stored = search_query index.path "select id, page, title from blocks" [] in
  let stored_by_id =
    List.fold_left
      (fun table (id, page, title) ->
        Hashtbl.replace table id (title, page);
        table)
      (Hashtbl.create 128) stored
  in
  let wanted_ids =
    List.fold_left
      (fun table (id, _, _) ->
        Hashtbl.replace table id ();
        table)
      (Hashtbl.create 128) wanted
  in
  let changed =
    List.filter
      (fun (id, title, page) ->
        match Hashtbl.find_opt stored_by_id id with
        | Some (stored_title, stored_page) ->
          stored_title <> title || stored_page <> page
        | None -> true)
      wanted
  in
  let stale =
    List.filter_map
      (fun (id, _, _) ->
        if Hashtbl.mem wanted_ids id then None else Some id)
      stored
  in
  if stale <> [] then search_delete index.path stale;
  ignore (if changed <> [] then search_upsert index.path changed)

let query_rows index sql binds =
  try search_query index.path sql binds with Failure _ -> []

let full_text_rows ~offset ~limit index query =
  let query = String.trim query in
  let query = if String.starts_with ~prefix:"#" query && not (String.exists whitespace_char query)
    then String.sub query 1 (String.length query - 1) else query in
  if query = "" || limit <= 0 then [] else
    try Sql.with_search_db index.path (fun connection ->
      Sql.query connection
        "SELECT id, page, title FROM blocks_fts WHERE title MATCH ? LIMIT ? OFFSET ?"
        [Sqlite3.Data.TEXT (get_match_input query); Sqlite3.Data.INT (Int64.of_int limit);
         Sqlite3.Data.INT (Int64.of_int (max 0 offset))]
        (fun row ->
          let uuid = Sqlite3.column_text row 0 and page_uuid = Sqlite3.column_text row 1 in
          {uuid; page_uuid; title = Sqlite3.column_text row 2; is_page = uuid = page_uuid}))
    with Failure _ -> []

let search limit index query = full_text_rows ~offset:0 ~limit index query

let hydrate_hits db results =
  let entity_eid uuid = Ds.entid db "block/uuid" (Ds.Uuid uuid) in
  let plain uuid = Ok uuid in
  List.map
    (fun (result : search_result) ->
      let page =
        if result.is_page then None
        else
          match entity_eid result.page_uuid with
          | Some eid -> Graph.page_summary plain db eid
          | None -> None
      in
      let breadcrumbs =
        if result.is_page then []
        else
          match entity_eid result.uuid with
          | Some eid -> Graph.breadcrumbs plain db eid
          | None -> []
      in
      {
        uuid = result.uuid;
        title = (match entity_eid result.uuid with
          | Some eid when Option.fold ~none:false ~some:Journal.valid_day
              (Graph.int_value (Graph.value db eid "block/journal-day")) ->
            Option.value ~default:result.title (Graph.entity_title plain db eid)
          | _ -> result.title);
        is_page = result.is_page;
        page;
        breadcrumbs;
      })
    results

(* Reference completion also accepts literal short page names. The global
   search UI uses the MATCH-only paged API below. *)
let search_hits limit index db query =
  let query = String.trim query in
  if limit <= 0 || query = "" then []
  else if utf8_length query < 3 then
    let query = Dev_query.Unicode.lowercase query in
    Ds.Db.datoms db Ds.Aevt ~a:"block/name" ()
    |> Seq.filter_map (fun (datom : Ds.datom) ->
      if Graph.page_is_hidden db datom.e then None else
      Option.bind (Graph.page_summary (fun value -> Ok value) db datom.e) (fun page ->
        if String_kit.includes ~sub:query (Dev_query.Unicode.lowercase page.title) then
          Some {uuid = page.uuid; title = page.title; is_page = true; page = None; breadcrumbs = []}
        else None))
    |> Seq.take limit |> List.of_seq
  else hydrate_hits db (search limit index query)

(* Bound the MATCH window before reading graph context, as on desktop. *)
let search_hits_page ~offset ~limit index db query =
  if limit <= 0 then [], false else
    let limit = min 100 limit in
    let results = full_text_rows ~offset ~limit:(limit + 1) index query in
    let rec take n acc = function
      | [] -> List.rev acc, false
      | _ when n = 0 -> List.rev acc, true
      | hit :: rest -> take (n - 1) (hit :: acc) rest in
    let page, more = take limit [] results in
    hydrate_hits db page, more
