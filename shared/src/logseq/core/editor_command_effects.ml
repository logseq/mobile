open Editor_command
module Ds = Datascript
module Ops = Pending_ops
module Read = Graph_read
module Entity = Ds.Entity
let eid db uuid = match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> eid | None -> invalid_arg "The node no longer exists"
let reference db eid =
  match Read.uuid_for_eid db eid, Read.value db eid "db/ident" with
  | Some uuid, _ -> Ops.Ref_uuid uuid
  | None, Some (Ds.Keyword ident) -> Ops.Ref_ident ident
  | _ -> invalid_arg "Missing reference"

let rec semantic db attr = function
  | Ds.Ref eid -> reference db eid
  | Ds.Int64 n when Datascript_value.is_ref_attr db attr -> reference db (Int64.to_int n)
  | Ds.Set values -> Ops.Set_value (List.map (semantic db attr) values)
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

let used_template = "logseq.property/used-template"

let copy_template db ~now ~allocate_uuid ~page ~page_title ~parent ~lower ~upper
    ~replacement ~source ~roots =
  let first = List.hd roots in
  let raw_title eid = Option.value ~default:"" (Read.string_value (Read.value db eid "block/title")) in
  let expand value =
    Str.global_substitute (Str.regexp "<%\\([^%]*\\)%>") (fun matched ->
      let variable = String.trim (Str.matched_group 1 matched) in
      match String.lowercase_ascii variable with
      | "current page" ->
        "[[" ^ (if Ref_text.is_uuid page then page else page_title) ^ "]]"
      | "time" -> let t = Unix.localtime (float_of_int now /. 1000.) in Printf.sprintf "%02d:%02d" t.tm_hour t.tm_min
      | "today" | "tomorrow" | "yesterday" as name ->
        let t = Unix.localtime (float_of_int now /. 1000.) in
        let seconds, _ = Unix.mktime {t with tm_mday = t.tm_mday + (if name = "tomorrow" then 1 else if name = "yesterday" then -1 else 0)} in
        let day = Cache_model.journal_day_for_ms (int_of_float (seconds *. 1000.)) in
        (match Read.journal_page_uuid db day with
         | Some uuid -> "[[" ^ uuid ^ "]]"
         | None -> Printf.sprintf "[[%08d]]" day)
      | _ -> variable) value in
  let mappings = Hashtbl.create 32 in
  let rec allocate seen eid =
    if List.mem eid seen then invalid_arg "The template contains a cycle";
    if Hashtbl.length mappings >= 10000 then invalid_arg "The template is too large";
    let uuid = match replacement with
      | Some (_, uuid) when eid = first -> uuid
      | _ -> allocate_uuid eid in
    let children = children db eid in
    Hashtbl.add mappings eid (uuid, children);
    List.iter (allocate (eid :: seen)) children in
  List.iter (allocate [source]) roots;
  let remap uuid =
    Option.bind (Ds.entid db "block/uuid" (Ds.Uuid uuid)) (fun eid ->
      Option.map fst (Hashtbl.find_opt mappings eid)) in
  let rec convert attr = function
    | Ds.Ref eid ->
      (match Hashtbl.find_opt mappings eid with
       | Some (uuid, _) -> Ops.Ref_uuid uuid
       | None -> reference db eid)
    | Ds.Int64 eid when Datascript_value.is_ref_attr db attr -> convert attr (Ds.Ref (Int64.to_int eid))
    | Ds.Set values -> Ops.Set_value (List.map (convert attr) values)
    | Ds.Vector values -> Ops.Vector_value (List.map (convert attr) values)
    | Ds.String text -> Ops.String_value (expand text)
    | value -> semantic db attr value in
  let properties source_node =
    let attrs = Ds.Db.datoms db Ds.Eavt ~e:source_node ()
      |> Seq.filter_map (fun (d : Ds.datom) ->
        if d.a = "block/link" || d.a = "block/tags"
          || ((d.a <> used_template || source_node <> first)
              && (String.starts_with ~prefix:"user.property/" d.a
                  || String.starts_with ~prefix:"logseq.property/" d.a
                  || String.starts_with ~prefix:"logseq.property." d.a))
        then Some d.a else None)
      |> List.of_seq |> List.sort_uniq String.compare in
    let entity = Option.get (Ds.entity db (Ds.Entity_id source_node)) in
    let props = List.filter_map (fun attr ->
      let value = match Entity.entity_attr_raw entity attr with
        | Some (Ds.One_value value) -> Some (convert attr value)
        | Some (Ds.Many_values values) -> Some (Ops.Set_value (List.map (convert attr) values))
        | _ -> None in
      Option.map (fun value -> attr, value) value) attrs in
    let used = if source_node = first then
        [used_template, reference db source]
      else [] in
    props @ used in
  let count = Hashtbl.length mappings in
  let new_count = if replacement = None then count else count - 1 in
  let new_orders = match Fractional_order.n_between lower upper new_count with
    | Ok orders -> orders | Error message -> invalid_arg message in
  let orders = if replacement = None then new_orders else Option.value ~default:"a0" lower :: new_orders in
  let rec copy parent (orders, writes, props) source_node =
    let uuid, descendants = Hashtbl.find mappings source_node in
    let order, orders = match orders with first :: rest -> first, rest | [] -> assert false in
    let title = expand (Ref_text.remap_page_ids remap (raw_title source_node)) in
    let destination = if source_node = first then Option.map fst replacement else None in
    let write = match destination with
      | Some eid -> Ops.Save_title {uuid; expected_title = raw_title eid; title}
      | None -> Ops.Insert_block {uuid; title; parent_uuid = parent;
          page_uuid = page; order; created_at = now} in
    List.fold_left (copy uuid)
      (orders, write :: writes, (uuid, properties source_node) :: props) descendants in
  let _, writes, props = List.fold_left (copy parent) (orders, [], []) roots in
  let last_order = List.nth_opt (List.rev orders) 0 in
  last_order, (List.rev writes, List.rev props)

let template_intent db writes properties =
  (* Preview the inserted titles, including any tags and defaults they
     generate, before applying properties and references to the copies. *)
  let inserted = match Pending_projection.compile db (Ops.Atomic writes) with
    | Ok tx -> Ds.db_with tx db
    | Error message -> invalid_arg message in
  let properties = List.filter_map (fun (uuid, properties) ->
    let entity = Option.get (Ds.entity inserted (Pending_projection.lookup uuid)) in
    let refs = Pending_projection.one_value inserted (Pending_projection.lookup uuid) "block/title"
      |> Pending_projection.string_value
      |> Option.fold ~none:[] ~some:(Pending_projection.refs_for_title inserted)
      |> List.map (reference inserted) in
    let properties = if refs = [] then properties else ("block/refs", Ops.Set_value refs) :: properties in
    let changes = List.filter_map (fun (attr, value) ->
      let raw = match Entity.entity_attr_raw entity attr with
        | Some (Ds.One_value value) -> Some value
        | Some (Ds.Many_values (_ :: _ as values)) -> Some (Ds.Set values)
        | _ -> None in
      if Pending_projection.semantic_value_equal inserted raw (Some value) then None
      else Some {Ops.attr; expected = Option.map (semantic inserted attr) raw; value = Some value})
      properties in
    if changes = [] then None else Some (Ops.Set_properties {uuid; changes})) properties in
  Ops.Atomic (writes @ properties)

let plain_placeholder db node =
  Option.fold ~none:false ~some:(fun title -> String.trim title = "")
    (Read.string_value (Read.value db node "block/title"))
  && Seq.is_empty (Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" node)
  && Seq.for_all (fun (d : Ds.datom) ->
    List.mem d.a ["block/title"; "block/uuid"; "block/parent"; "block/page"; "block/order";
      "block/created-at"; "block/updated-at"; "block/tx-id";
      Created_by.property; "logseq.property/updated-by-ref"])
    (Ds.Db.datoms db Ds.Eavt ~e:node ())

let clone_template db ~now ~fresh_uuid target source draft =
  let target_eid = eid db target and source_eid = eid db source in
  if not (Read.entity_is_instance_of db source_eid "logseq.class/Template") then invalid_arg "Choose a template";
  let roots = children db source_eid in
  if roots = [] then invalid_arg "This template has no blocks";
  let page_eid = match Read.ref_eids db target_eid "block/page" with p :: _ -> p | _ -> invalid_arg "Missing target page" in
  let page = Option.get (Read.uuid_for_eid db page_eid) in
  let page_title = Option.value ~default:"" (Read.string_value (Read.value db page_eid "block/title")) in
  let target_children = children db target_eid in
  let replace = String.trim draft = "" && plain_placeholder db target_eid
    && not (List.exists (fun (attr, (schema : Ds.schema_attr)) ->
      schema.value_type = Some Ds.RefType
      && not (Seq.is_empty (Datascript_value.datoms_by_ref db Ds.Aevt attr target_eid))) db.Ds.schema) in
  let inside = target_children <> [] in
  let parent = if inside then target else match Read.ref_eids db target_eid "block/parent" with
    | p :: _ -> Option.get (Read.uuid_for_eid db p) | _ -> page in
  let lower, upper = match target_children with
    | first :: _ -> None, Read.string_value (Read.value db first "block/order")
    | [] -> Read.string_value (Read.value db target_eid "block/order"), next_order db target_eid in
  let replacement = if replace then Some (target_eid, target) else None in
  let _, (writes, properties) = copy_template db ~now ~allocate_uuid:(fun _ -> fresh_uuid ()) ~page
    ~page_title ~parent ~lower ~upper ~replacement ~source:source_eid ~roots in
  let writes = if replace then writes else
    let expected_title = Option.value ~default:"" (Read.string_value (Read.value db target_eid "block/title")) in
    if expected_title = draft then writes else Ops.Save_title {uuid = target; expected_title; title = draft} :: writes in
  [template_intent db writes properties]

let templates_for_tags db tags =
  let seen = Hashtbl.create 8 in
  let rec templates tag =
    if Hashtbl.mem seen tag then [] else begin
      Hashtbl.add seen tag ();
      let direct = Datascript_value.datoms_by_ref db Ds.Aevt "logseq.property/template-applied-to" tag
        |> Seq.map (fun (d : Ds.datom) -> d.e) |> List.of_seq in
      direct @ List.concat_map templates (Read.ref_eids db tag "logseq.property.class/extends")
    end in
  List.concat_map templates tags |> List.sort_uniq Int.compare
  |> List.filter_map (fun source ->
    match Read.uuid_for_eid db source, children db source with
    | Some _, (_ :: _ as roots) when not (Read.recycled db source) -> Some (source, roots)
    | _ -> None)
  |> List.sort (fun (a, _) (b, _) ->
    compare (Read.value db a "block/created-at", Read.uuid_for_eid db a)
      (Read.value db b "block/created-at", Read.uuid_for_eid db b))

let tag_template_intent ?(applied = []) (report : Ds.tx_report) ~now ~fresh_uuid =
  let db = report.db_after in
  let targets = Hashtbl.create 8 in
  List.iter (fun (d : Ds.datom) ->
    if d.added && d.a = "block/tags" then
      Option.iter (fun tag ->
        let tags = Option.value ~default:[] (Hashtbl.find_opt targets d.e) in
        if not (List.mem tag tags) && Read.has_ref db d.e d.a tag
           && not (Read.has_ref report.db_before d.e d.a tag) then
          Hashtbl.replace targets d.e (tag :: tags))
        (Datascript_value.ref_eid db d.a d.v)) report.tx_data;
  if Hashtbl.length targets = 0 || Seq.is_empty (Ds.Db.datoms db Ds.Aevt ~a:"logseq.property/template-applied-to" ()) then
    Ok None
  else
    let journal_class = Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Journal") in
    let insert (writes, properties) (target, tags) =
      let templates = templates_for_tags db tags
        |> List.filter (fun (source, _) -> not (List.mem source applied)) in
      match templates, Read.uuid_for_eid db target with
      | [], _ | _, None -> writes, properties
      | templates, Some parent ->
        let journal = Read.value db target "block/journal-day" <> None
          && List.exists (fun tag -> Some tag = journal_class) tags in
        let page_eid = match Read.ref_eids db target "block/page" with
          | page :: _ -> page | [] -> target in
        let page = Option.get (Read.uuid_for_eid db page_eid) in
        let page_title = Option.value ~default:"" (Read.string_value (Read.value db page_eid "block/title")) in
        let allocate_uuid node =
          match Read.uuid_for_eid db node with
          | Some uuid when journal && Ref_text.is_uuid parent && Ref_text.is_uuid uuid ->
            "00000005-" ^ String.sub parent 9 14 ^ String.sub uuid 23 13
          | _ -> fresh_uuid () in
        let children = children db target in
        let children, writes = match children with
          | node :: rest when journal && plain_placeholder db node ->
            (match Read.uuid_for_eid db node with
             | Some uuid when Ds.entid report.db_before "block/uuid" (Ds.Uuid uuid) = None ->
               rest, Ops.Delete_blocks {uuids = [uuid]} :: writes
             | _ -> children, writes)
          | _ -> children, writes in
        let upper = match children with
          | first :: _ -> Read.string_value (Read.value db first "block/order")
          | [] -> None in
        let _, writes, props = List.fold_left (fun (lower, writes, props) (source, roots) ->
          let lower, (new_writes, new_props) = copy_template db ~now ~allocate_uuid ~page
            ~page_title ~parent ~lower ~upper ~replacement:None ~source ~roots in
          lower, List.rev_append new_writes writes, List.rev_append new_props props)
          (None, writes, properties) templates in
        writes, props in
    try
      let writes, properties = Hashtbl.to_seq targets |> List.of_seq |> List.sort compare
        |> List.fold_left insert ([], []) in
      if writes = [] then Ok None
      else Ok (Some (template_intent db (List.rev writes) (List.rev properties)))
    with Invalid_argument message | Failure message -> Error message

let plan db ~now ~fresh_uuid operation =
  try Ok (match operation with
    | Ensure_journal day ->
      if Read.journal_page_uuid db day <> None then [] else
      [Ops.Create_journal {page_uuid = Journal.page_uuid day;
        block_uuid = fresh_uuid (); block_title = ""; title = Journal.title db day; journal_day = day; created_at = now}]
    | Insert_code (uuid, language) ->
      let language = match language with Some _ -> language | None -> Read.latest_code_language db in
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
    | Apply (uuid, Properties fields) ->
      List.map (fun (attr, value) -> set db uuid attr value) fields
      @ (if List.assoc_opt "logseq.property.node/display-type" fields = Some (Some (Ops.Keyword_value "quote")) then
          match Option.bind (Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Quote-block"))
            (fun id -> Read.uuid_for_eid db id) with
          | Some tag_uuid -> [Ops.Add_tag {uuid; tag_uuid}]
          | None -> []
        else [])
    | Apply (uuid, Choice (attr, value)) -> [edit db ~now ~fresh_uuid uuid attr (Option.value ~default:"" value)]
    | Apply (uuid, Code lang) ->
      let lang = match lang with Some _ -> lang | None -> Read.latest_code_language db in
      [set db uuid "logseq.property.node/display-type" (Some (Ops.Keyword_value "code"))]
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
