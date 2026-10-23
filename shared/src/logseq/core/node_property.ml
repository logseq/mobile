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
    let tag_picker = if not (Node_title.can_edit db id) then `Null else
      let assigned = Hashtbl.create 8 in
      List.iter (fun id -> Option.iter (fun uuid -> Hashtbl.replace assigned uuid ()) (G.uuid_for_eid db id))
        (G.ref_eids db id "block/tags");
      let choices = G.tag_pages (fun value -> Ok value) db |> List.filter_map (fun (tag : Cache_model.entity_summary) ->
        if Hashtbl.mem assigned tag.uuid then None else Some (`Assoc ["title", `String tag.title;
          "value", `Null; "match", `List [`String tag.uuid]])) in
      match Result_view.property_json ~include_candidates:false db ~owner ~attr:"block/tags" ~encode_block with
      | `Assoc fields -> `Assoc (["title", `String "Add tags"; "raw", `Null; "text", `String ""; "filterValues", `List choices] @
          List.filter (fun (name, _) -> not (List.mem name ["title"; "raw"; "text"; "filterValues"])) fields)
      | _ -> `Null in
    Ok (`Assoc ["ownerUuid", `String owner; "canDelete", `Bool (Node_title.can_delete db id); "tagPicker", tag_picker; "rename", rename; "properties", `List (List.map (fun attr ->
      Result_view.property_json db ~owner ~attr ~encode_block) attrs)])

let mutation db ~now ~fresh_uuid input =
  try
    let action = member "action" input in
    if action = `String "addTags" then (
      let owner = required "blockUuid" input in
      let owner_id = match Ds.entid db "block/uuid" (Ds.Uuid owner) with Some id -> id | None -> invalid_arg "Object no longer exists" in
      if not (Node_title.can_edit db owner_id) then invalid_arg "This object is read-only";
      let values name = match member name input with `Null -> [] | `List values -> List.map (function
        | `String value -> value | _ -> invalid_arg "Choose a tag") values | _ -> invalid_arg "Choose a tag" in
      let selected = List.map (fun uuid ->
        if not (G.node_is_tag db uuid) then invalid_arg "The tag no longer exists";
        Pending_ops.Add_tag {uuid = owner; tag_uuid = uuid}) (List.sort_uniq String.compare (values "selectedValues")) in
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
      if selected = [] && created = [] then invalid_arg "Choose at least one tag";
      Ok (Pending_ops.Atomic (selected @ created)))
    else
    let attr = match input with `Assoc fields -> (match List.assoc_opt "attr" fields with Some (`String attr) -> attr | _ -> "") | _ -> "" in
    let rename = attr = "block/title" && (match input with
      | `Assoc fields -> (match List.assoc_opt "blockUuid" fields with Some (`String uuid) ->
        Option.fold ~none:false ~some:(Node_title.can_rename_page db) (Ds.entid db "block/uuid" (Ds.Uuid uuid)) | _ -> false)
      | _ -> false) in
    if not (rename || visible db attr) then invalid_arg "This property is read-only";
    Ok (Result_view.edit_property ~text_value:true ~allow_builtin:true db ~now ~fresh_uuid input)
  with Invalid_argument message -> Error message
