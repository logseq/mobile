module J = Yojson.Basic
let member fields key = Option.value ~default:`Null (List.assoc_opt key fields)
let string = function `String value -> Some value | _ -> None

let parse_url value =
  let value = String.trim value in
  match String_kit.index_of ~sub:"://" value with
  | Some colon when List.mem (String.lowercase_ascii (String.sub value 0 colon)) ["http"; "https"] ->
    let start = colon + 3 in
    let rec boundary index = if index >= String.length value || List.mem value.[index] ['/'; '?'; '#'] then index else boundary (index + 1) in
    let stop = boundary start in
    let authority = String.sub value start (stop - start) in
    let authority = match String.rindex_opt authority '@' with
      | Some index -> String.sub authority (index + 1) (String.length authority - index - 1)
      | None -> authority in
    let host = String.lowercase_ascii (List.hd (String.split_on_char ':' authority)) in
    if host = "" || String.exists (fun c -> Char.code c <= 32 || c = '\\') value then None
    else Some (host, String.sub value stop (String.length value - stop))
  | _ -> None

let safe_url value = Option.map (fun _ -> String.trim value) (parse_url value)

let decode value =
  let result = Buffer.create (String.length value) in
  let rec loop i = if i < String.length value then
    if value.[i] = '%' && i + 2 < String.length value then
      match int_of_string_opt ("0x" ^ String.sub value (i + 1) 2) with
      | Some n -> Buffer.add_char result (Char.chr n); loop (i + 3)
      | None -> Buffer.add_char result value.[i]; loop (i + 1)
    else (Buffer.add_char result value.[i]; loop (i + 1)) in
  loop 0; Buffer.contents result

let query value =
  match String.index_opt value '?' with
  | None -> []
  | Some index ->
    let value = String.sub value (index + 1) (String.length value - index - 1) in
    let value = List.hd (String.split_on_char '#' value) in
    String.split_on_char '&' value |> List.filter_map (fun pair ->
      match String.index_opt pair '=' with
      | None -> None
      | Some index -> Some (decode (String.sub pair 0 index), decode (String.sub pair (index + 1) (String.length pair - index - 1))))

let youtube_id value =
  match parse_url value with
  | Some (host, path) when List.mem host ["youtu.be"; "www.youtu.be"; "youtube.com"; "www.youtube.com";
      "m.youtube.com"; "youtube-nocookie.com"; "www.youtube-nocookie.com"] ->
    let clean = List.hd (String.split_on_char '?' (List.hd (String.split_on_char '#' path))) in
    let parts = String.split_on_char '/' clean |> List.filter (fun value -> value <> "") in
    let id = if host = "youtu.be" || host = "www.youtu.be" then List.nth_opt parts 0
      else match parts with
        | ["watch"] -> List.assoc_opt "v" (query path)
        | ("embed" | "shorts" | "live") :: id :: _ -> Some (decode id)
        | _ -> None in
    (match id with Some id when String.length id = 11 && String.for_all (function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true | _ -> false) id -> Some id | _ -> None)
  | _ -> None

let embed_url ?seconds value =
  match youtube_id value with
  | Some id ->
    let seconds = match seconds with Some value when value >= 0 -> Some value | _ ->
      let q = query value in List.find_map (fun key -> Option.bind (List.assoc_opt key q) int_of_string_opt) ["start"; "t"] in
    Some ("https://www.youtube-nocookie.com/embed/" ^ id ^ "?playsinline=1"
      ^ (match seconds with Some seconds when seconds >= 0 -> "&start=" ^ string_of_int seconds | _ -> ""))
  | None -> (match parse_url value with Some ("player.vimeo.com", _) -> safe_url value | _ -> None)

let headers value = if youtube_id value <> None then `Assoc ["Referer", `String "https://logseq.com/"] else `Assoc []

let resolve_markup ?preceding input =
  let rec nodes current = function
    | [] -> [], current
    | node :: rest ->
      let node, current = resolve current node in
      let rest, current = nodes current rest in
      node :: rest, current
  and resolve current = function
    | `Assoc fields ->
      let kind = member fields "type" in
      let url = string (member fields "url") in
      let put key value fields =
        if List.mem_assoc key fields then List.map (fun (name, previous) -> name, if name = key then value else previous) fields
        else fields @ [key, value] in
      let optional = function Some value -> `String value | None -> `Null in
      let fields, current =
        if kind = `String "video" || kind = `String "iframe" then
          let valid = Option.bind url safe_url in
          let embed = if kind = `String "iframe" then valid else Option.bind valid embed_url in
          let fields = put "url" (optional valid) fields in
          let fields = match embed with None -> fields | Some embed ->
            put "embedURL" (`String embed) (put "mediaHeaders" (headers embed)
              (put "positionParameter" (`String "start") fields)) in
          fields, (match valid with Some url when youtube_id url <> None -> Some url | _ -> current)
        else if kind = `String "youtubeTimestamp" then
          let target = match Option.bind url (fun url -> if youtube_id url <> None then Some url else None) with
            | Some _ as value -> value | None -> current in
          let seconds = match string (member fields "style") with Some value -> int_of_string_opt value | None -> None in
          let fields = put "url" (optional target) fields in
          let fields = match seconds with Some seconds when seconds >= 0 ->
            let fields = put "seconds" (`Int seconds) fields in
            (match Option.bind target (embed_url ~seconds) with None -> fields | Some url ->
              put "embedURL" (`String url) (put "mediaHeaders" (headers url) fields))
            | _ -> fields in
          fields, current
        else fields, current in
      let fields, current = match member fields "children" with
        | `List children -> let children, current = nodes current children in put "children" (`List children) fields, current
        | _ -> fields, current in
      `Assoc fields, current
    | value -> value, current in
  match input with `List values -> let values, current = nodes preceding values in `List values, current
    | _ -> input, preceding

let first_timestamp_target input =
  let rec first = function
    | [] -> None
    | `Assoc fields :: rest ->
      if member fields "type" = `String "youtubeTimestamp" then Some (string (member fields "url"))
      else (match member fields "children" with
        | `List children -> (match first children with Some _ as value -> value | None -> first rest)
        | _ -> first rest)
    | _ :: rest -> first rest in
  match input with `List values -> Option.join (first values) | _ -> None
