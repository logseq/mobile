module Ds = Datascript
module Ops = Pending_ops
module J = Yojson.Basic
module Read = Graph_read
let ( let* ) = Result.bind
let field key = function `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields) | _ -> `Null
let text = function `String text -> text | _ -> ""
let number = function `Int value -> float_of_int value | `Float value -> value | _ -> nan
let integer = function `Int value -> value | _ -> 0
let selected_text source =
  let output = Buffer.create (String.length source) in
  let rec loop index =
    if index < String.length source then
      if source.[index] = '\r' || source.[index] = '\n' then begin
        let next = ref (index + 1) in
        while !next < String.length source && (source.[!next] = '\r' || source.[!next] = '\n') do incr next done;
        let length = Buffer.length output in
        if length > 0 && Buffer.nth output (length - 1) = '-' then Buffer.truncate output (length - 1)
        else if !next < String.length source then
          (match source.[!next] with 'a' .. 'z' | 'A' .. 'Z' | '_' -> Buffer.add_char output ' ' | _ -> ());
        loop !next
      end else (Buffer.add_char output source.[index]; loop (index + 1)) in
  loop 0;
  Buffer.contents output
let valid_uuid value =
  let rec loop index = index = 36 ||
    ((if List.mem index [8; 13; 18; 23] then value.[index] = '-'
      else match value.[index] with '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
     && loop (index + 1)) in
  String.length value = 36 && loop 0
let value = Read.value
let uuid db id = match value db id "block/uuid" with Some (Ds.Uuid uuid) -> Some uuid | _ -> None
let eid db uuid = Ds.entid db "block/uuid" (Ds.Uuid uuid)
let ref_id db id attr = Datascript_value.optional_ref_eid db attr (value db id attr)
let live db id = value db id "logseq.property/deleted-at" = None
  && ref_id db id "block/page" <> Read.recycle_page_eid db

let asset db asset_uuid = match eid db asset_uuid with
  | Some id when live db id && Read.entity_is_instance_of db id "logseq.class/Asset"
      && (match value db id "logseq.property.asset/type" with
        | Some (Ds.String kind) -> List.mem (String.lowercase_ascii kind) ["pdf"; "application/pdf"]
        | _ -> false) -> Ok id
  | _ -> Error "The PDF asset is unavailable"

let rec json = function
  | Ds.Nil -> `Null | Ds.String value | Ds.Uuid value | Ds.Keyword value -> `String value
  | Ds.Int64 value | Ds.Instant value -> `Int (Int64.to_int value)
  | Ds.Float value -> `Float value | Ds.Bool value -> `Bool value
  | Ds.Vector values | Ds.Set values -> `List (List.map json values)
  | Ds.Map entries -> `Assoc (List.filter_map (function
      | Ds.Keyword key, value | Ds.String key, value -> Some (key, json value) | _ -> None) entries)
  | _ -> `Null

let rec semantic = function
  | `Null -> Ops.Nil_value | `String value -> Ops.String_value value
  | `Int value -> Ops.Int_value value | `Float value -> Ops.Float_value value
  | `Bool value -> Ops.Bool_value value
  | `List values -> Ops.Vector_value (List.map semantic values)
  | `Assoc fields -> Ops.Map_value (List.map (fun (key, value) ->
      key, if key = "id" then Ops.Uuid_value (text value) else semantic value) fields)

let annotation db asset_id id = live db id
  && Read.entity_is_instance_of db id "logseq.class/Pdf-annotation"
  && ref_id db id "logseq.property/asset" = Some asset_id

let read db ~asset_uuid =
  let* asset_id = asset db asset_uuid in
  let highlights = Datascript_value.datoms_by_ref db Ds.Avet "logseq.property/asset" asset_id
    |> Seq.filter_map (fun (datom : Ds.datom) ->
      if annotation db asset_id datom.e then
        match value db datom.e "logseq.property.pdf/hl-value" with
        | Some (Ds.Map _ as highlight) ->
          let highlight = json highlight in
          let color = Option.bind (ref_id db datom.e "logseq.property.pdf/hl-color")
            (fun id -> match value db id "block/title" with Some (Ds.String color) -> Some color | _ -> None) in
          let properties = match field "properties" highlight with `Assoc fields -> fields | _ -> [] in
          let properties = match color with Some color -> ("color", `String color) :: List.remove_assoc "color" properties | None -> properties in
          (match highlight with `Assoc fields -> Some (`Assoc
            (("properties", `Assoc properties) :: List.remove_assoc "properties" fields)) | _ -> None)
        | _ -> None
      else None) |> List.of_seq in
  let highlights = List.sort (fun a b ->
    let pages = compare (integer (field "page" a)) (integer (field "page" b)) in
    if pages <> 0 then pages else compare (text (field "id" a)) (text (field "id" b))) highlights in
  let page = match value db asset_id "logseq.property.asset/last-visit-page" with
    | Some (Ds.Int64 page) -> max 1 (Int64.to_int page) | _ -> 1 in
  Ok (`Assoc ["assetUuid", `String asset_uuid; "highlights", `List highlights; "page", `Int page])

let valid_rect rect =
  let x1 = number (field "x1" rect) and y1 = number (field "y1" rect)
  and x2 = number (field "x2" rect) and y2 = number (field "y2" rect)
  and width = number (field "width" rect) and height = number (field "height" rect) in
  List.for_all Float.is_finite [x1; y1; x2; y2; width; height]
  && width > 0. && height > 0. && x1 >= 0. && y1 >= 0.
  && x2 > x1 && y2 > y1 && x2 <= width +. 0.01 && y2 <= height +. 0.01

let reference db block_uuid =
  let rec resolve budget id =
    if budget = 0 || not (live db id) then None else
    match ref_id db id "block/link" with
    | Some source -> resolve (budget - 1) source
    | None ->
      match ref_id db id "logseq.property/asset", uuid db id with
      | Some asset_id, Some block_uuid when annotation db asset_id id ->
        (match uuid db asset_id, Read.int_value (value db id "logseq.property.pdf/hl-page") with
         | Some asset_uuid, Some page when page > 0 && Result.is_ok (asset db asset_uuid) ->
           let title = Option.value ~default:"PDF" (Read.string_value (value db asset_id "block/title")) in
           Some (`Assoc ["id", `String block_uuid; "assetUuid", `String asset_uuid;
             "assetTitle", `String title; "page", `Int page])
         | _ -> None)
      | _ -> None in
  Option.bind (eid db block_uuid) (resolve 16)

let expected db block_uuid attr = Option.bind (eid db block_uuid) (fun id ->
  match ref_id db id attr with
  | Some target -> (match value db target "db/ident" with
      | Some (Ds.Keyword ident) -> Some (Ops.Ref_ident ident)
      | _ -> Option.map (fun uuid -> Ops.Ref_uuid uuid) (uuid db target))
  | None -> Option.bind (value db id attr) (fun value -> Result.to_option (Ops.semantic_value_from_datascript value)))
let changes db uuid fields = Ops.Set_properties {uuid; changes = List.map (fun (attr, value) ->
  {Ops.attr; expected = expected db uuid attr; value = Some value}) fields}
let same db uuid attr next = Pending_projection.semantic_value_equal db
  (Option.bind (eid db uuid) (fun id -> value db id attr)) (Some next)

let color_value db color =
  if not (List.mem color ["yellow"; "red"; "green"; "blue"; "purple"]) then Error "Unsupported highlight color"
  else match Ds.entid db "db/ident" (Ds.Keyword ("logseq.property/color." ^ color)) with
    | Some _ -> Ok (Ops.Ref_ident ("logseq.property/color." ^ color))
    | None -> Error "The graph's PDF highlight colors are unavailable"

let mutation db ~now input =
  let asset_uuid = text (field "assetUuid" input) in
  let* asset_id = asset db asset_uuid in
  match text (field "action" input) with
  | "recolor" ->
    let id = text (field "id" input) in
    let* color = color_value db (text (field "color" input)) in
    (match eid db id with
     | Some existing when annotation db asset_id existing ->
       if same db id "logseq.property.pdf/hl-color" color then Ok None
       else Ok (Some (changes db id ["logseq.property.pdf/hl-color", color]))
     | _ -> Error "The annotation is unavailable for this PDF")
  | "visit" ->
    let page = integer (field "page" input) in
    if page <= 0 then Error "A PDF page must be positive"
    else if same db asset_uuid "logseq.property.asset/last-visit-page" (Ops.Int_value page) then Ok None
    else Ok (Some (changes db asset_uuid ["logseq.property.asset/last-visit-page", Ops.Int_value page]))
  | "delete" ->
    let id = text (field "id" input) in
    if id = "" then Error "An annotation ID is required" else
    (match eid db id with
     | None -> Ok None
     | Some existing when not (live db existing) -> Ok None
     | Some existing when annotation db asset_id existing -> Ok (Some (Ops.Delete_blocks {uuids = [id]}))
     | Some _ -> Error "The annotation belongs to another asset")
  | "save" ->
    let highlight = field "highlight" input in
    let id = text (field "id" highlight) in
    let content = selected_text (text (field "text" (field "content" highlight))) in
    let highlight = match highlight with
      | `Assoc fields ->
        let content_fields = match field "content" highlight with `Assoc fields -> fields | _ -> [] in
        `Assoc (("content", `Assoc (("text", `String content) :: List.remove_assoc "text" content_fields))
          :: List.remove_assoc "content" fields)
      | value -> value in
    let page = integer (field "page" highlight) in
    let color = text (field "color" (field "properties" highlight)) in
    let position = field "position" highlight in
    let rects = match field "rects" position with `List values -> values | _ -> [] in
    if not (valid_uuid id) then Error "An annotation requires a valid UUID"
    else if page <= 0 || integer (field "page" position) <> page then Error "The annotation page is invalid"
    else if String.trim content = "" then Error "Select PDF text before highlighting"
    else if not (List.mem color ["yellow"; "red"; "green"; "blue"; "purple"]) then Error "Unsupported highlight color"
    else if rects = [] || List.length rects > 10000 || not (valid_rect (field "bounding" position))
      || not (List.for_all valid_rect rects) then Error "The annotation geometry is invalid"
    else
      let* color_id = color_value db color in
      let fields = ["logseq.property/ls-type", Ops.Keyword_value "annotation";
        "logseq.property/asset", Ops.Ref_uuid asset_uuid;
        "logseq.property.pdf/hl-color", color_id;
        "logseq.property.pdf/hl-page", Ops.Int_value page;
        "logseq.property.pdf/hl-value", semantic highlight] in
      (match eid db id with
       | Some existing when not (annotation db asset_id existing) -> Error "The annotation UUID is already used"
       | Some _ ->
         if List.for_all (fun (attr, next) -> same db id attr next) fields then Ok None
         else Ok (Some (changes db id fields))
       | None ->
         let* page_uuid = match ref_id db asset_id "block/page" with
           | Some page_id -> (match uuid db page_id with Some uuid -> Ok uuid | None -> Error "The PDF page is unavailable")
           | None -> Ok asset_uuid in
         let* order = Fractional_order.between (Read.last_order db "block/parent" asset_id) None in
         let* tag_uuid = match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Pdf-annotation") with
           | Some tag_id -> (match uuid db tag_id with Some uuid -> Ok uuid | None -> Error "The annotation class has no UUID")
           | None -> Error "The graph's PDF annotation class is unavailable" in
         Ok (Some (Ops.Atomic [Ops.Insert_block {uuid = id; title = content; page_uuid;
           parent_uuid = asset_uuid; order; created_at = now};
           Ops.Add_tag {uuid = id; tag_uuid}; changes db id fields])))
  | _ -> Error "Unsupported PDF annotation action"
