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
  let tagged eid ident = List.exists (fun tag ->
    Read.value db tag "db/ident" = Some (Ds.Keyword ident)) (Read.ref_eids db eid "block/tags") in
  if tagged eid "logseq.class/Comments" then "thread"
  else if tagged eid "logseq.class/Comment" || List.exists (fun parent -> tagged parent "logseq.class/Comments")
    (Read.ref_eids db eid "block/parent") then "comment"
  else ""

let reaction_emoji id =
  match String.lowercase_ascii id with
  | "+1" | "thumbsup" | "thumbs_up" -> "👍"
  | "-1" | "thumbsdown" | "thumbs_down" -> "👎"
  | "heart" -> "❤️" | "tada" -> "🎉" | "smile" -> "😄"
  | "laughing" | "satisfied" -> "😆" | "joy" -> "😂" | "eyes" -> "👀"
  | "rocket" -> "🚀" | "fire" -> "🔥" | "thinking_face" -> "🤔"
  | "white_check_mark" -> "✅" | "clap" -> "👏"
  | _ -> id

let reactions db eid =
  let counts = Hashtbl.create 8 in
  Seq.iter (fun (datom : Ds.datom) ->
    if Read.value db datom.e "logseq.property/deleted-at" = None then
      match Read.string_value (Read.value db datom.e "logseq.property.reaction/emoji-id") with
      | Some id -> Hashtbl.replace counts id (1 + Option.value ~default:0 (Hashtbl.find_opt counts id))
      | None -> ()) (Datascript_value.datoms_by_ref db Ds.Aevt "logseq.property.reaction/target" eid);
  Hashtbl.fold (fun id count acc -> (id, count) :: acc) counts []
  |> List.sort (fun (a, x) (b, y) -> let order = compare y x in if order = 0 then String.compare a b else order)
  |> List.map (fun (id, count) -> `Assoc ["id", `String id; "emoji", `String (reaction_emoji id); "count", `Int count])

let decorate db =
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
  let rec markup seen budget eid =
    if budget <= 0 || List.mem eid seen then [M.Markup_text "Embedded node unavailable"] else
    let title = Option.value ~default:"" (Read.string_value (Read.value db eid "block/title")) in
    let summaries attr = Read.entity_summaries (fun x -> Ok x) db eid attr in
    let parsed = match Read.ref_eids db eid "block/link" with
      | source :: _ ->
        let definitions = Read.ref_eids db source "logseq.property/query" in
        let children = Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" source
          |> Seq.filter_map (fun (d : Ds.datom) ->
            if List.mem d.e definitions then None else Some d.e)
          |> List.of_seq
          |> List.sort (fun a b -> compare (Read.string_value (Read.value db a "block/order"), a)
            (Read.string_value (Read.value db b "block/order"), b)) in
        markup (eid :: seen) (budget - 1) source @
          List.concat_map (fun child -> M.Markup_text "\n" :: markup (eid :: seen) (budget - 1) child) children
      | [] -> (match Read.display_type_for_eid db eid with
        | Some "code" ->
          let language = Read.string_value (Read.value db eid "logseq.property.code/lang") in
          [M.Markup_code_block (language, if language = Some "calc" then calculator title else title)]
        | Some "math" -> [M.Markup_math (title, true)]
        | Some "quote" -> [M.Markup_quote (M.parse (summaries "block/refs") (summaries "block/tags") title)]
        | _ -> M.parse (summaries "block/refs") (summaries "block/tags") title) in
    match Read.int_value (Read.value db eid "logseq.property/heading") with
    | Some level when level >= 1 && level <= 6 -> [M.Markup_emphasis ("heading-" ^ string_of_int level, parsed)]
    | _ -> parsed in
  let rec source_title seen budget eid =
    if budget <= 0 || List.mem eid seen then None
    else match Read.ref_eids db eid "block/link" with
      | source :: _ -> source_title (eid :: seen) (budget - 1) source
      | [] -> Read.string_value (Read.value db eid "block/title") in
  fun uuid encoded -> match Ds.entid db "block/uuid" (Ds.Uuid uuid), encoded with
    | Some eid, `Assoc fields ->
      let embedded = Read.ref_eids db eid "block/link" <> [] in
      let decorated = embedded
        || Read.value db eid "logseq.property/heading" <> None
        || Read.value db eid "logseq.property.code/lang" <> None in
      let fields = if decorated then ("markup", M.to_yojson (markup [] 16 eid)) :: List.remove_assoc "markup" fields else fields in
      let fields = if embedded then match source_title [] 16 eid with
        | Some title -> ("sourceTitle", `String title) :: fields
        | None -> fields
        else fields in
      let fields = match Pdf_annotation.reference db uuid with
        | Some reference -> ("pdfAnnotation", reference) :: fields | None -> fields in
      `Assoc (("discussionKind", `String (discussion_kind db eid))
        :: ("reactions", `List (reactions db eid))
        :: ("isEmbed", `Bool embedded) :: ("taskDates", task_dates uuid eid) :: (match list_number eid with Some n -> ["listNumber", `Int n] | None -> []) @ fields)
    | _ -> encoded
