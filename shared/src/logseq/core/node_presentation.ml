module Ds = Datascript
module Read = Graph_read
module M = Markup

external calculate_native : string -> string = "logseq_calculator_results"

let calculator_results source =
  let fallback () = String.split_on_char '\n' source |> List.map (fun line ->
    if String.trim line = "" then "" else "Error") in
  try match Yojson.Basic.from_string (calculate_native source) with
    | `List results when List.length results = List.length (String.split_on_char '\n' source) ->
      List.map (function `String value -> value | _ -> "Error") results
    | _ -> fallback ()
  with _ -> fallback ()

let calculator source =
  List.map2 (fun line result -> if result = "" then line else line ^ "  = " ^ result)
    (String.split_on_char '\n' source) (calculator_results source) |> String.concat "\n"

let discussion_kind db eid =
  if Read.is_comments_area db eid then "thread"
  else if Read.is_comment db eid then "comment"
  else ""

let reaction_emoji id =
  match Reaction_emoji.find id with
  | Some emoji -> emoji.glyph
  | None -> id

let markup db eid ~title ~references ~tags =
  let parsed = match Read.display_type_for_eid db eid with
    | Some "code" ->
      let language = Read.string_value (Read.value db eid "logseq.property.code/lang") in
      [M.Markup_code_block (language, if language = Some "calc" then calculator title else title)]
    | Some "math" -> [M.Markup_math (title, true)]
    | Some "quote" -> [M.Markup_quote (M.parse references tags title)]
    | _ -> M.parse references tags title in
  match Read.int_value (Read.value db eid "logseq.property/heading") with
  | Some level when level >= 1 && level <= 6 ->
    let content = List.concat_map (function
      | M.Markup_emphasis (style, children) when String.starts_with ~prefix:"heading-" style -> children
      | node -> [node]) parsed in
    [M.Markup_emphasis ("heading-" ^ string_of_int level, content)]
  | _ -> parsed

let preview db =
  let cache = Hashtbl.create 16 in
  let decode title = Ok title in
  let build eid =
    let source = match Read.block ~with_breadcrumbs:false decode db eid with
      | Some _ as block -> block
      | None -> Read.page_block decode db eid in
    match source with
    | None -> `Null
    | Some block ->
      let resolve uuid =
        Option.bind (Ds.entid db "block/uuid" (Ds.Uuid uuid)) (fun target ->
          if Read.recycled db target || Read.value db target "logseq.property/deleted-at" <> None then None
          else Read.string_value (Read.value db target "block/title")) in
      let uuids title = Ref_text.references title |> List.filter_map (fun reference ->
        if Ref_text.is_uuid reference.Ref_text.name then Some reference.name else None)
        |> List.sort_uniq String.compare in
      let hide_uuid uuid = if Ref_text.is_uuid uuid then Some "Unavailable reference" else None in
      let reference_title uuid =
        Option.bind (resolve uuid) (fun title ->
          let title = Ref_text.to_text hide_uuid hide_uuid title in
          if String_kit.is_blank title || Ref_text.is_uuid (String.trim title) then None else Some title) in
      let extra = uuids block.title |> List.filter_map (fun uuid ->
        Option.map (fun title -> {Cache_model.uuid; title}) (reference_title uuid)) in
      let missing uuid = if Ref_text.is_uuid uuid && not (List.exists (fun (item : Cache_model.entity_summary) ->
        item.uuid = uuid) extra) then hide_uuid uuid else None in
      let title = if List.mem block.display_type [Some "code"; Some "math"] then block.title
        else if Ref_text.is_uuid (String.trim block.title) then ""
        else Ref_text.to_text missing missing block.title in
      let references = extra @ block.references in
      let tags = extra @ block.tags in
      let nodes = markup db eid ~title ~references ~tags in
      let display_title = if block.is_asset then title else M.plain_text nodes in
      `Assoc (["uuid", `String block.uuid; "title", `String title;
        "displayTitle", `String display_title; "markup", M.to_yojson nodes;
        "isAsset", `Bool block.is_asset]
        @ List.filter_map (fun (name, value) -> Option.map (fun value -> name, `String value) value)
          ["assetType", block.asset_type; "assetChecksum", block.asset_checksum; "localPath", block.local_path]) in
  fun eid -> match Hashtbl.find_opt cache eid with
    | Some content -> content
    | None -> let content = build eid in Hashtbl.add cache eid content; content

let decorate ?actor db =
  let preview = preview db in
  let discussions = Hashtbl.create 16 in
  let discussion eid = match Hashtbl.find_opt discussions eid with
    | Some fields -> fields
    | None ->
      let reactions = Collaboration.reaction_summaries db ~actor eid |> List.map (fun fields ->
        let id = match List.assoc_opt "id" fields with Some (`String id) -> id | _ -> "" in
        `Assoc (("emoji", `String (reaction_emoji id)) :: fields)) in
      let threads = Collaboration.comment_threads db ~actor ~preview eid in
      let fields = (if reactions = [] then [] else ["reactions", `List reactions])
        @ (if threads = [] then [] else ["commentThreads", `List threads]) in
      Hashtbl.add discussions eid fields;
      fields in
  let numbers = Hashtbl.create 8 in
  let dates = Hashtbl.create 16 in
  let task_dates uuid eid = match Hashtbl.find_opt dates uuid with
    | Some value -> value
    | None ->
      let properties = List.filter_map (fun attr ->
        match Read.value db eid attr with
        | None -> None
        | Some _ ->
          let property = Result_view.property_json ~include_candidates:false db ~owner:uuid ~attr ~encode_block:(fun _ -> `Null) in
          (match property with `Assoc fields when List.assoc_opt "text" fields <> Some (`String "") -> Some property | _ -> None))
        ["logseq.property/scheduled"; "logseq.property/deadline"] in
      let value = if properties = [] then `Null else `Assoc ["ownerUuid", `String uuid; "properties", `List properties] in
      Hashtbl.add dates uuid value; value in
  let list_number eid =
    let numbered eid = match Read.ref_eids db eid "logseq.property/order-list-type" with
      | value :: _ -> Read.string_value (Read.value db value "block/title") = Some "number"
      | _ -> Read.string_value (Read.value db eid "logseq.property/order-list-type") = Some "number" in
    if not (numbered eid) then None else
      match Read.ref_eids db eid "block/parent" with
      | [] -> Some 1
      | parent :: _ ->
        if not (Hashtbl.mem numbers parent) then begin
          let siblings = Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" parent |> List.of_seq
            |> List.map (fun (d : Ds.datom) -> d.e)
            |> List.sort (fun a b -> compare (Read.string_value (Read.value db a "block/order"), a)
                (Read.string_value (Read.value db b "block/order"), b)) in
          let table = Hashtbl.create 16 in
          ignore (List.fold_left (fun count eid -> if numbered eid then
            (Hashtbl.add table eid count; count + 1) else 1) 1 siblings);
          Hashtbl.add numbers parent table
        end;
        Hashtbl.find_opt (Hashtbl.find numbers parent) eid in
  let markup eid =
    let title = Option.value ~default:"" (Read.string_value (Read.value db eid "block/title")) in
    let summaries attr = Read.entity_summaries (fun x -> Ok x) db eid attr in
    markup db eid ~title ~references:(summaries "block/refs") ~tags:(summaries "block/tags") in
  let rec embed_source seen budget eid =
    if budget <= 0 || List.mem eid seen then None
    else match Read.ref_eids db eid "block/link" with
      | source :: _ -> embed_source (eid :: seen) (budget - 1) source
      | [] -> Some (eid, eid :: seen) in
  let decode_title title = Ok title in
  let read_block eid =
    match Read.block ~with_breadcrumbs:false decode_title db eid with
    | Some _ as block -> block
    | None -> Read.page_block decode_title db eid in
  let children parent source =
    let definitions = Read.ref_eids db source "logseq.property/query" in
    let definitions = List.filter_map (Read.uuid_for_eid db) definitions in
    Read.children_for_block decode_title db parent
    |> List.filter (fun (block : Cache_model.block) -> not (List.mem block.uuid definitions)) in
  let rec decorate path remaining in_embed uuid encoded =
    match Ds.entid db "block/uuid" (Ds.Uuid uuid), encoded with
    | Some eid, `Assoc fields ->
      let embedded = Read.ref_eids db eid "block/link" <> [] in
      let resolved =
        if embedded then embed_source path 16 eid
        else Some (eid, eid :: path) in
      let body = Option.fold ~none:eid ~some:fst resolved in
      let decorated = embedded
        || Read.value db body "logseq.property/heading" <> None
        || Read.value db body "logseq.property.code/lang" <> None in
      let fields = if not decorated then fields else
        let nodes = if resolved = None then [M.Markup_text "Embedded node unavailable"] else markup body in
        ("markup", M.to_yojson nodes) :: List.remove_assoc "markup" fields in
      let fields = match resolved with
        | Some (source, path) when in_embed || embedded ->
          (match read_block source with
           | None -> fields
           | Some block ->
             let rows = if remaining = 0 then [] else
               children block source |> List.filter_map (fun (child : Cache_model.block) ->
                 match Ds.entid db "block/uuid" (Ds.Uuid child.uuid) with
                 | Some child_eid when not (List.mem child_eid path) ->
                   let collapsed = Read.value db child_eid "block/collapsed?" = Some (Ds.Bool true) in
                   let encoded = match Rpc_encode.block_json child with
                     | `Assoc fields -> `Assoc (("isCollapsed", `Bool collapsed) :: fields)
                     | value -> value in
                   Some (decorate path (remaining - 1) true child.uuid encoded)
                 | _ -> None) in
             let fields = if rows = [] then fields else ("embedChildren", `List rows) :: fields in
             if embedded then
               ("sourceTitle", `String block.title) :: ("embedSourceUuid", `String block.uuid) :: fields
             else fields)
        | _ -> fields in
      let fields = match Pdf_annotation.reference db uuid with
        | Some reference -> ("pdfAnnotation", reference) :: fields | None -> fields in
      let fields =
        if List.assoc_opt "isAsset" fields <> Some (`Bool true) then fields
        else
          match Read.int_value (Read.value db body "logseq.property.asset/width"),
                Read.int_value (Read.value db body "logseq.property.asset/height") with
          | Some width, Some height when width > 0 && height > 0 ->
            ("imageDimensions", `Assoc ["width", `Int width; "height", `Int height]) :: fields
          | _ -> fields in
      `Assoc (("discussionKind", `String (discussion_kind db eid))
        :: ("isTask", `Bool (Read.entity_is_instance_of db eid "logseq.class/Task"))
        :: ("isEmbed", `Bool embedded) :: ("taskDates", task_dates uuid eid) :: (match list_number eid with Some n -> ["listNumber", `Int n] | None -> [])
         @ discussion body @ fields)
    | _ -> encoded in
  decorate [] 128 false
