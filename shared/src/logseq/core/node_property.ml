module Ds = Datascript
module G = Graph_read

let member name = function `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields) | _ -> `Null
let required name json = match member name json with `String value when value <> "" -> value | _ -> invalid_arg ("Missing " ^ name)

let get db id attr = Option.value ~default:Ds.Nil (G.value db id attr)
let ident db id = match get db id "db/ident" with Ds.Keyword attr -> Some attr | _ -> None
let visible db attr =
  (String.starts_with ~prefix:"user.property/" attr || String.starts_with ~prefix:"logseq.property/" attr)
  && not (List.mem attr ["logseq.property/icon"; "logseq.property/query"; "logseq.property.class/properties"])
  && match Ds.entid db "db/ident" (Ds.Keyword attr) with
     | Some id -> get db id "logseq.property/hide?" <> Ds.Bool true
     | None -> String.starts_with ~prefix:"user.property/" attr

let render db ~owner ~encode_block =
  match Ds.entid db "block/uuid" (Ds.Uuid owner) with
  | None -> Error "Object no longer exists"
  | Some id ->
    let attrs = Hashtbl.create 16 and visited = Hashtbl.create 8 in
    let add attr = if visible db attr then Hashtbl.replace attrs attr () in
    Seq.iter (fun (d : Ds.datom) -> add d.a) (Ds.Db.datoms db Ds.Eavt ~e:id ());
    let rec tag id = if not (Hashtbl.mem visited id) then (
      Hashtbl.add visited id ();
      List.iter (fun property -> Option.iter add (ident db property))
        (G.ref_eids db id "logseq.property.class/properties");
      List.iter tag (G.ref_eids db id "logseq.property.class/extends")) in
    List.iter tag (G.ref_eids db id "block/tags");
    let order attr = match Ds.entid db "db/ident" (Ds.Keyword attr) with
      | Some id -> (match get db id "block/order" with Ds.String order -> order | _ -> ""), attr
      | None -> "", attr in
    let attrs = Hashtbl.fold (fun attr () acc -> attr :: acc) attrs []
      |> List.sort (fun a b -> compare (order a) (order b)) in
    let rename = if Node_title.can_rename_page db id then
      Result_view.property_json ~include_candidates:false db ~owner ~attr:"block/title" ~encode_block
      else `Null in
    let class_ = Node_title.is_class db id in
    let schema_attrs = G.ref_eids db id "logseq.property.class/properties" |> List.filter_map (ident db) in
    let property attr = Result_view.property_json ~include_candidates:false db ~owner ~attr ~encode_block in
    let catalog = Ds.Db.datoms db Ds.Aevt ~a:"db/ident" () |> Seq.filter_map (fun (d : Ds.datom) ->
      match d.v with Ds.Keyword attr when visible db attr && Node_title.is_property db d.e
        && not (List.mem attr (if class_ then schema_attrs else attrs)) ->
        let p = Result_view.property_metadata db attr in
        if member "editable" p = `Bool true then Some p else None
      | _ -> None) |> List.of_seq |> List.sort (fun a b ->
        compare (member "title" a) (member "title" b)) in
    let tag_picker = if not (Node_title.can_edit db id) then `Null else
      let choices = G.tag_pages (fun value -> Ok value) db |> List.map (fun (tag : Cache_model.entity_summary) ->
        `Assoc ["title", `String tag.title; "value", `Null; "match", `List [`String tag.uuid]]) in
      match Result_view.property_json ~include_candidates:false db ~owner ~attr:"block/tags" ~encode_block with
      | `Assoc fields -> `Assoc (["title", `String "Set tags"; "filterValues", `List choices] @
          List.filter (fun (name, _) -> not (List.mem name ["title"; "filterValues"])) fields)
      | _ -> `Null in
    Ok (`Assoc ["ownerUuid", `String owner; "canDelete", `Bool (Node_title.can_delete db id);
      "tagPicker", tag_picker; "canAdd", `Bool (Node_title.can_edit db id); "classSchema", `Bool class_;
      "availableProperties", `List catalog; "schemaProperties", `List (List.map property schema_attrs);
      "rename", rename; "properties", `List (List.map (fun attr ->
        Result_view.property_json db ~owner ~attr ~encode_block) attrs)])

let attach db owner attr =
  let id = match Ds.entid db "block/uuid" (Ds.Uuid owner) with Some id -> id | None -> invalid_arg "Object no longer exists" in
  if not (Node_title.can_edit db id && visible db attr) then invalid_arg "This property is read-only";
  let definition = match Ds.entid db "db/ident" (Ds.Keyword attr) with
    | Some id when Node_title.is_property db id -> id | _ -> invalid_arg "Property no longer exists" in
  let json = Result_view.property_json ~include_candidates:false db ~owner ~attr ~encode_block:(fun _ -> `Null) in
  if member "editable" json <> `Bool true then invalid_arg "This property is read-only";
  let target_attr, value = if Node_title.is_class db id then
      "logseq.property.class/properties", Pending_ops.Ref_ident attr
    else attr, (match List.assoc_opt attr db.Ds.schema with
      | Some schema when schema.Ds.value_type = Some Ds.RefType -> Pending_ops.Ref_ident "logseq.property/empty-placeholder"
      | _ when get db definition "logseq.property/type" = Ds.Keyword "checkbox" -> Pending_ops.Bool_value false
      | _ -> Pending_ops.String_value "") in
  let raw = Result_view.property_json ~include_candidates:false db ~owner ~attr:target_attr ~encode_block:(fun _ -> `Null)
    |> member "raw" in
  let expected = match raw with `Null -> None | value -> Some (Pending_ops.semantic_value_of_json value) in
  let many = match List.assoc_opt target_attr db.Ds.schema with Some schema -> schema.Ds.cardinality = Ds.Many | None -> false in
  let value = match expected with
    | Some value when not (Node_title.is_class db id) -> value
    | Some (Pending_ops.Set_value values) -> Pending_ops.Set_value (List.sort_uniq compare (value :: values))
    | _ -> if many then Pending_ops.Set_value [value] else value in
  Pending_ops.Set_property {uuid = owner; attr = target_attr; expected; value = Some value}

let mutation db ~now ~fresh_uuid input =
  try
    let action = member "action" input in
    if action = `String "remove" || action = `String "removeTag" then (
      let owner = required "blockUuid" input in
      let id = match Ds.entid db "block/uuid" (Ds.Uuid owner) with
        | Some id when Node_title.can_edit db id -> id | _ -> invalid_arg "This object is read-only" in
      let attr, remaining = if action = `String "removeTag" then (
        let tag = required "tagUuid" input in
        let tag_id = match Ds.entid db "block/uuid" (Ds.Uuid tag) with
          | Some id when G.tag_available_for_completion db id -> id | _ -> invalid_arg "This tag cannot be removed" in
        let assigned = G.ref_eids db id "block/tags" in
        if not (List.mem tag_id assigned) then invalid_arg "The tag is no longer assigned";
        "block/tags", Some (List.filter ((<>) tag_id) assigned))
      else (
        let attr = required "attr" input in
        if not (visible db attr) then invalid_arg "This property is read-only";
        if Node_title.is_class db id then (
          let definition = match Ds.entid db "db/ident" (Ds.Keyword attr) with
            | Some id -> id | None -> invalid_arg "Property no longer exists" in
          let assigned = G.ref_eids db id "logseq.property.class/properties" in
          if not (List.mem definition assigned) then invalid_arg "The property is no longer assigned";
          "logseq.property.class/properties", Some (List.filter ((<>) definition) assigned))
        else attr, None) in
      let raw = Result_view.property_json ~include_candidates:false db ~owner ~attr ~encode_block:(fun _ -> `Null) |> member "raw" in
      let expected = if raw = `Null then None else Some (Pending_ops.semantic_value_of_json raw) in
      let value = Option.map (fun ids -> Pending_ops.Set_value (List.map (fun id ->
        match G.uuid_for_eid db id, ident db id with
        | Some uuid, _ -> Pending_ops.Ref_uuid uuid
        | _, Some attr -> Pending_ops.Ref_ident attr
        | _ -> invalid_arg "The value has no stable identity") ids)) remaining in
      Ok (Pending_ops.Set_property {uuid = owner; attr; expected; value}))
    else if action = `String "setCodeLanguage" then (
      let uuid = required "blockUuid" input in
      let id = match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
        | Some id when Node_title.can_edit db id && G.display_type_for_eid db id = Some "code" -> id
        | _ -> invalid_arg "Choose an editable code block" in
      let language = match member "value" input with `String language -> String.trim language
        | _ -> invalid_arg "Choose a code language" in
      if String.length language > 80 || String.exists (fun c -> Char.code c < 32) language then
        invalid_arg "Invalid code language";
      let expected = match G.value db id "logseq.property.code/lang" with
        | Some (Ds.String value) -> Some (Pending_ops.String_value value) | _ -> None in
      Ok (Pending_ops.Set_property {uuid; attr = "logseq.property.code/lang"; expected;
        value = if language = "" then None else Some (Pending_ops.String_value language)}))
    else if action = `String "addTags" || action = `String "setTags" then (
      let owner = required "blockUuid" input in
      let owner_id = match Ds.entid db "block/uuid" (Ds.Uuid owner) with Some id -> id | None -> invalid_arg "Object no longer exists" in
      if not (Node_title.can_edit db owner_id) then invalid_arg "This object is read-only";
      let values name = match member name input with `Null -> [] | `List values -> List.map (function
        | `String value -> value | _ -> invalid_arg "Choose a tag") values | _ -> invalid_arg "Choose a tag" in
      let selected_uuids = List.sort_uniq String.compare (values "selectedValues") in
      let assigned = G.ref_eids db owner_id "block/tags" in
      let selected = List.map (fun uuid ->
        if not (G.node_is_tag db uuid) then invalid_arg "The tag no longer exists";
        Pending_ops.Add_tag {uuid = owner; tag_uuid = uuid}) selected_uuids in
      let created = List.concat_map (fun title ->
        let title = Dev_query.Unicode.trim title in
        if title = "" || String.contains title '#' || String.contains title '/' || String.starts_with ~prefix:"[[" title
        then invalid_arg "Enter a valid tag name";
        let existing = Ds.Db.datoms db Ds.Avet ~a:"block/title" ~v:(Ds.String title) () |> Seq.find_map (fun (d : Ds.datom) ->
          if G.entity_is_instance_of db d.e "logseq.class/Tag" then G.uuid_for_eid db d.e else None) in
        match existing with
        | Some uuid -> [Pending_ops.Add_tag {uuid = owner; tag_uuid = uuid}]
        | None -> let uuid = fresh_uuid () in
          [Pending_ops.Create_tag {uuid; title; created_at = now}; Pending_ops.Add_tag {uuid = owner; tag_uuid = uuid}])
        (List.sort_uniq String.compare (values "newValues")) in
      let replace = if action <> `String "setTags" then [] else
        let retained = List.filter (fun tag ->
          not (G.tag_available_for_completion db tag) || G.page_is_hidden db tag ||
          Option.fold ~none:false ~some:(fun uuid -> List.mem uuid selected_uuids) (G.uuid_for_eid db tag)) assigned in
        let current = Result_view.property_json ~include_candidates:false db ~owner ~attr:"block/tags"
          ~encode_block:(fun _ -> `Null) |> member "raw" in
        let expected = match member "expected" input with `Null -> current | raw -> raw in
        [Pending_ops.Set_property {uuid = owner; attr = "block/tags";
          expected = (if expected = `Null then None else Some (Pending_ops.semantic_value_of_json expected));
          value = Some (Pending_ops.Set_value (List.map (fun tag ->
            Pending_ops.Ref_uuid (Option.get (G.uuid_for_eid db tag))) retained))}] in
      if replace = [] && selected = [] && created = [] then invalid_arg "Choose at least one tag";
      Ok (Pending_ops.Atomic (replace @ selected @ created)))
    else     if action = `String "add" then
      Ok (attach db (required "blockUuid" input) (required "attr" input))
    else if action = `String "create" then (
      let owner = required "blockUuid" input in
      let title = String.trim (required "title" input) in
      let existing = Ds.Db.datoms db Ds.Avet ~a:"block/title" ~v:(Ds.String title) () |> Seq.find_map (fun (d : Ds.datom) ->
        if Node_title.is_property db d.e then ident db d.e else None) in
      match existing with Some attr -> Ok (attach db owner attr)
      | None ->
        let pages = Ds.Db.datoms db Ds.Avet ~a:"block/name" ~v:(Ds.String (Node_title.name title)) ()
          |> Seq.filter_map (fun (d : Ds.datom) ->
            if Node_title.is_page db d.e && not (Node_title.is_property db d.e || Node_title.is_class db d.e)
            then Some d.e else None) |> List.of_seq in
        let uuid, title = match pages with
          | [] -> fresh_uuid (), title
          | [id] ->
            if G.ref_eids db id "block/parent" <> [] then invalid_arg "Namespaced pages cannot become properties";
            (match G.uuid_for_eid db id with Some uuid -> uuid | None -> invalid_arg "Page has no UUID"),
            (match get db id "block/title" with Ds.String title -> title | _ -> title)
          | _ -> invalid_arg "Multiple pages share this name. Choose a unique property name" in
        let create = Pending_ops.Create_property {uuid; title; created_at = now} in
        let projected = match Pending_projection.compile db create with
          | Ok tx -> Ds.db_with tx db | Error message -> invalid_arg message in
        Ok (Pending_ops.Atomic [create; attach projected owner ("user.property/property-" ^ uuid)]))
    else
    let attr = match input with `Assoc fields -> (match List.assoc_opt "attr" fields with Some (`String attr) -> attr | _ -> "") | _ -> "" in
    let rename = attr = "block/title" && (match input with
      | `Assoc fields -> (match List.assoc_opt "blockUuid" fields with Some (`String uuid) ->
        Option.fold ~none:false ~some:(Node_title.can_rename_page db) (Ds.entid db "block/uuid" (Ds.Uuid uuid)) | _ -> false)
      | _ -> false) in
    if not (rename || visible db attr) then invalid_arg "This property is read-only";
    Ok (Result_view.edit_property ~text_value:true ~allow_builtin:true db ~now ~fresh_uuid input)
  with Invalid_argument message -> Error message
