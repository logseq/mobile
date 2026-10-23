let char_at value index = String.sub value index 1

let hex_character value =
  match value.[0] with
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let is_uuid value =
  String.length value = 36
  &&
  let rec loop index =
    if index = 36 then true
    else
      let character = char_at value index in
      let hyphen_slot =
        index = 8 || index = 13 || index = 18 || index = 23
      in
      if hyphen_slot then character.[0] = '-' && loop (index + 1)
      else hex_character character && loop (index + 1)
  in
  loop 0

let tag_terminator value =
  match value.[0] with
  | ' ' | '\t' | '\r' | '\n' | ',' | '.' | '(' | ')' | '[' | ']' | '#'
  | ';' | '!' | '?' | '\'' | '"' | ':' -> true
  | _ -> false

let plain_tag_label label =
  label <> ""
  &&
  let rec loop index =
    if index = String.length label then true
    else if tag_terminator (char_at label index) then false
    else loop (index + 1)
  in
  loop 0

let config =
  {
    Mldoc.Conf.toc = false;
    parse_outline_only = false;
    heading_number = false;
    keep_line_break = true;
    format = Mldoc.Conf.Markdown;
    heading_to_list = false;
    exporting_keep_properties = false;
    inline_type_with_pos = true;
    inline_skip_macro = false;
    export_md_indent_style = Mldoc.Conf.Dashes;
    export_md_remove_options = [];
    hiccup_in_block = true;
    enable_drawers = false;
    parse_marker = false;
    parse_priority = false;
  }

module Inline = Mldoc.Inline

type reference_kind = Page | Tag

type reference =
  { kind : reference_kind
  ; name : string
  ; start_pos : int
  ; end_pos : int
  }

let unbracket value =
  let length = String.length value in
  if length >= 4 && String_kit.starts_with ~prefix:"[[" value
     && String_kit.ends_with ~suffix:"]]" value then
    String.sub value 2 (length - 4)
  else value

let whitespace_at source index =
  index < String.length source &&
  let code = Uchar.to_int (Uchar.utf_decode_uchar (String.get_utf_8_uchar source index)) in
  (code >= 0x09 && code <= 0x0D) || (code >= 0x2000 && code <= 0x200A)
  || match code with
  | 0x20 | 0xA0 | 0x1680 | 0x2028 | 0x2029 | 0x202F | 0x205F | 0x3000 | 0xFEFF -> true
  | _ -> false

let hashtag_boundaries source first last =
  (* Match master's replace-tag-ref boundaries, including JavaScript whitespace. *)
  let rec previous index =
    if index > 0 && Char.code source.[index] land 0xC0 = 0x80 then previous (index - 1)
    else index in
  let rec after index =
    index = String.length source || whitespace_at source index || source.[index] = ')'
    || ((source.[index] = ',' || source.[index] = '.') && after (index + 1)) in
  first >= 0 && last >= first && last <= String.length source
  && (first = 0 || source.[first - 1] = '(' || whitespace_at source (previous (first - 1)))
  && after last

let references title =
  let add kind name start_pos end_pos acc =
    let name = String.trim (unbracket name) in
    if name = "" then acc else { kind; name; start_pos; end_pos } :: acc
  in
  let rec inlines source offset allow_tags acc =
    match Angstrom.parse_string ~consume:Angstrom.Consume.All
      (Inline.parse config) source with
    | Error _ -> acc
    | Ok nodes ->
      List.fold_left (fun acc (node, position) ->
        match position with
        | None -> acc
        | Some (pos : Mldoc.Pos.pos_meta) ->
          let start_pos = offset + pos.start_pos in
          let end_pos = offset + pos.end_pos in
          match node with
          | Inline.Tag _ when allow_tags ->
            let name = Inline.hash_tag_value_string node in
            if String_kit.starts_with ~prefix:"[[" name
               && not (String_kit.ends_with ~suffix:"]]" name) then acc
            else if not (is_uuid (unbracket name))
                    && not (hashtag_boundaries title start_pos end_pos) then acc
            else add Tag name start_pos end_pos acc
          | Inline.Nested_link link ->
            add Page link.content start_pos end_pos acc
          | Inline.Link { url = Inline.Page_ref name; _ } ->
            let raw = String.sub source pos.start_pos (pos.end_pos - pos.start_pos) in
            let target = "[[" ^ name ^ "]]" in
            (* For aliases, replace the destination while preserving the label. *)
            let target_start =
              if String_kit.starts_with ~prefix:"[[" raw then Some 0
              else
                match String_kit.last_index_of ~sub:"](" raw with
                | Some opening -> String_kit.index_of ~sub:target ~start:(opening + 2) raw
                | None -> None
            in
            (match target_start with
             | Some start -> add Page name (start_pos + start)
                 (start_pos + start + String.length target) acc
             | None -> acc)
          | Inline.Emphasis (style, _) ->
            (* Emphasis children have no positions. Reparse the inner source for
               page refs; mldoc treats hashtags inside emphasis as plain text. *)
            let delimiter = match style with `Italic -> 1 | _ -> 2 in
            let length = pos.end_pos - pos.start_pos - (2 * delimiter) in
            if length <= 0 then acc
            else inlines (String.sub source (pos.start_pos + delimiter) length)
              (start_pos + delimiter) false acc
          | _ -> acc)
        acc nodes
  in
  (* Block spans exclude fenced code, including tilde fences, before inline
     parsing. All offsets are UTF-8 byte offsets into the unchanged source. *)
  let blocks =
    if String.contains title '[' || String.contains title '#' then
      Mldoc.Parser.parse config title
    else []
  in
  List.fold_left (fun acc (block, (pos : Mldoc.Pos.pos_meta)) ->
    match block with
    | Mldoc.Type.Src _ | Mldoc.Type.Example _ -> acc
    | _ ->
      inlines (String.sub title pos.start_pos (pos.end_pos - pos.start_pos))
        pos.start_pos true acc)
    [] blocks
  |> List.rev

let page_names title = List.map (fun reference -> reference.name) (references title)

let tag_names title =
  List.filter_map (fun reference ->
    if reference.kind = Tag then Some reference.name else None) (references title)

(* Completion uses the whole source, including syntax to the right of the caret.
   mldoc positions are byte offsets; callers convert native UTF-16 carets first.
   Closed syntax also ends any earlier completion query. *)
let completion_prefix title caret =
  let caret = max 0 (min caret (String.length title)) in
  let blocked = ref false and floor = ref 0 in
  let protect start_pos end_pos =
    if caret > start_pos && caret < end_pos then blocked := true;
    if end_pos <= caret then floor := max !floor end_pos
  in
  let rec inlines source offset =
    match Angstrom.parse_string ~consume:Angstrom.Consume.All
      (Inline.parse config) source with
    | Error _ -> ()
    | Ok nodes -> List.iter (fun (node, position) ->
        match position with
        | None -> ()
        | Some (pos : Mldoc.Pos.pos_meta) ->
          let first = offset + pos.start_pos and last = offset + pos.end_pos in
          match node with
          | Inline.Nested_link _ -> if caret >= last then protect first last
          | Inline.Link { url = Inline.Page_ref name; _ } ->
            let raw = String.sub source pos.start_pos (pos.end_pos - pos.start_pos) in
            if String_kit.starts_with ~prefix:"[[" raw then begin
              if caret >= last then protect first last
            end else begin
              (* An alias label is literal; only its wiki destination is editable. *)
              let destination = match String_kit.last_index_of ~sub:"](" raw with
                | Some opening -> String_kit.index_of ~sub:("[[" ^ name ^ "]]")
                    ~start:(opening + 2) raw
                | None -> None in
              match destination with
              | Some start when caret > first + start && caret < last - 1 -> ()
              | _ -> protect first last
            end
          | Inline.Link _ | Inline.Code _ | Inline.Verbatim _
          | Inline.Latex_Fragment _ | Inline.Macro _ | Inline.Inline_Source_Block _
          | Inline.Inline_Hiccup _ | Inline.Inline_Html _ -> protect first last
          | Inline.Emphasis (style, _) ->
            let delimiter = match style with `Italic -> 1 | _ -> 2 in
            let length = pos.end_pos - pos.start_pos - (2 * delimiter) in
            if length > 0 then inlines
              (String.sub source (pos.start_pos + delimiter) length) (first + delimiter)
          | _ -> ()) nodes
  in
  List.iter (fun (block, (pos : Mldoc.Pos.pos_meta)) ->
    match block with
    | Mldoc.Type.Src _ | Mldoc.Type.Example _ -> protect pos.start_pos pos.end_pos
    | _ -> inlines (String.sub title pos.start_pos (pos.end_pos - pos.start_pos)) pos.start_pos)
    (Mldoc.Parser.parse config title);
  if !blocked then "" else String.sub title !floor (caret - !floor)

let rewrite resolve title =
  let result = Buffer.create (String.length title) in
  let offset = ref 0 in
  List.iter (fun reference ->
    match resolve reference with
    | None -> ()
    | Some replacement ->
      Buffer.add_substring result title !offset (reference.start_pos - !offset);
      Buffer.add_string result replacement;
      offset := reference.end_pos)
    (references title);
  Buffer.add_substring result title !offset (String.length title - !offset);
  Buffer.contents result

let to_text tag_title ref_title title =
  rewrite (fun reference ->
    match reference.kind with
    | Page -> Option.map (fun label -> "[[" ^ label ^ "]]") (ref_title reference.name)
    | Tag ->
      (* Plain hashtags already contain editor text. *)
      if title.[reference.start_pos + 1] <> '[' then None
      else Option.map (fun label ->
        if plain_tag_label label then "#" ^ label else "#[[" ^ label ^ "]]")
        (tag_title reference.name)) title

let to_ids resolve_ref resolve_tag title =
  rewrite (fun reference ->
    if is_uuid reference.name then None
    else match reference.kind with
    | Page -> Option.map (fun uuid -> "[[" ^ uuid ^ "]]") (resolve_ref reference.name)
    | Tag -> Option.map (fun uuid -> "#[[" ^ uuid ^ "]]") (resolve_tag reference.name)) title
