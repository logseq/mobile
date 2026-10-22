module D = Datascript
module G = Graph_read
module O = Pending_ops
module S = String_kit

type content = {target_uuid : string; before_title : string; selection_start : int;
  selection_length : int; plain_text : string; blocks_edn : string}
type insertion = {intent : O.pending_intent; focus : string option; title : string; caret : int}
type node = {uuid : string; parent : string option; attrs : (string * D.value) list}
let field attr node = Option.value ~default:D.Nil (List.assoc_opt attr node.attrs)
let string = function D.String s | D.Uuid s -> s | _ -> ""
let eid db uuid = match D.entid db "block/uuid" (D.Uuid uuid) with
  | Some id -> id | None -> invalid_arg "Clipboard target no longer exists"
let get db id attr = Option.value ~default:D.Nil (G.value db id attr)
let lookup uuid = D.Vector [D.Keyword "block/uuid"; D.Uuid uuid]
let lookup_uuid = function
  | D.Vector [D.Keyword "block/uuid"; D.Uuid uuid]
  | D.Vector [D.Keyword "block/uuid"; D.String uuid] -> Some uuid
  | _ -> None
let parent_uuid db id = Option.bind (Datascript_value.optional_ref_eid db "block/parent" (G.value db id "block/parent"))
  (G.uuid_for_eid db)
let many db attr = Option.fold ~none:false ~some:(fun (spec : D.schema_attr) -> spec.cardinality = D.Many)
  (List.assoc_opt attr db.D.schema)
let rec canonical db = function
  | D.Ref id -> (match G.uuid_for_eid db id with Some uuid -> lookup uuid
      | None -> (match get db id "db/ident" with D.Keyword name -> D.Vector [D.Keyword "db/ident"; D.Keyword name]
        | _ -> invalid_arg "Clipboard contains an unresolved reference"))
  | D.Set xs -> D.Set (List.map (canonical db) xs)
  | D.Vector xs -> D.Vector (List.map (canonical db) xs)
  | D.Map fields -> D.Map (List.map (fun (k, v) -> k, canonical db v) fields)
  | v -> v
let attrs db id =
  let values = Hashtbl.create 16 in
  D.Db.datoms db D.Eavt ~e:id () |> Seq.iter (fun (d : D.datom) ->
    if not (String.starts_with ~prefix:"block.temp/" d.a) then
      Hashtbl.replace values d.a (canonical db d.v :: Option.value ~default:[] (Hashtbl.find_opt values d.a)));
  Hashtbl.fold (fun attr values acc ->
    (attr, if many db attr then D.Set (List.rev values) else List.hd values) :: acc) values []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
let children db id = Pending_projection.children db id |> List.sort (fun a b ->
  compare (get db a "block/order", a) (get db b "block/order", b))
let protect f = try Ok (f ()) with Invalid_argument message | Failure message -> Error message

let copy db ~graph selected = protect (fun () ->
  let selected_ids = Hashtbl.create (List.length selected) in
  List.iter (fun uuid -> Hashtbl.replace selected_ids (eid db uuid) ()) selected;
  let has_selected_ancestor id =
    let seen = Hashtbl.create 8 in
    let rec walk id =
      match Datascript_value.optional_ref_eid db "block/parent" (G.value db id "block/parent") with
      | None -> false
      | Some parent when Hashtbl.mem seen parent -> invalid_arg "Clipboard source contains a parent cycle"
      | Some parent -> Hashtbl.replace seen parent ();
        Hashtbl.mem selected_ids parent || walk parent
    in walk id in
  let roots = List.filter_map (fun uuid -> let id = eid db uuid in if has_selected_ancestor id then None else Some id) selected in
  let seen = Hashtbl.create 32 and reversed = ref [] and markdown = Buffer.create 256 in
  let rec visit depth id =
    if not (Hashtbl.mem seen id) then begin
      Hashtbl.add seen id ();
      let values = attrs db id in
      reversed := D.Map ((D.Keyword "db/id", D.Int64 (Int64.of_int id)) ::
        List.map (fun (attr, v) -> D.Keyword attr, v) values) :: !reversed;
      let raw_title = string (get db id "block/title") in
      let label uuid = Option.bind (D.entid db "block/uuid" (D.Uuid uuid)) (fun id ->
        match get db id "block/title" with D.String title -> Some (G.display_title (fun s -> Ok s) db title) | _ -> None) in
      let display = Ref_text.to_text label label raw_title in
      let lines = String.split_on_char '\n' display in
      List.iteri (fun i line ->
        Buffer.add_string markdown (String.make depth '\t');
        Buffer.add_string markdown (if i = 0 then "- " else "  ");
        Buffer.add_string markdown line; Buffer.add_char markdown '\n') lines;
      List.iter (visit (depth + 1)) (children db id)
    end in
  List.iter (visit 0) roots;
  if !reversed = [] then invalid_arg "Select blocks before copying";
  let rich = Dev_query.Edn_util.pr_str (D.Map [D.Keyword "graph", D.String graph;
    D.Keyword "op", D.Keyword "copy"; D.Keyword "blocks", D.Vector (List.rev !reversed)]) in
  Yojson.Basic.to_string (`Assoc ["plainText", `String (Buffer.contents markdown); "blocksEDN", `String rich]))

let decode ~graph source =
  let map_field attr fields = Option.value ~default:D.Nil (List.assoc_opt (D.Keyword attr) fields) in
  match (try Some (Dev_query.Edn_util.read_string source) with _ -> None) with
  | Some (D.Map fields) when map_field "graph" fields = D.String graph ->
    (match map_field "blocks" fields with
     | D.Vector blocks | D.List blocks when blocks <> [] ->
       let parsed = List.map (function
         | D.Map fields ->
           let uuid = string (map_field "block/uuid" fields) in
           if not (Ref_text.is_uuid uuid) then invalid_arg "Clipboard block UUID is invalid";
           let attrs = List.filter_map (function D.Keyword attr, value -> Some (attr, value) | _ -> None) fields in
           {uuid; parent = lookup_uuid (map_field "block/parent" fields); attrs}
         | _ -> invalid_arg "Clipboard block is invalid") blocks in
       Some parsed
     | _ -> None)
  | _ -> None

let normalize_lines source = Str.global_replace (Str.regexp_string "\r\n") "\n" source
let markdown_pattern = Str.regexp "^[ \t]*\\([-+*] +\\|#+ +\\|```\\|\\$\\$[ \t]*$\\)"
let has_markdown source = List.exists (fun line -> Str.string_match markdown_pattern line 0) (String.split_on_char '\n' source)
let add_attr attr value attrs = (attr, value) :: List.remove_assoc attr attrs

(* mldoc identifies fenced code/math before outline prefixes are examined, so
   a dash, heading or blank line inside a literal block never becomes a node. *)
let parse_text ~fresh_uuid source =
  let source = normalize_lines source in
  let config = {Ref_text.config with Mldoc.Conf.parse_outline_only = false} in
  let literals = Hashtbl.create 8 in
  List.iter (fun (block, (pos : Mldoc.Pos.pos_meta)) -> match block with
    | Mldoc.Type.Src code -> Hashtbl.replace literals pos.start_pos
        (pos.end_pos, String.concat "" code.lines, ["logseq.property.node/display-type", D.Keyword "code"]
          @ (match code.language with None -> [] | Some language -> ["logseq.property.code/lang", D.String language]))
    | Mldoc.Type.Displayed_Math body -> Hashtbl.replace literals pos.start_pos
        (pos.end_pos, body, ["logseq.property.node/display-type", D.Keyword "math"])
    | _ -> ()) (Mldoc.Parser.parse config source);
  let lines = String.split_on_char '\n' source |> Array.of_list in
  let starts = Array.make (Array.length lines) 0 in
  for i = 1 to Array.length lines - 1 do starts.(i) <- starts.(i - 1) + String.length lines.(i - 1) + 1 done;
  let nodes = ref [] and stack = ref [] and current = ref None and blank = ref false in
  let new_node indent title extra =
    let rec ancestors = function (level, _) :: rest when level >= indent -> ancestors rest | rest -> rest in
    stack := ancestors !stack;
    let uuid = fresh_uuid () in
    let parent = Option.map snd (List.nth_opt !stack 0) in
    let buffer = Buffer.create (String.length title + 32) in Buffer.add_string buffer title;
    nodes := (uuid, parent, buffer, extra) :: !nodes;
    stack := (indent, uuid) :: !stack; current := Some (indent, buffer);
    blank := false in
  let indent line =
    let rec count index width = if index >= String.length line then index, width else
      match line.[index] with ' ' -> count (index + 1) (width + 1) | '\t' -> count (index + 1) (width + 2) | _ -> index, width in
    count 0 0 in
  let heading = Str.regexp "^\\([-+*] +\\|\\(#+\\) +\\)\\(.*\\)$" in
  let i = ref 0 in
  while !i < Array.length lines do
    let line = lines.(!i) in
    match Hashtbl.find_opt literals starts.(!i) with
    | Some (finish, body, extra) ->
      let _, level = indent line in new_node level (String.trim body) extra;
      incr i; while !i < Array.length lines && starts.(!i) < finish do incr i done
    | None ->
      let spaces, level = indent line in
      let trimmed = String.trim line in
      if trimmed = "" then blank := true
      else if Str.string_match heading (String.sub line spaces (String.length line - spaces)) 0 then begin
        let body = Str.matched_group 3 (String.sub line spaces (String.length line - spaces)) in
        let size = try Some (String.length (Str.matched_group 2 (String.sub line spaces (String.length line - spaces)))) with Not_found -> None in
        let extra = Option.fold ~none:[] ~some:(fun size -> ["logseq.property/heading", D.Int64 (Int64.of_int size)]) size in
        new_node (Option.fold ~none:level ~some:(fun size -> size - 1) size) body extra
      end else (match !current with
        | None -> new_node level trimmed []
        | Some (_, buffer) ->
          Buffer.add_string buffer (if !blank then "\n\n" else "\n");
          Buffer.add_string buffer trimmed; blank := false);
      incr i
  done;
  List.rev_map (fun (uuid, parent, buffer, extra) -> {uuid; parent;
    attrs = ("block/title", D.String (Buffer.contents buffer)) :: extra}) !nodes

let paragraphs ~fresh_uuid source = Str.split (Str.regexp "\n\n+") source
  |> List.map (fun title -> {uuid = fresh_uuid (); parent = None; attrs = ["block/title", D.String (String.trim title)]})

let inline content =
  let source = content.before_title in
  let first = S.byte_index_of_utf16 source content.selection_start in
  let last = S.byte_index_of_utf16 source (content.selection_start + content.selection_length) in
  let before = String.sub source 0 first and after = String.sub source last (String.length source - last) in
  let selected = String.sub source first (last - first) in
  let plain = normalize_lines content.plain_text in
  let url value = Str.string_match (Str.regexp "^\\(https?\\|file\\|ftp\\)://[^ \t\r\n]+$") value 0 in
  let within_link = String.ends_with ~suffix:"](" before && String.starts_with ~prefix:")" after in
  let inserted =
    if before <> "" && after <> "" && String.ends_with ~suffix:"((" before && String.starts_with ~prefix:"))" after
       && String.starts_with ~prefix:"((" plain && String.ends_with ~suffix:"))" plain
    then String.sub plain 2 (String.length plain - 4)
    else if selected <> "" && (url plain || url selected) && not (url plain && url selected) && not within_link then
      if url selected then "[" ^ plain ^ "](" ^ selected ^ ")" else "[" ^ selected ^ "](" ^ plain ^ ")"
    else plain in
  let title = before ^ inserted ^ after in
  title, S.utf16_length (before ^ inserted)

let remap_value mapping value =
  let remap value = match lookup_uuid value with
    | Some uuid -> Option.fold ~none:value ~some:lookup (Hashtbl.find_opt mapping uuid)
    | None -> value in
  match value with
  | D.Set xs -> D.Set (List.map remap xs)
  | D.Vector _ -> (match lookup_uuid value with Some _ -> remap value | None -> value)
  | v -> v

let rec semantic db = function
  | D.Vector [D.Keyword "block/uuid"; D.Uuid uuid] -> O.Ref_uuid uuid
  | D.Vector [D.Keyword "db/ident"; D.Keyword ident] -> O.Ref_ident ident
  | D.Ref id -> (match G.uuid_for_eid db id with Some uuid -> O.Ref_uuid uuid
      | None -> (match get db id "db/ident" with D.Keyword ident -> O.Ref_ident ident | _ -> invalid_arg "Missing clipboard reference"))
  | D.Set xs -> O.Set_value (List.map (semantic db) xs)
  | D.Vector xs -> O.Vector_value (List.map (semantic db) xs)
  | v -> (match O.semantic_value_from_datascript v with Ok v -> v | Error message -> invalid_arg message)
let raw db uuid attr =
  let values = D.Db.datoms db D.Eavt ~e:(eid db uuid) ~a:attr () |> Seq.map (fun (d : D.datom) -> d.v) |> List.of_seq in
  match values with [] -> None | [v] when not (many db attr) -> Some (semantic db v) | xs -> Some (O.Set_value (List.map (semantic db) xs))

let insert db ~now ~fresh_uuid content nodes =
  let by_id = Hashtbl.create (List.length nodes) in
  List.iter (fun node -> if Hashtbl.mem by_id node.uuid then invalid_arg "Clipboard has duplicate block identities";
    Hashtbl.add by_id node.uuid node) nodes;
  let seen = Hashtbl.create (List.length nodes) and visiting = Hashtbl.create 8 in
  let rec validate node =
    if Hashtbl.mem visiting node.uuid then invalid_arg "Clipboard contains a parent cycle";
    if not (Hashtbl.mem seen node.uuid) then begin
      Hashtbl.add visiting node.uuid ();
      Option.iter (fun parent -> Option.iter validate (Hashtbl.find_opt by_id parent)) node.parent;
      Hashtbl.remove visiting node.uuid; Hashtbl.add seen node.uuid ()
    end in
  List.iter validate nodes;
  let target_id = eid db content.target_uuid in
  let page = Option.bind (Datascript_value.optional_ref_eid db "block/page" (G.value db target_id "block/page")) (G.uuid_for_eid db)
    |> Option.value ~default:content.target_uuid in
  let existing_children = children db target_id in
  let empty = String.trim content.before_title = "" in
  let nested = List.exists (fun node -> Option.fold ~none:false ~some:(Hashtbl.mem by_id) node.parent) nodes in
  let replace = empty && (existing_children = [] || List.length nodes = 1) in
  let target_parent = Option.value ~default:page (parent_uuid db target_id) in
  let siblings = children db (eid db target_parent) in
  let parent, lower, upper =
    if replace then target_parent, Some (string (get db target_id "block/order")),
      (let rec next = function [] -> None | id :: rest when id = target_id -> Option.map (fun id -> string (get db id "block/order")) (List.nth_opt rest 0) | _ :: rest -> next rest in next siblings)
    else if empty && existing_children <> [] && nested then
      let rec previous lower = function [] -> lower | id :: _ when id = target_id -> lower | id :: rest -> previous (Some (string (get db id "block/order"))) rest in
      target_parent, previous None siblings, Some (string (get db target_id "block/order"))
    else if existing_children <> [] then content.target_uuid, None, Some (string (get db (List.hd existing_children) "block/order"))
    else
      let rec next = function [] -> None | id :: rest when id = target_id -> Option.map (fun id -> string (get db id "block/order")) (List.nth_opt rest 0) | _ :: rest -> next rest in
      target_parent, Some (string (get db target_id "block/order")), next siblings in
  let mapping = Hashtbl.create (List.length nodes) in
  List.iteri (fun index node -> Hashtbl.add mapping node.uuid
    (if index = 0 && replace then content.target_uuid else fresh_uuid ())) nodes;
  let orders = Hashtbl.create 8 in
  let operations = ref [] in
  let stage intent = operations := intent :: !operations in
  if not replace && content.before_title <> string (get db target_id "block/title") then
    stage (O.Save_title {uuid = content.target_uuid; expected_title = string (get db target_id "block/title"); title = content.before_title});
  List.iteri (fun index node ->
    let uuid = Hashtbl.find mapping node.uuid in
    let node_parent, root = match Option.bind node.parent (Hashtbl.find_opt mapping) with Some id -> id, false | None -> parent, true in
    let order = if replace && index = 0 then string (get db target_id "block/order") else
      let previous = Option.value ~default:(if root then lower else None) (Hashtbl.find_opt orders node_parent) in
      match Fractional_order.between previous (if root then upper else None) with Ok v -> v | Error message -> invalid_arg message in
    Hashtbl.replace orders node_parent (Some order);
    let title = string (field "block/title" node) in
    if replace && index = 0 then stage (O.Save_title {uuid; expected_title = string (get db target_id "block/title"); title})
    else stage (O.Insert_block {uuid; title; page_uuid = page; parent_uuid = node_parent; order; created_at = now})) nodes;
  let inserted = List.rev !operations in
  let projected = match Pending_projection.compile db (O.Atomic inserted) with
    | Ok tx -> D.db_with tx db | Error message -> invalid_arg message in
  let structural = ["db/id"; "db/ident"; "block/uuid"; "block/title"; "block/page"; "block/parent"; "block/order"; "block/level"; "block/name"] in
  List.iter (fun node ->
    let uuid = Hashtbl.find mapping node.uuid in
    let changes = List.filter_map (fun (attr, v) ->
      if List.mem attr structural || String.starts_with ~prefix:"block.temp/" attr then None
      else let expected = raw projected uuid attr and value = Some (semantic projected (remap_value mapping v)) in
        if expected = value then None else Some {O.attr; expected; value}) node.attrs in
    if changes <> [] then stage (O.Set_properties {uuid; changes})) nodes;
  let last = List.hd (List.rev nodes) in
  let uuid = Hashtbl.find mapping last.uuid in
  {intent = O.Atomic (List.rev !operations); focus = Some uuid;
   title = string (field "block/title" last); caret = S.utf16_length (string (field "block/title" last))}

let paste db ~graph ~now ~fresh_uuid content = protect (fun () ->
  let id = eid db content.target_uuid in
  let literal = List.mem (get db id "logseq.property.node/display-type") [D.Keyword "code"; D.Keyword "math"] in
  let rich = if literal then None else decode ~graph content.blocks_edn in
  let source = normalize_lines content.plain_text in
  let nodes = match rich with Some nodes -> Some nodes | None when literal -> None
    | None when has_markdown source -> Some (parse_text ~fresh_uuid source)
    | None when S.index_of ~sub:"\n\n" ~start:0 source <> None -> Some (paragraphs ~fresh_uuid source)
    | None -> None in
  match nodes with
  | Some (_ :: _ as nodes) -> insert db ~now ~fresh_uuid content nodes
  | _ -> let title, caret = inline content in
    {intent = O.Save_title {uuid = content.target_uuid; expected_title = string (get db id "block/title"); title}; focus = None; title; caret})
