let native_input_policy = {|{"emptyPairs":[{"text":"[[]]","deleteOffset":1}]}|}

module Sset = Set.Make (String)
module Model = Cache_model
module Ops = Pending_ops
module Order = Fractional_order
module Ref_text = Ref_text
module Search = Search_index

type reducer_autocomplete_kind = Node | Tag | Property

type reducer_autocomplete =
  { kind : reducer_autocomplete_kind
  ; query : string
  }

type outliner_candidate =
  { label : string
  ; value : string
  }

type editor_draft =
  { uuid : string
  ; expected_title : string
  ; title : string
  ; caret : int
  }

type outliner_state =
  { editing : editor_draft option
  ; selected : Sset.t
  ; pending_deletion : string list
  ; autocomplete : reducer_autocomplete option
  ; collapsed : Sset.t
  ; zoomed : string list
  }

type outliner_toolbar =
  | Task
  | Outdent
  | Indent
  | Move_up
  | Move_down
  | Tag_action
  | Page_reference
  | Camera
  | Audio
  | Attachment
  | Hide_keyboard
  | Copy
  | Delete
  | Copy_reference
  | Copy_url
  | Unselect

type outliner_placement = Before | Inside | After

type outliner_text =
  { title : string
  ; caret : int
  }

type outliner_selection =
  { selection_length : int
  }

type outliner_backspace =
  { backspace_title : string
  ; backspace_selection_length : int
  }

type outliner_drop =
  { target_uuid : string
  ; placement : outliner_placement
  }

type outliner_status =
  { status_uuid : string
  ; status : Ops.semantic_value
  }

type outliner_message =
  | Tap_block of string
  | Long_press_block of string
  | Text_changed of outliner_text
  | Caret_moved of int
  | Return_pressed
  | Return_pressed_with_text of outliner_text
  | Backspace_pressed of outliner_selection
  | Backspace_pressed_with_text of outliner_backspace
  | Toolbar of outliner_toolbar
  | Drop_blocks of outliner_drop
  | Choose_autocomplete of string
  | Confirm_delete
  | Save_editing
  | Cancel_editing
  | Set_task_status of outliner_status
  | Toggle_collapsed of string
  | Zoom_in of string
  | Zoom_out
  | Add_root_block of string
  | Operation_staged of Ops.pending_intent

type outliner_haptic = Selection | Impact

type outliner_split =
  { split_uuid : string
  ; split_expected_title : string
  ; before : string
  ; after : string
  }

type outliner_merge =
  { merge_uuid : string
  ; merge_expected_title : string
  ; merge_title : string
  ; previous_uuid : string
  ; expected_previous_title : string
  }

type outliner_tag =
  { tag_target_uuid : string
  ; value : string
  }

type outliner_root =
  { page_uuid : string
  }

type outliner_command =
  | Haptic of outliner_haptic
  | Commit_title of Ops.pending_title
  | Split_at of outliner_split
  | Merge_into_previous of outliner_merge
  | Reparent_blocks of Ops.pending_move list
  | Request_delete_confirmation of string list
  | Remove_blocks of string list
  | Cycle_task_status of string
  | Set_task_status_value of outliner_status
  | Create_linked_page of string
  | Assign_tag of outliner_tag
  | Pick_attachment of string
  | Take_photo of string
  | Record_audio of string
  | Insert_root_block of outliner_root
  | Copy_text of string
  | Copy_references of string list
  | Copy_urls of string list

type outliner_context =
  { blocks : Model.block list
  ; pages : outliner_candidate list
  ; tags : outliner_candidate list
  ; label_values : (string, Sset.t) Hashtbl.t
  ; dup_labels : Sset.t
  ; search_nodes : string -> outliner_candidate list
  ; is_block_reference : string -> bool
  }

type outliner_row =
  { block : Model.block
  ; depth : int
  ; has_children : bool
  ; is_collapsed : bool
  }

let empty =
  {
    editing = None;
    selected = Sset.empty;
    pending_deletion = [];
    autocomplete = None;
    collapsed = Sset.empty;
    zoomed = [];
  }

let editing_uuid (state : outliner_state) =
  match state.editing with Some draft -> Some draft.uuid | None -> None

let editing_title (state : outliner_state) =
  match state.editing with Some draft -> Some draft.title | None -> None

let selected_uuids (state : outliner_state) = Sset.elements state.selected
let collapsed_uuids (state : outliner_state) = Sset.elements state.collapsed
let autocomplete (state : outliner_state) = state.autocomplete
let zoom_path (state : outliner_state) = state.zoomed

let find_block (context : outliner_context) uuid =
  List.find_opt (fun (block : Model.block) -> block.uuid = uuid) context.blocks

let candidate_label_values candidates =
  List.fold_left
    (fun values (candidate : outliner_candidate) ->
      let key = String.lowercase_ascii candidate.label in
      let existing =
        match Hashtbl.find_opt values key with
        | Some set -> set
        | None -> Sset.empty
      in
      Hashtbl.replace values key (Sset.add candidate.value existing);
      values)
    (Hashtbl.create 32) candidates

let duplicated_of label_values =
  Hashtbl.fold
    (fun label values acc ->
      if Sset.cardinal values > 1 then Sset.add label acc else acc)
    label_values Sset.empty

let duplicated_labels candidates =
  duplicated_of (candidate_label_values candidates)

let context ?(search_nodes = fun _ -> []) ?is_block_reference blocks pages tags =
  let is_block_reference = match is_block_reference with
    | Some resolve -> resolve
    | None -> fun uuid -> List.exists (fun (block : Model.block) ->
        block.uuid = uuid && block.page_id <> uuid) blocks in
  let label_values = candidate_label_values (pages @ tags) in
  {
    blocks;
    pages;
    tags;
    label_values;
    dup_labels = duplicated_of label_values;
    search_nodes;
    is_block_reference;
  }

let summary_candidates summaries =
  List.map
    (fun (summary : Model.entity_summary) ->
      { label = summary.title; value = summary.uuid })
    summaries

let summary_title duplicated (summaries : Model.entity_summary list) uuid =
  List.find_map
    (fun (summary : Model.entity_summary) ->
      if
        summary.uuid = uuid && String_kit.trim summary.title <> ""
        && not (Sset.mem (String.lowercase_ascii summary.title) duplicated)
      then Some summary.title
      else None)
    summaries

let display_block_title (context : outliner_context) (block : Model.block) =
  let dup, _label_values =
    List.fold_left
      (fun (dup, label_values) (candidate : outliner_candidate) ->
        let key = String.lowercase_ascii candidate.label in
        let existing =
          match Hashtbl.find_opt label_values key with
          | Some set -> set
          | None -> Sset.empty
        in
        let values = Sset.add candidate.value existing in
        ( (if Sset.cardinal values > 1 then Sset.add key dup else dup)
        , (Hashtbl.replace label_values key values;
           label_values) ))
      (context.dup_labels, context.label_values)
      (summary_candidates (block.references @ block.tags))
  in
  Ref_text.to_text
    (summary_title dup (block.tags @ block.references))
    (summary_title dup (block.references @ block.tags))
    block.title

let utf8_sequence_length byte =
  if byte land 128 = 0 then 1
  else if byte land 224 = 192 then 2
  else if byte land 240 = 224 then 3
  else if byte land 248 = 240 then 4
  else 1

let utf16_units byte = if utf8_sequence_length byte = 4 then 2 else 1

let byte_index_of_utf16 value offset =
  let rec loop index units =
    if index >= String.length value || units >= max 0 offset then index
    else
      let byte = Char.code value.[index] in
      loop
        (min (String.length value) (index + utf8_sequence_length byte))
        (units + utf16_units byte)
  in
  loop 0 0

let utf16_length value =
  let rec loop index units =
    if index >= String.length value then units
    else
      let byte = Char.code value.[index] in
      loop
        (min (String.length value) (index + utf8_sequence_length byte))
        (units + utf16_units byte)
  in
  loop 0 0

let prefix_at value caret = String.sub value 0 (byte_index_of_utf16 value caret)

let last_substring value needle =
  let size = String.length needle in
  if size <= 0 then None
  else
    let rec loop index found =
      if index + size > String.length value then found
      else
        loop (index + 1)
          (if String.sub value index size = needle then Some index else found)
    in
    loop 0 None

let contains_substring value needle = String_kit.includes ~sub:needle value

let includes_normalized_query value query =
  query = "" || String_kit.includes ~sub:query (String.lowercase_ascii value)

let includes_case_insensitive value query =
  includes_normalized_query value
    (String.lowercase_ascii (String_kit.trim query))

let rec take_n n xs =
  if n <= 0 then []
  else match xs with [] -> [] | x :: rest -> x :: take_n (n - 1) rest

let autocomplete_candidates (context : outliner_context) request =
  let query = String_kit.trim request.query in
  let normalized = String.lowercase_ascii query in
  let raw =
    match request.kind with
    | Node ->
      context.pages
      @ List.map
          (fun (block : Model.block) ->
            { label = block.title; value = block.uuid })
          context.blocks
    | Tag -> context.tags
    | Property ->
      List.map
        (fun label -> { label; value = label })
        [ "status"; "tags"; "alias"; "priority" ]
  in
  let fuzzy = request.kind = Tag && normalized <> "" in
  let seen = Hashtbl.create 32 in
  let indexed = if request.kind = Node && query <> "" then context.search_nodes query else [] in
  let matches = indexed @
    List.filter
      (fun (candidate : outliner_candidate) ->
        String_kit.trim candidate.label <> ""
        && (if fuzzy then
              Search.fuzzy_score normalized candidate.label > 0.0
            else includes_normalized_query candidate.label normalized))
      raw
  in
  let matches = List.filter (fun (candidate : outliner_candidate) ->
        if Hashtbl.mem seen candidate.value then false
        else begin
          Hashtbl.add seen candidate.value ();
          true
        end) matches
  in
  let matches =
    take_n 12
      (if fuzzy then
         List.sort
           (fun (a : outliner_candidate) (b : outliner_candidate) ->
             compare
               (Search.fuzzy_score normalized b.label)
               (Search.fuzzy_score normalized a.label))
           matches
       else matches)
  in
  if
    request.kind = Tag && query <> ""
    && not
         (List.exists
            (fun (candidate : outliner_candidate) ->
              String.lowercase_ascii candidate.label = normalized)
            matches)
  then matches @ [ { label = "New tag: " ^ query; value = query } ]
  else if request.kind = Node && matches = [] && query <> "" then
    [ { label = "New page: " ^ query; value = query } ]
  else matches

let contains_from value start needle =
  Option.is_some
    (last_substring
       (String.sub value start (String.length value - start))
       needle)

let token_request kind marker prefix =
  match String.rindex_opt prefix marker with
  | Some index ->
    let query =
      String.sub prefix (index + 1) (String.length prefix - index - 1)
    in
    let word_boundary =
      index = 0
      || (match prefix.[index - 1] with ' ' | '\t' | '\r' | '\n' -> true | _ -> false)
      || (index >= 2 && String.sub prefix (index - 2) 2 = "]]")
    in
    if word_boundary && not (String_kit.includes ~sub:"\n" query) then
      Some { kind; query }
    else None
  | None -> None

(* Completion markers in code and escaped text are literal. Once a code
   span closes, an earlier marker cannot consume the prose after it. *)
let completion_prefix prefix =
  let length = String.length prefix in
  let visible = Bytes.of_string prefix in
  let rec ticks index =
    if index < length && prefix.[index] = '`' then ticks (index + 1) else index in
  let rec scan index code_width start =
    if index >= length then
      if code_width <> 0 then "" else Bytes.sub_string visible start (length - start)
    else if prefix.[index] = '\\' && code_width = 0 && index + 1 < length then begin
      (match prefix.[index + 1] with
       | '#' | '[' | ':' -> Bytes.set visible (index + 1) ' '
       | _ -> ());
      scan (index + 2) code_width start
    end else if prefix.[index] = '`' then
      let next = ticks index in
      let width = next - index in
      if code_width = 0 then scan next width start
      else if width = code_width || (code_width >= 3 && width >= code_width) then scan next 0 next
      else scan next code_width start
    else scan (index + 1) code_width start
  in
  scan 0 0 0

let autocomplete_for title caret =
  let prefix = completion_prefix
    (Ref_text.completion_prefix title (byte_index_of_utf16 title caret)) in
  match last_substring prefix "[[" with
  | Some index ->
    if not (contains_from prefix (index + 2) "]]") then
      Some
        {
          kind = Node;
          query =
            String.sub prefix (index + 2) (String.length prefix - index - 2);
        }
    else
      (match last_substring prefix "::" with
       | Some index ->
         let start =
           match String.rindex_from_opt prefix index '\n' with
           | Some newline -> newline + 1
           | None -> 0
         in
         Some
           { kind = Property; query = String.sub prefix start (index - start) }
       | None -> token_request Tag '#' prefix)
  | None ->
    (match last_substring prefix "::" with
     | Some index ->
       let start =
         match String.rindex_from_opt prefix index '\n' with
         | Some newline -> newline + 1
         | None -> 0
       in
       Some
         { kind = Property; query = String.sub prefix start (index - start) }
     | None -> token_request Tag '#' prefix)

let replace_range value start finish replacement =
  String.sub value 0 start ^ replacement
  ^ String.sub value finish (String.length value - finish)

let candidate_label (context : outliner_context) candidates value =
  let duplicated = context.dup_labels in
  List.find_map
    (fun (candidate : outliner_candidate) ->
      if
        candidate.value = value && String_kit.trim candidate.label <> ""
        && not
             (Sset.mem (String.lowercase_ascii candidate.label) duplicated)
      then Some candidate.label
      else None)
    candidates

let reference_token_end title caret_byte =
  let size = String.length title in
  let rec loop index =
    if index >= size then caret_byte
    else if title.[index] = '\n' then caret_byte
    else if index + 1 < size && String.sub title index 2 = "[[" then caret_byte
    else if title.[index] = ']' then
      if index + 1 < size && title.[index + 1] = ']' then index + 2
      else if index = caret_byte then index + 1
      else caret_byte
    else loop (index + 1)
  in
  loop caret_byte

let complete (context : outliner_context) (editing : editor_draft) kind value =
  let caret_byte = byte_index_of_utf16 editing.title editing.caret in
  let prefix = String.sub editing.title 0 caret_byte in
  let completion =
    match kind with
    | Node ->
      let text =
        if context.is_block_reference value then value
        else match candidate_label context (context.pages @ context.tags) value with
        | Some label -> label
        | None -> value
      in
      (match last_substring prefix "[[" with
       | Some index -> Some (index, "[[" ^ text ^ "]]")
       | None -> None)
    | Tag ->
      let label = candidate_label context context.tags value in
      let text = match label with Some label -> label | None -> value in
      let plain =
        Ref_text.plain_tag_label text
        && (Option.is_some label || not (Ref_text.is_uuid value))
      in
      (match String.rindex_opt prefix '#' with
       | Some index ->
         Some (index, if plain then "#" ^ text else "#[[" ^ text ^ "]]")
       | None -> None)
    | Property ->
      let start =
        match String.rindex_opt prefix '\n' with
        | Some newline -> newline + 1
        | None -> 0
      in
      Some (start, value ^ ":: ")
  in
  match completion with
  | Some (start, replacement) ->
    let finish =
      if kind = Node then reference_token_end editing.title caret_byte
      else caret_byte
    in
    let title = replace_range editing.title start finish replacement in
    Some
      {
        editing with
        title;
        caret =
          utf16_length
            (String.sub title 0 (start + String.length replacement));
      }
  | None -> None

let trim_right value =
  let rec loop finish =
    if
      finish > 0
      && List.mem value.[finish - 1] [ ' '; '\t'; '\n'; '\r' ]
    then loop (finish - 1)
    else String.sub value 0 finish
  in
  loop (String.length value)

let remove_tag_token (editing : editor_draft) =
  let index = byte_index_of_utf16 editing.title editing.caret in
  match String.rindex_opt (String.sub editing.title 0 index) '#' with
  | Some start ->
    let before = trim_right (String.sub editing.title 0 start) in
    let suffix =
      String.sub editing.title index (String.length editing.title - index)
    in
    let separator =
      if
        before = "" || suffix = ""
        || String_kit.starts_with ~prefix:" " suffix
        || String_kit.starts_with ~prefix:"\n" suffix
      then ""
      else " "
    in
    Some
      {
        editing with
        title = before ^ separator ^ suffix;
        caret = utf16_length before;
      }
  | None -> None

let commit_effect (context : outliner_context) editing =
  match editing with
  | Some (editing : editor_draft) ->
    let expected =
      match find_block context editing.uuid with
      | Some block ->
        display_block_title context
          { block with title = editing.expected_title }
      | None -> editing.expected_title
    in
    if expected = editing.title then []
    else
      [
        Commit_title
          {
            uuid = editing.uuid;
            expected_title = editing.expected_title;
            title = editing.title;
          };
      ]
  | None -> []

let insert_at_caret (editing : editor_draft) text backward_utf16 =
  let index = byte_index_of_utf16 editing.title editing.caret in
  let prefix = String.sub editing.title 0 index in
  let inserted =
    (if prefix = "" || String_kit.ends_with ~suffix:" " prefix then ""
     else " ")
    ^ text
  in
  {
    editing with
    title = replace_range editing.title index index inserted;
    caret = utf16_length (prefix ^ inserted) - backward_utf16;
  }

let compare_blocks (left : Model.block) (right : Model.block) =
  match (left.order, right.order) with
  | Some a, Some b ->
    if a <> b then compare a b
    else
      let created = compare left.created_at right.created_at in
      if created <> 0 then created else compare left.uuid right.uuid
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None ->
    let created = compare left.created_at right.created_at in
    if created <> 0 then created else compare left.uuid right.uuid

let compare_root_blocks (left : Model.block) (right : Model.block) =
  match (left.journal, right.journal) with
  | Some (_, a), Some (_, b) ->
    if a <> b then compare b a else compare_blocks left right
  | _ -> compare_blocks left right

let sorted_siblings (context : outliner_context) parent =
  List.sort compare_blocks
    (List.filter
       (fun (block : Model.block) -> block.parent_id = parent)
       context.blocks)

let visible_rows (context : outliner_context) (state : outliner_state) =
  let ids =
    List.fold_left
      (fun set (block : Model.block) -> Sset.add block.uuid set)
      Sset.empty context.blocks
  in
  let children_by_parent = Hashtbl.create 64 in
  List.iter
    (fun (block : Model.block) ->
      let key = block.parent_id in
      let existing =
        match Hashtbl.find_opt children_by_parent key with
        | Some children -> children
        | None -> []
      in
      Hashtbl.replace children_by_parent key (block :: existing))
    context.blocks;
  Hashtbl.iter
    (fun key children ->
      Hashtbl.replace children_by_parent key
        (List.sort compare_blocks children))
    children_by_parent;
  let children uuid =
    match Hashtbl.find_opt children_by_parent (Some uuid) with
    | Some children -> children
    | None -> []
  in
  let roots =
    List.sort compare_root_blocks
      (List.filter
         (fun (block : Model.block) ->
           match block.parent_id with
           | Some parent -> not (Sset.mem parent ids)
           | None -> true)
         context.blocks)
  in
  let visited = ref Sset.empty in
  let rec hide_descendants uuid =
    List.iter
      (fun (block : Model.block) ->
        if not (Sset.mem block.uuid !visited) then begin
          visited := Sset.add block.uuid !visited;
          hide_descendants block.uuid
        end)
      (children uuid)
  in
  let rec append_row depth rows (block : Model.block) =
    if Sset.mem block.uuid !visited then rows
    else begin
      visited := Sset.add block.uuid !visited;
      let descendants = children block.uuid in
      let collapsed = Sset.mem block.uuid state.collapsed in
      let rows =
            {
              block;
              depth;
              has_children = descendants <> [];
              is_collapsed = collapsed;
            } :: rows
      in
      if collapsed then begin
        hide_descendants block.uuid;
        rows
      end
      else
        List.fold_left
          (fun rows child -> append_row (depth + 1) rows child)
          rows descendants
    end
  in
  let rows =
    match
      match List.rev state.zoomed with
      | [] -> None
      | uuid :: _ -> find_block context uuid
    with
    | Some root -> append_row 0 [] root
    | None -> List.fold_left (fun rows block -> append_row 0 rows block) [] roots
  in
  let rows =
    if state.zoomed = [] then
      List.fold_left (fun rows block -> append_row 0 rows block) rows context.blocks
    else rows
  in
  List.rev rows

let selected_roots (context : outliner_context) selected =
  let by_uuid = Hashtbl.create 64 in
  List.iter
    (fun (block : Model.block) -> Hashtbl.replace by_uuid block.uuid block)
    context.blocks;
  let selected_ancestor (block : Model.block) =
    let visited = ref Sset.empty in
    let rec loop parent =
      match parent with
      | Some uuid ->
        if Sset.mem uuid !visited then false
        else if Sset.mem uuid selected then true
        else begin
          visited := Sset.add uuid !visited;
          (match Hashtbl.find_opt by_uuid uuid with
           | Some ancestor -> loop ancestor.parent_id
           | None -> false)
        end
      | None -> false
    in
    loop block.parent_id
  in
  List.filter
    (fun (block : Model.block) ->
      Sset.mem block.uuid selected && not (selected_ancestor block))
    context.blocks

let moves_with_orders roots parent_uuid lower upper =
  match Order.n_between lower upper (List.length roots) with
  | Error _ -> None
  | Ok orders ->
    Some
      (List.map2
         (fun (block : Model.block) value ->
           {
             Ops.uuid = block.uuid;
             page_uuid = block.page_id;
             parent_uuid;
             order = value;
           })
         roots orders)

let index_of_uuid uuid blocks =
  let rec loop index rest =
    match rest with
    | [] -> None
    | (block : Model.block) :: remaining ->
      if block.uuid = uuid then Some index else loop (index + 1) remaining
  in
  loop 0 blocks

let selection_indices roots siblings =
  let ids =
    List.fold_left
      (fun set (block : Model.block) -> Sset.add block.uuid set)
      Sset.empty roots
  in
  let rec loop index acc rest =
    match rest with
    | [] -> List.rev acc
    | (block : Model.block) :: remaining ->
      loop (index + 1)
        (if Sset.mem block.uuid ids then index :: acc else acc)
        remaining
  in
  loop 0 [] siblings

let selection_is_contiguous roots siblings =
  let indices = selection_indices roots siblings in
  indices <> []
  && List.length indices = List.length roots
  &&
  match indices with
  | first :: _ ->
    List.for_all2
      (fun offset index -> index = first + offset)
      (List.init (List.length indices) (fun i -> i))
      indices
  | [] -> false

let same_parent roots parent =
  List.for_all (fun (block : Model.block) -> block.parent_id = parent) roots

let indent (context : outliner_context) selected =
  let roots = selected_roots context selected in
  match roots with
  | [] -> None
  | first :: _ ->
    let siblings =
      sorted_siblings context (first : Model.block).parent_id
    in
    let indices = selection_indices roots siblings in
    if
      same_parent roots first.parent_id && indices <> []
      && List.hd indices > 0
      && selection_is_contiguous roots siblings
    then
      let parent = List.nth siblings (List.hd indices - 1) in
      let children = sorted_siblings context (Some parent.uuid) in
      let lower =
        match List.rev children with
        | last :: _ -> last.order
        | [] -> None
      in
      moves_with_orders roots parent.uuid lower None
    else None

let outdent (context : outliner_context) selected =
  let roots = selected_roots context selected in
  match roots with
  | [] -> None
  | first :: _ ->
    if not (same_parent roots (first : Model.block).parent_id) then None
    else
      (match first.parent_id with
       | Some uuid -> find_block context uuid
       | None -> None)
      |> (fun parent ->
        match parent with
        | Some (parent : Model.block) ->
          let siblings = sorted_siblings context (Some parent.uuid) in
          if selection_is_contiguous roots siblings then
            let parent_uuid =
              match parent.parent_id with
              | Some uuid -> uuid
              | None -> parent.page_id
            in
            let parent_row = sorted_siblings context (Some parent_uuid) in
            (match index_of_uuid parent.uuid parent_row with
             | Some index ->
               (match
                  moves_with_orders roots parent_uuid parent.order
                    (if index + 1 < List.length parent_row then
                       (List.nth parent_row (index + 1)).order
                     else None)
                with
                | Some moves ->
                  (* logseq direct outdenting: the trailing siblings of the
                     last moved block become its children *)
                  let last_index =
                    List.fold_left max 0 (selection_indices roots siblings)
                  in
                  let last = List.nth siblings last_index in
                  let trailing =
                    List.filteri (fun i _ -> i > last_index) siblings
                  in
                  (match trailing with
                   | [] -> Some moves
                   | trailing ->
                     let lower =
                       match
                         List.rev (sorted_siblings context (Some last.uuid))
                       with
                       | child :: _ -> child.order
                       | [] -> None
                     in
                     (match moves_with_orders trailing last.uuid lower None with
                      | Some adopted -> Some (moves @ adopted)
                      | None -> Some moves))
                | None -> None)
             | None -> None)
          else None
        | None -> None)

let ancestor_uuids (context : outliner_context) (block : Model.block) =
  let visited = ref Sset.empty in
  let rec loop parent =
    match parent with
    | Some uuid ->
      if Sset.mem uuid !visited then ()
      else begin
        visited := Sset.add uuid !visited;
        (match find_block context uuid with
         | Some ancestor -> loop ancestor.parent_id
         | None -> ())
      end
    | None -> ()
  in
  loop block.parent_id;
  !visited

let drop (context : outliner_context) selected target_uuid placement =
  let roots = selected_roots context selected in
  let ids =
    List.fold_left
      (fun set (block : Model.block) -> Sset.add block.uuid set)
      Sset.empty roots
  in
  if roots = [] then None
  else
    match find_block context target_uuid with
    | Some target ->
      if
        Sset.mem target_uuid ids
        || not (Sset.is_empty (Sset.inter ids (ancestor_uuids context target)))
      then None
      else if placement = Inside then
        let lower =
          match List.rev (sorted_siblings context (Some target.uuid)) with
          | last :: _ -> last.order
          | [] -> None
        in
        moves_with_orders roots target.uuid lower None
      else
        let parent =
          match (target : Model.block).parent_id with
          | Some uuid -> uuid
          | None -> target.page_id
        in
        let siblings =
          List.filter
            (fun (block : Model.block) -> not (Sset.mem block.uuid ids))
            (sorted_siblings context (Some parent))
        in
        (match index_of_uuid target_uuid siblings with
         | Some index ->
           if placement = Before then
             moves_with_orders roots parent
               (if index > 0 then (List.nth siblings (index - 1)).order else None)
               target.order
           else
             moves_with_orders roots parent target.order
               (if index + 1 < List.length siblings then
                  (List.nth siblings (index + 1)).order
                else None)
         | None -> None)
    | None -> None

let step (state : outliner_state) commands = (state, commands)

let leave_interaction context (state : outliner_state) =
  step
    { state with editing = None; selected = Sset.empty; autocomplete = None }
    (commit_effect context state.editing)

let split_editing (state : outliner_state) (editing : editor_draft) =
  let index = byte_index_of_utf16 editing.title editing.caret in
  step
    { state with editing = None; autocomplete = None }
    [
      Split_at
        {
          split_uuid = editing.uuid;
          split_expected_title = editing.expected_title;
          before = String.sub editing.title 0 index;
          after =
            String.sub editing.title index
              (String.length editing.title - index);
        };
    ]

let split_or_outdent (context : outliner_context) (state : outliner_state)
    (editing : editor_draft) =
  let final_nested_empty =
    match find_block context editing.uuid with
    | Some (block : Model.block) ->
      String_kit.is_blank editing.title
      && block.parent_id <> Some block.page_id
      &&
      (match List.rev (sorted_siblings context block.parent_id) with
       | last :: _ -> last.uuid = block.uuid
       | [] -> false)
    | None -> false
  in
  if final_nested_empty then
    match outdent context (Sset.singleton editing.uuid) with
    | Some moves ->
      step
        { state with editing = Some editing; autocomplete = None }
        (commit_effect context (Some editing) @ [ Reparent_blocks moves ])
    | None -> split_editing state editing
  else split_editing state editing

let start_editing context (state : outliner_state) block caret =
  {
    state with
    editing =
      Some
        {
          uuid = (block : Model.block).uuid;
          expected_title = block.title;
          title = display_block_title context block;
          caret;
        };
    autocomplete = None;
  }

let merge_backward context (state : outliner_state) (editing : editor_draft) =
  match find_block context editing.uuid with
  | Some (block : Model.block) ->
    let rows =
      List.filter
        (fun (row : outliner_row) -> row.block.page_id = block.page_id)
        (visible_rows context state)
    in
    let index =
      match
        let rec loop index rest =
          match rest with
          | [] -> None
          | (row : outliner_row) :: remaining ->
            if row.block.uuid = editing.uuid then Some index
            else loop (index + 1) remaining
        in
        loop 0 rows
      with
      | Some index -> index
      | None -> List.length rows
    in
    if index > 0 then
      let previous = (List.nth rows (index - 1)).block in
      step state
        [
          Merge_into_previous
            {
              merge_uuid = editing.uuid;
              merge_expected_title = editing.expected_title;
              merge_title = editing.title;
              previous_uuid = previous.uuid;
              expected_previous_title = previous.title;
            };
        ]
    else if index + 1 < List.length rows then
      step
        (start_editing context state (List.nth rows (index + 1)).block 0)
        [ Remove_blocks [ editing.uuid ] ]
    else step state []
  | None -> step state []

let toggle_member values value =
  if Sset.mem value values then Sset.remove value values
  else Sset.add value values

let interaction_targets (state : outliner_state) =
  if Sset.is_empty state.selected then
    match state.editing with
    | Some editing -> Sset.singleton editing.uuid
    | None -> Sset.empty
  else state.selected

let toolbar_insert (state : outliner_state) text backward =
  match state.editing with
  | Some editing ->
    let editing = insert_at_caret editing text backward in
    step
      {
        state with
        editing = Some editing;
        autocomplete = autocomplete_for editing.title editing.caret;
      }
      [ Haptic Impact ]
  | None -> step state []

let move (context : outliner_context) selected up_ =
  let roots = selected_roots context selected in
  match roots with
  | [] -> None
  | first :: _ ->
    if not (same_parent roots (first : Model.block).parent_id) then None
    else
      let parent =
        match first.parent_id with Some uuid -> uuid | None -> first.page_id
      in
      let siblings = sorted_siblings context (Some parent) in
      (match selection_indices roots siblings with
       | [] -> None
       | first_index :: _ as indices ->
         if not (selection_is_contiguous roots siblings) then None
         else
           let last_index = first_index + List.length indices - 1 in
           (* like logseq's move-blocks-up-down: at a boundary the selection
              crosses into the parent's neighbor as its first child *)
           let parent_neighbor before =
             if parent = first.page_id then None
             else
               match find_block context parent with
               | Some parent_block ->
                 let grandparent =
                   match (parent_block : Model.block).parent_id with
                   | Some uuid -> uuid
                   | None -> parent_block.page_id
                 in
                 let parent_siblings =
                   sorted_siblings context (Some grandparent)
                 in
                 (match index_of_uuid parent_block.uuid parent_siblings with
                  | Some index ->
                    let neighbor_index =
                      if before then index - 1 else index + 1
                    in
                    if
                      neighbor_index < 0
                      || neighbor_index >= List.length parent_siblings
                    then None
                    else Some (List.nth parent_siblings neighbor_index)
                  | None -> None)
               | None -> None
           in
           let first_child_order (block : Model.block) =
             match sorted_siblings context (Some block.uuid) with
             | child :: _ -> child.order
             | [] -> None
           in
           if up_ then
             if first_index = 0 then
               match parent_neighbor true with
               | Some neighbor ->
                 moves_with_orders roots neighbor.uuid None
                   (first_child_order neighbor)
               | None -> None
             else
               let target = List.nth siblings (first_index - 1) in
               let lower =
                 if first_index > 1 then
                   (List.nth siblings (first_index - 2)).order
                 else None
               in
               moves_with_orders roots parent lower target.order
           else if last_index + 1 >= List.length siblings then
             match parent_neighbor false with
             | Some neighbor ->
               moves_with_orders roots neighbor.uuid None
                 (first_child_order neighbor)
             | None -> None
           else
             let target = List.nth siblings (last_index + 1) in
             let upper =
               if last_index + 2 < List.length siblings then
                 (List.nth siblings (last_index + 2)).order
               else None
             in
             moves_with_orders roots parent target.order upper)

let toolbar_move context (state : outliner_state) outdent_ =
  let moves =
    if outdent_ then outdent context (interaction_targets state)
    else indent context (interaction_targets state)
  in
  step state
    (match moves with
     | Some moves -> [ Reparent_blocks moves; Haptic Impact ]
     | None -> [ Haptic Impact ])

let toolbar_reorder context (state : outliner_state) up_ =
  match move context (interaction_targets state) up_ with
  | Some moves -> step state [ Reparent_blocks moves; Haptic Impact ]
  | None -> step state [ Haptic Impact ]

let choose_completion context (state : outliner_state) value =
  match (state.editing, state.autocomplete) with
  | Some editing, Some request
    when autocomplete_for editing.title editing.caret = Some request ->
    let context = if request.kind = Node && String_kit.trim request.query <> "" then
        let pages = context.search_nodes (String_kit.trim request.query) @ context.pages in
        let label_values = candidate_label_values (pages @ context.tags) in
        { context with pages; label_values; dup_labels = duplicated_of label_values }
      else context in
    if request.kind = Tag then
      match remove_tag_token editing with
      | Some editing ->
        step
          { state with editing = Some editing; autocomplete = None }
          [
            Assign_tag
              { tag_target_uuid = editing.uuid; value };
            Haptic Selection;
          ]
      | None -> step state []
    else
      (match complete context editing request.kind value with
       | Some editing ->
         let create =
           request.kind = Node && not (Ref_text.is_uuid value)
           && not
                (List.exists
                   (fun (candidate : outliner_candidate) ->
                     candidate.value = value)
                   context.pages)
           && not
                (List.exists
                   (fun (block : Model.block) -> block.uuid = value)
                   context.blocks)
         in
         step
           { state with editing = Some editing; autocomplete = None }
           (if create then [ Create_linked_page value; Haptic Selection ]
            else [ Haptic Selection ])
       | None -> step state [])
  | _ -> step state []

let staged_editing context (state : outliner_state) uuid fallback at_start =
  let expected, display =
    match find_block context uuid with
    | Some block -> (block.title, display_block_title context block)
    | None -> (fallback, fallback)
  in
  step
    {
      state with
      editing =
        Some
          {
            uuid;
            expected_title = expected;
            title = display;
            caret = (if at_start then 0 else utf16_length display);
          };
      selected = Sset.empty;
      autocomplete = None;
    }
    []

let rec take_while pred xs =
  match xs with
  | [] -> []
  | x :: rest -> if pred x then x :: take_while pred rest else []

let update context (state : outliner_state) message =
  let state =
    {
      state with
      zoomed =
        take_while
          (fun uuid -> Option.is_some (find_block context uuid))
          state.zoomed;
    }
  in
  match message with
  | Tap_block uuid ->
    if not (Sset.is_empty state.selected) then
      step { state with selected = toggle_member state.selected uuid } []
    else
      (match find_block context uuid with
       | Some block ->
         step
           {
             (start_editing context state block
                (utf16_length (display_block_title context block)))
             with
             selected = Sset.empty;
           }
           (commit_effect context state.editing)
       | None -> step state [])
  | Long_press_block uuid ->
    step
      {
        state with
        editing = None;
        selected = Sset.singleton uuid;
        autocomplete = None;
      }
      (commit_effect context state.editing @ [ Haptic Selection ])
  | Text_changed value ->
    (match state.editing with
     | Some editing ->
       step
         {
           state with
           editing =
             Some { editing with title = value.title; caret = value.caret };
           autocomplete = autocomplete_for value.title value.caret;
         }
         []
     | None -> step state [])
  | Caret_moved caret ->
    (match state.editing with
     | Some editing ->
       step
         {
           state with
           editing = Some { editing with caret };
           autocomplete = (match state.autocomplete with
             | None -> None
             | Some _ -> autocomplete_for editing.title caret);
         }
         []
     | None -> step state [])
  | Choose_autocomplete value -> choose_completion context state value
  | Return_pressed ->
    (match state.editing with
     | Some editing -> split_or_outdent context state editing
     | None -> step state [])
  | Return_pressed_with_text value ->
    (match state.editing with
     | Some editing ->
       split_or_outdent context state
         { editing with title = value.title; caret = value.caret }
     | None -> step state [])
  | Backspace_pressed value ->
    (match state.editing with
     | Some editing ->
       if value.selection_length = 0 && editing.caret = 0 then
         merge_backward context state editing
       else step state []
     | None -> step state [])
  | Backspace_pressed_with_text value ->
    (match state.editing with
     | Some editing ->
       if value.backspace_selection_length = 0 then
         merge_backward context state
           { editing with title = value.backspace_title; caret = 0 }
       else step state []
     | None -> step state [])
  | Toolbar Indent -> toolbar_move context state false
  | Toolbar Outdent -> toolbar_move context state true
  | Toolbar Move_up -> toolbar_reorder context state true
  | Toolbar Move_down -> toolbar_reorder context state false
  | Toolbar Delete ->
    let uuids = selected_uuids state in
    step
      { state with selected = Sset.empty; pending_deletion = uuids }
      [ Request_delete_confirmation uuids; Haptic Impact ]
  | Confirm_delete ->
    let uuids =
      if state.pending_deletion = [] then selected_uuids state
      else state.pending_deletion
    in
    if uuids = [] then step state []
    else
      step
        { state with selected = Sset.empty; pending_deletion = [] }
        [ Remove_blocks uuids ]
  | Toolbar Unselect ->
    step { state with selected = Sset.empty } [ Haptic Impact ]
  | Toolbar Task ->
    (match state.editing with
     | Some editing ->
       step state [ Cycle_task_status editing.uuid; Haptic Impact ]
     | None -> step state [])
  | Toolbar Hide_keyboard ->
    step
      { state with editing = None; autocomplete = None }
      (commit_effect context state.editing @ [ Haptic Impact ])
  | Save_editing -> step state (commit_effect context state.editing)
  | Cancel_editing ->
    step
      { state with editing = None; autocomplete = None }
      (commit_effect context state.editing)
  | Toolbar Tag_action -> toolbar_insert state "#" 0
  | Toolbar Page_reference -> toolbar_insert state "[[]]" 2
  | Toolbar Camera ->
    (match state.editing with
     | Some editing ->
       step state [ Take_photo editing.uuid; Haptic Impact ]
     | None -> step state [])
  | Toolbar Audio ->
    (match state.editing with
     | Some editing ->
       step state [ Record_audio editing.uuid; Haptic Impact ]
     | None -> step state [])
  | Toolbar Attachment ->
    (match state.editing with
     | Some editing ->
       step state [ Pick_attachment editing.uuid; Haptic Impact ]
     | None -> step state [])
  | Toolbar Copy ->
    let text =
      String.concat "\n"
        (List.filter_map
           (fun (block : Model.block) ->
             if Sset.mem block.uuid state.selected then Some block.title
             else None)
           context.blocks)
    in
    step { state with selected = Sset.empty }
      [ Copy_text text; Haptic Impact ]
  | Toolbar Copy_reference ->
    step
      { state with selected = Sset.empty }
      [ Copy_references (selected_uuids state); Haptic Impact ]
  | Toolbar Copy_url ->
    step
      { state with selected = Sset.empty }
      [ Copy_urls (selected_uuids state); Haptic Impact ]
  | Drop_blocks value ->
    (match drop context state.selected value.target_uuid value.placement with
     | Some moves ->
       step
         { state with selected = Sset.empty }
         [ Reparent_blocks moves; Haptic Impact ]
     | None -> step state [])
  | Set_task_status value ->
    step state [ Set_task_status_value value; Haptic Impact ]
  | Toggle_collapsed uuid ->
    step
      {
        state with
        collapsed = toggle_member state.collapsed uuid;
        editing = None;
        autocomplete = None;
      }
      (commit_effect context state.editing @ [ Haptic Impact ])
  | Zoom_in uuid ->
    if Option.is_some (find_block context uuid) then
      let state, effects = leave_interaction context state in
      let zoomed =
        match List.rev state.zoomed with
        | last :: _ when last = uuid -> state.zoomed
        | _ -> state.zoomed @ [ uuid ]
      in
      step { state with zoomed } (effects @ [ Haptic Selection ])
    else step state []
  | Zoom_out ->
    let state, effects = leave_interaction context state in
    step
      {
        state with
        zoomed = take_n (max 0 (List.length state.zoomed - 1)) state.zoomed;
      }
      (effects @ [ Haptic Selection ])
  | Add_root_block page_uuid ->
    let state, effects = leave_interaction context state in
    step state
      (effects @ [ Insert_root_block { page_uuid }; Haptic Impact ])
  | Operation_staged intent ->
    (match intent with
     | Ops.Split_block value ->
       staged_editing context state value.new_uuid value.after true
     | Ops.Insert_block value ->
       staged_editing context state value.uuid value.title false
     | Ops.Merge_backward value ->
       (match find_block context value.previous_uuid with
        | Some block -> staged_editing context state block.uuid block.title false
        | None -> step state [])
     | Ops.Save_title value ->
       (match state.editing with
        | Some editing ->
          if editing.uuid = value.uuid then
            step
              {
                state with
                editing =
                  Some { editing with expected_title = value.title };
              }
              []
          else step state []
        | None -> step state [])
     | _ -> step state [])
