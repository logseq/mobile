module Ds = Datascript
module Read = Graph_read
module M = Markup

let calculator source =
  let vars = Hashtbl.create 8 in
  let tokenize line =
    let re = Str.regexp "[0-9]+\\.?[0-9]*\\([eE][-+]?[0-9]+\\)?\\|[A-Za-z_][A-Za-z_0-9]*\\|[+*/^()=-]" in
    let rec loop index acc =
      if index >= String.length line then ref (List.rev acc)
      else if line.[index] = ' ' || line.[index] = '\t' then loop (index + 1) acc
      else if Str.string_match re line index then
        let token = Str.matched_string line in loop (index + String.length token) (token :: acc)
      else failwith "Unexpected input" in loop 0 [] in
  let peek s = match !s with x :: _ -> x | [] -> "" in
  let take s = match !s with x :: xs -> s := xs; x | [] -> failwith "Expected a number" in
  let rec expression s = sum (product s) s
  and sum left s = match peek s with
    | "+" -> ignore (take s); sum (left +. product s) s
    | "-" -> ignore (take s); sum (left -. product s) s
    | _ -> left
  and product s = factor (power s) s
  and factor left s = match peek s with
    | "*" -> ignore (take s); factor (left *. power s) s
    | "/" -> ignore (take s); factor (left /. power s) s
    | _ -> left
  and power s = let left = atom s in match peek s with
    | "^" -> ignore (take s); left ** power s | _ -> left
  and atom s = match take s with
    | "-" -> -. atom s | "+" -> atom s
    | "(" -> let n = expression s in if take s = ")" then n else failwith "Expected )"
    | token -> (match float_of_string_opt token with
      | Some n -> n
      | None -> if peek s = "(" then begin
          ignore (take s); let n = expression s in
          if take s <> ")" then failwith "Expected )";
          match token with "sqrt" -> sqrt n | "sin" -> sin n | "cos" -> cos n | "tan" -> tan n
          | "abs" -> abs_float n | "round" -> Float.round n | "log" -> log n | _ -> failwith "Unknown function"
        end else if token = "pi" then Float.pi else if token = "e" then exp 1. else Hashtbl.find vars token) in
  String.split_on_char '\n' source |> List.map (fun line ->
    if String.trim line = "" then line else try
      let s = tokenize line in
      let name = match !s with name :: "=" :: rest -> s := rest; Some name | _ -> None in
      let n = expression s in
      if !s <> [] || not (Float.is_finite n) then failwith "Invalid expression";
      Option.iter (fun name -> Hashtbl.replace vars name n) name;
      line ^ "  = " ^ Printf.sprintf "%.10g" n
    with _ -> line ^ "  = Error") |> String.concat "\n"

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
        let children = Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" source |> List.of_seq
          |> List.map (fun (d : Ds.datom) -> d.e)
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
      `Assoc (("isEmbed", `Bool embedded) :: ("taskDates", task_dates uuid eid) :: (match list_number eid with Some n -> ["listNumber", `Int n] | None -> []) @ fields)
    | _ -> encoded
