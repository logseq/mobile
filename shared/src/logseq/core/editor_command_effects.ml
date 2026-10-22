open Editor_command
module Ds = Datascript
module Ops = Pending_ops
module Read = Graph_read
module Entity = Ds.Entity
let eid db uuid = match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> eid | None -> invalid_arg "The node no longer exists"
let semantic db attr = function
  | Ds.Ref eid -> (match Read.uuid_for_eid db eid with Some uuid -> Ops.Ref_uuid uuid | None -> invalid_arg "Missing reference")
  | Ds.Int64 n when Datascript_value.is_ref_attr db attr -> (match Read.uuid_for_eid db (Int64.to_int n) with Some uuid -> Ops.Ref_uuid uuid | None -> invalid_arg "Missing reference")
  | v -> (match Ops.semantic_value_from_datascript v with Ok v -> v | Error msg -> invalid_arg msg)
let set db uuid attr value =
  let expected = Option.map (semantic db attr) (Read.value db (eid db uuid) attr) in
  Ops.Set_property {uuid; attr; expected; value}
let edit db ~now ~fresh_uuid uuid attr text =
  let p = Result_view.property_json db ~owner:uuid ~attr ~encode_block:(fun _ -> `Null) in
  let raw = match p with `Assoc fields -> Option.value ~default:`Null (List.assoc_opt "raw" fields) | _ -> `Null in
  Result_view.edit_property ~allow_builtin:true db ~now ~fresh_uuid (`Assoc ["blockUuid", `String uuid;
    "attr", `String attr; "expected", raw; "value", `String text])

let children db parent =
  Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" parent |> List.of_seq
  |> List.map (fun (d : Ds.datom) -> d.e)
  |> List.sort (fun a b -> compare (Read.string_value (Read.value db a "block/order"), a)
      (Read.string_value (Read.value db b "block/order"), b))

let next_order db target =
  let order = Read.string_value (Read.value db target "block/order") in
  match Read.ref_eids db target "block/parent" with
  | parent :: _ -> children db parent |> List.find_map (fun eid ->
      let next = Read.string_value (Read.value db eid "block/order") in
      if compare next order > 0 then next else None)
  | _ -> None

let position lower upper = match Fractional_order.between lower upper with
  | Ok order -> order | Error message -> invalid_arg message

let clone_template db ~now ~fresh_uuid target source draft =
  let target_eid = eid db target and source_eid = eid db source in
  if not (Read.entity_is_instance_of db source_eid "logseq.class/Template") then invalid_arg "Choose a template";
  let roots = children db source_eid in
  if roots = [] then invalid_arg "This template has no blocks";
  let page_eid = match Read.ref_eids db target_eid "block/page" with p :: _ -> p | _ -> invalid_arg "Missing target page" in
  let page = Option.get (Read.uuid_for_eid db page_eid) in
  let page_title = Option.value ~default:"" (Read.string_value (Read.value db page_eid "block/title")) in
  let title eid = Option.value ~default:"" (Read.string_value (Read.value db eid "block/title")) in
  let expand value =
    Str.global_substitute (Str.regexp "<%\\([^%]*\\)%>") (fun matched ->
      let variable = String.trim (Str.matched_group 1 matched) in
      match String.lowercase_ascii variable with
      | "current page" -> "[[" ^ page_title ^ "]]"
      | "time" -> let t = Unix.localtime (float_of_int now /. 1000.) in Printf.sprintf "%02d:%02d" t.tm_hour t.tm_min
      | "today" | "tomorrow" | "yesterday" as name ->
        let t = Unix.localtime (float_of_int now /. 1000.) in
        let seconds, _ = Unix.mktime {t with tm_mday = t.tm_mday + (if name = "tomorrow" then 1 else if name = "yesterday" then -1 else 0)} in
        Editor_command.journal_reference (Some db) (int_of_float (seconds *. 1000.))
      | _ -> variable) value in
  let target_children = children db target_eid in
  let replace = String.trim draft = "" && target_children = [] in
  let mappings = Hashtbl.create 32 in
  let rec allocate seen eid =
    if List.mem eid seen then invalid_arg "The template contains a cycle";
    if Hashtbl.length mappings >= 10000 then invalid_arg "The template is too large";
    Hashtbl.add mappings eid (if replace && eid = List.hd roots then target else fresh_uuid ());
    List.iter (allocate (eid :: seen)) (children db eid) in
  List.iter (allocate [source_eid]) roots;
  let rec convert attr = function
    | Ds.Ref eid -> Ops.Ref_uuid (Option.value ~default:(Option.get (Read.uuid_for_eid db eid)) (Hashtbl.find_opt mappings eid))
    | Ds.Int64 eid when Datascript_value.is_ref_attr db attr -> convert attr (Ds.Ref (Int64.to_int eid))
    | Ds.Set values -> Ops.Set_value (List.map (convert attr) values)
    | Ds.Vector values -> Ops.Vector_value (List.map (convert attr) values)
    | Ds.String text -> Ops.String_value (expand text)
    | value -> semantic db attr value in
  let properties destination source =
    let attrs = Hashtbl.create 16 in
    Seq.iter (fun (d : Ds.datom) -> if d.a = "block/tags" || d.a = "block/link"
      || String.starts_with ~prefix:"user.property/" d.a
      || String.starts_with ~prefix:"logseq.property/" d.a
      || String.starts_with ~prefix:"logseq.property." d.a then Hashtbl.replace attrs d.a ())
      (Ds.Db.datoms db Ds.Eavt ~e:source ());
    Hashtbl.fold (fun attr () ops ->
      let entity = Option.get (Ds.entity db (Ds.Entity_id source)) in
      let value = match Entity.entity_attr_raw entity attr with
        | Some (Ds.One_value value) -> Some (convert attr value)
        | Some (Ds.Many_values values) -> Some (Ops.Set_value (List.map (convert attr) values))
        | _ -> None in
      let expected = if destination = target then
        let entity = Option.get (Ds.entity db (Ds.Entity_id target_eid)) in
        (match Entity.entity_attr_raw entity attr with
         | Some (Ds.One_value value) -> Some (semantic db attr value)
         | Some (Ds.Many_values values) -> Some (Ops.Set_value (List.map (semantic db attr) values))
         | _ -> None) else None in
      Ops.Set_property {uuid = destination; attr; expected; value} :: ops) attrs [] in
  let rec copy parent order source =
    let uuid = Hashtbl.find mappings source in
    let own = if uuid = target then [Ops.Save_title {uuid; expected_title = title target_eid; title = expand (title source)}]
      else [Ops.Insert_block {uuid; title = expand (title source); parent_uuid = parent;
        page_uuid = page; order; created_at = now}] in
    own @ properties uuid source @ List.concat_map (fun child -> copy uuid
      (Option.value ~default:"a0" (Read.string_value (Read.value db child "block/order"))) child) (children db source) in
  let inside = target_children <> [] in
  let parent = if inside then target else match Read.ref_eids db target_eid "block/parent" with
    | p :: _ -> Option.get (Read.uuid_for_eid db p) | _ -> page in
  let lower = if inside then match List.rev target_children with
    | last :: _ -> Read.string_value (Read.value db last "block/order") | _ -> None
    else Read.string_value (Read.value db target_eid "block/order") in
  let upper = if inside then None else next_order db target_eid in
  let _, ops = List.fold_left (fun (lower, ops) source ->
    let reuse = Hashtbl.find mappings source = target in
    let order = if reuse then Option.value ~default:"a0" lower else position lower upper in
    Some order, List.rev_append (copy parent order source) ops) (lower, []) roots in
  let ops = List.rev ops in
  let ops = if replace then ops else Ops.Save_title {uuid = target; expected_title = title target_eid; title = draft} :: ops in
  [Ops.Atomic (ops @ [Ops.Set_property {uuid = Hashtbl.find mappings (List.hd roots);
    attr = "logseq.property/used-template"; expected = None; value = Some (Ops.Ref_uuid source)}])]

let plan db ~now ~fresh_uuid operation =
  try Ok (match operation with
    | Ensure_journal ms ->
      let day = Cache_model.journal_day_for_ms ms in
      if Read.journal_page_uuid db day <> None then [] else
      [Ops.Create_journal {page_uuid = Printf.sprintf "00000001-%04d-%04d-0000-000000000000" (day / 10000) (day mod 10000);
        block_uuid = fresh_uuid (); block_title = ""; title = Journal.day_title day; journal_day = day; created_at = now}]
    | Insert_code (uuid, language) ->
      let target = eid db uuid in
      let page = match Read.ref_eids db target "block/page" with p :: _ -> Option.get (Read.uuid_for_eid db p) | _ -> invalid_arg "Missing page" in
      let parent = match Read.ref_eids db target "block/parent" with p :: _ -> Option.get (Read.uuid_for_eid db p) | _ -> page in
      let fresh = fresh_uuid () in
      [Ops.Atomic ([Ops.Insert_block {uuid = fresh; title = ""; page_uuid = page; parent_uuid = parent;
          order = position (Read.string_value (Read.value db target "block/order")) (next_order db target); created_at = now};
        Ops.Set_property {uuid = fresh; attr = "logseq.property.node/display-type"; expected = None; value = Some (Ops.Keyword_value "code")}]
        @ match language with None -> [] | Some language -> [Ops.Set_property {uuid = fresh;
          attr = "logseq.property.code/lang"; expected = None; value = Some (Ops.String_value language)}])]
    | Embed_node (uuid, source, replace) ->
      let source_eid = eid db source in
      if uuid = source then invalid_arg "A node cannot embed itself";
      let rec ancestors seen eid_ =
        if List.mem eid_ seen then false
        else eid_ = source_eid || List.exists (ancestors (eid_ :: seen)) (Read.ref_eids db eid_ "block/parent") in
      if ancestors [] (eid db uuid) then invalid_arg "A node cannot embed an ancestor";
      if replace then [set db uuid "block/link" (Some (Ops.Ref_uuid source))] else
        let target = eid db uuid in
        let page = match Read.ref_eids db target "block/page" with p :: _ -> Option.get (Read.uuid_for_eid db p) | _ -> invalid_arg "Missing page" in
        let parent = match Read.ref_eids db target "block/parent" with p :: _ -> Option.get (Read.uuid_for_eid db p) | _ -> page in
        let fresh = fresh_uuid () in
        [Ops.Atomic [Ops.Insert_block {uuid = fresh; title = ""; page_uuid = page; parent_uuid = parent;
          order = position (Read.string_value (Read.value db target "block/order")) (next_order db target); created_at = now};
          Ops.Set_property {uuid = fresh; attr = "block/link"; expected = None; value = Some (Ops.Ref_uuid source)}]]
    | Apply_template (target, source, draft) -> clone_template db ~now ~fresh_uuid target source draft
    | Apply (uuid, Properties fields) -> List.map (fun (attr, value) -> set db uuid attr value) fields
    | Apply (uuid, Choice (attr, value)) -> [edit db ~now ~fresh_uuid uuid attr (Option.value ~default:"" value)]
    | Apply (uuid, Code lang) -> [set db uuid "logseq.property.node/display-type" (Some (Ops.Keyword_value "code"))]
      @ (match lang with None -> [] | Some lang -> [set db uuid "logseq.property.code/lang" (Some (Ops.String_value lang))])
    | Apply (uuid, Number children) ->
      let targets = if children then Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" (eid db uuid)
        |> List.of_seq |> List.filter_map (fun (d : Ds.datom) -> Read.uuid_for_eid db d.e) else [uuid] in
      let attr = "logseq.property/order-list-type" in
      let on = List.exists (fun uuid -> Read.value db (eid db uuid) attr <> None) targets in
      List.concat_map (fun uuid -> if on then [set db uuid attr None] else
        let value_uuid = fresh_uuid () in
        [Ops.Create_property_value {uuid = value_uuid; owner_uuid = uuid; property_ident = attr;
          content = Ops.String_value "number"; created_at = now};
         set db uuid attr (Some (Ops.Ref_uuid value_uuid))]) targets
    | Apply (_, _) -> [])
  with Invalid_argument message | Failure message -> Error message
