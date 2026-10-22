module Ds = Datascript
module G = Graph_read

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
    Ok (`Assoc ["ownerUuid", `String owner; "rename", rename; "properties", `List (List.map (fun attr ->
      Result_view.property_json db ~owner ~attr ~encode_block) attrs)])

let mutation db ~now ~fresh_uuid input =
  try
    let attr = match input with `Assoc fields -> (match List.assoc_opt "attr" fields with Some (`String attr) -> attr | _ -> "") | _ -> "" in
    let rename = attr = "block/title" && (match input with
      | `Assoc fields -> (match List.assoc_opt "blockUuid" fields with Some (`String uuid) ->
        Option.fold ~none:false ~some:(Node_title.can_rename_page db) (Ds.entid db "block/uuid" (Ds.Uuid uuid)) | _ -> false)
      | _ -> false) in
    if not (rename || visible db attr) then invalid_arg "This property is read-only";
    Ok (Result_view.edit_property ~text_value:true ~allow_builtin:true db ~now ~fresh_uuid input)
  with Invalid_argument message -> Error message
