type retained_row =
  { render_key : string
  ; value : Model.outline_row
  ; is_editing : bool
  ; editing_title : string
  ; editing_caret : int
  }

let make_retained_outline_row (current : Model.logseq_model)
    (row : Model.outline_row) =
  match current.outliner_editing with
  | Some editing ->
    if editing.editing_uuid = row.row_uuid then
      {
        render_key = "active-outliner-editor";
        value = row;
        is_editing = true;
        editing_title = editing.editing_title;
        editing_caret = editing.caret_utf16_offset;
      }
    else
      {
        render_key = row.row_uuid;
        value = row;
        is_editing = false;
        editing_title = "";
        editing_caret = 0;
      }
  | None ->
    {
      render_key = row.row_uuid;
      value = row;
      is_editing = false;
      editing_title = "";
      editing_caret = 0;
    }

let retained_outliner_rows (current : Model.logseq_model) =
  List.map (fun row -> make_retained_outline_row current row)
    current.outliner_rows

let first_journal_section_visible_ (current : Model.logseq_model) =
  View_base.journal_root_visible_ current
  && current.selected_page = None
  && current.outliner_section_markers <> []
  && (List.hd current.outliner_section_markers).start_index = 0

let retained_row_value (retained : retained_row) = retained.value
let retained_row_identifier (retained : retained_row) = retained.render_key
let retained_row_editing_ (retained : retained_row) = retained.is_editing
let retained_row_editing_title (retained : retained_row) =
  retained.editing_title

let retained_row_editing_caret (retained : retained_row) =
  retained.editing_caret

(* Only the native-visible window owns UI scopes and protocol nodes. The
   lightweight collection metadata keeps the entire outline scrollable. *)
let windowed_keyed ?scroll_target ?first_section ?section_titles ?reset_key
    ?(identifier = "outliner.window") ?(item_extent = 32)
    ?(on_visible_range = fun _ _ -> ()) ?(on_window = fun _ -> ())
    ?(on_prefetch = fun _ -> ()) ?(is_pinned = fun _ -> false) ~source ~key ~cmp ~mount : Lui_elements.t =
 fun context parent ->
  if not (List.mem (Lui_ui.host context) [Lui_protocol.SwiftUIHost; Lui_protocol.KotlinHost]) then
    Lui_elements.keyed ~source ~key ~cmp ~mount context parent
  else
    let own signal = Signal.own_signal context.Lui_ui.ui_scope signal in
    let items = own (Signal.map Array.of_list source) in
    let range = Signal.state context.ui_scheduler (0, 32) in
    let pinned = own (Signal.map (fun items ->
      match Array.find_index is_pinned items with Some index -> index | None -> -1) items) in
    Option.iter (fun reset ->
      let previous_key = ref (Signal.sample reset) in
      ignore (Signal.own context.ui_scope
        (Signal.observe reset (fun key ->
          if key <> !previous_key then begin
            previous_key := key;
            Signal.set range (0, 32)
          end)))) reset_key;
    let target = match scroll_target with Some source -> source
      | None -> Signal.constant context.ui_scheduler None in
    let request = own (Signal.map2 (fun items target ->
      match target with
      | None -> None
      | Some uuid -> Option.map (fun index -> (uuid, index))
          (Array.find_index (fun item -> key item = uuid) items)) items target) in
    let applied_target = ref None in
    ignore (Signal.own context.ui_scope (Signal.observe request (function
      | Some (uuid, index) when !applied_target <> Some uuid ->
        applied_target := Some uuid;
        Signal.set range (max 0 (index - 8), 32)
      | _ -> ())));
    let window = own (Signal.map2 (fun items (start, length) ->
      let count = Array.length items in
      let start = min start (max 0 (count - length)) in
      (items, start, min length (count - start))) items (Signal.value range)) in
    let first_section = match first_section with
      | Some source -> source | None -> Signal.constant context.ui_scheduler 0 in
    let layout = own (Signal.map2 (fun first pinned -> first, pinned) first_section pinned) in
    let metadata_base = own (Signal.map2 (fun (items, start, length) (first_count, pinned_index) ->
      ["data-virtual-count", string_of_int (Array.length items);
       "data-virtual-start", string_of_int start;
       "data-virtual-length", string_of_int length;
       "data-item-extent", string_of_int item_extent;
       "data-first-section-count", string_of_int first_count;
       "data-first-section-inset", "136";
       "data-pinned-index", string_of_int pinned_index]) window layout) in
    let section_titles = match section_titles with
      | Some source -> source | None -> Signal.constant context.ui_scheduler [] in
    let metadata_base = own (Signal.map2 (fun metadata titles ->
      List.rev_append (List.rev_map (fun (index, title) ->
        ("data-section-title-" ^ string_of_int index, title)) titles) metadata)
      metadata_base section_titles) in
    let metadata = own (Signal.map2 (fun metadata request ->
      match request with None -> metadata | Some (uuid, index) ->
        ("data-scroll-key", uuid) :: ("data-scroll-index", string_of_int index) :: metadata)
      metadata_base request) in
    let visible = own (Signal.map (fun (items, start, length) ->
      let visible = Array.sub items start length |> Array.to_list in
      if Lui_ui.host context <> Lui_protocol.KotlinHost then visible
      else match Array.find_index is_pinned items with
      | Some index when index < start || index >= start + length -> visible @ [items.(index)]
      | _ -> visible) window) in
    ignore (Signal.own context.ui_scope (Signal.observe visible on_window));
    let adjacent = own (Signal.map (fun (items, start, length) ->
      let before = max 0 (start - 16) in
      let after = start + length in
      let preceding = Array.sub items before (start - before) |> Array.to_list in
      let following = Array.sub items after (min 16 (Array.length items - after)) |> Array.to_list in
      preceding @ following) window) in
    ignore (Signal.own context.ui_scope (Signal.observe adjacent on_prefetch));
    Lui_elements.if_ ~test:(own (Signal.map (fun items -> Array.length items > 0) items))
    (Lui_elements.list ~accessibility_identifier:identifier
      ~data_attrs_signal:metadata ~track_visible_range:true
      ~on_visible_range:(function
        | Lui_protocol.VisibleRange (_, first, last) ->
          on_visible_range first last;
          let items, start, length = Signal.sample window in
          let count = Array.length items in
          if count > 0 && first >= 0 && last >= first then begin
            let first = min first (count - 1) in
            let last = min last (count - 1) in
            if (first < start + 2 && start > 0)
               || (last >= start + length - 2 && start + length < count) then
              let next_start = min (max 0 (first - max 0 ((32 - (last - first + 1)) / 2))) (max 0 (count - 32)) in
              if next_start <> start || length < min 32 count then
                Signal.set range (next_start, 32)
          end
        | _ -> ())
      [Lui_elements.keyed ~source:visible ~key ~cmp ~mount]) context parent

type reference_entry =
  | Reference_heading of string * string
  | Empty_tag
  | Reference_row of string * Model.outline_row

let reference_entries (current : Model.logseq_model) =
  if not (View_base.page_content_ready_ current) then []
  else
    let add_section visible key title rows acc =
      if not visible then acc
      else
        let acc = Reference_heading (key, title) :: acc in
        let acc = if key = "tagged" && rows = [] then Empty_tag :: acc else acc in
        List.fold_left (fun acc row -> Reference_row (key, row) :: acc) acc rows
    in
    []
    |> add_section (View_base.node_related_section_visible_ current)
         "related" "Linked references" (View_base.active_node_related_rows current)
    |> add_section (View_base.node_tag_section_visible_ current)
         "tagged" "Tagged nodes" (View_base.active_node_related_rows current)
    |> add_section (View_base.node_linked_reference_section_visible_ current)
         "linked" "Linked references" (View_base.active_node_linked_reference_rows current)
    |> List.rev

let reference_entry_identifier = function
  | Reference_heading (key, _) -> key ^ ".heading"
  | Empty_tag -> "tagged.empty"
  | Reference_row (key, row) -> key ^ "." ^ row.Model.row_uuid

let reference_entry_row = function
  | Reference_row (_, row) -> row
  | _ -> invalid_arg "reference_entry_row requires a block entry"


type page_entry = Outline_entry of retained_row | Reference_entry of reference_entry

let page_entries rows current =
  List.rev_append (List.rev_map (fun row -> Outline_entry row) rows)
    (List.map (fun row -> Reference_entry row) (reference_entries current))

let page_entry_identifier = function
  | Outline_entry row -> "outline." ^ retained_row_identifier row
  | Reference_entry row -> "reference." ^ reference_entry_identifier row

let page_entry_outline = function
  | Outline_entry row -> row
  | _ -> invalid_arg "page_entry_outline requires an outline entry"

let page_entry_reference = function
  | Reference_entry row -> row
  | _ -> invalid_arg "page_entry_reference requires a reference entry"

let first_journal_section_count current =
  if first_journal_section_visible_ current then
    (List.hd current.Model.outliner_section_markers).end_index
  else 0

let unloaded_entry_id = function
  | Outline_entry row when not row.value.Model.row_loaded -> Some row.value.row_uuid
  | Reference_entry (Reference_row (_, row)) when not row.Model.row_loaded -> Some row.row_uuid
  | _ -> None

let page_entry_ready = function
  | Outline_entry row -> row.value.Model.row_loaded || row.value.row_title <> "" || row.is_editing
  | Reference_entry (Reference_row (_, row)) -> row.Model.row_loaded || row.row_title <> ""
  | _ -> true

let page_entry_editor_ = function
  | Outline_entry row -> row.is_editing
  | _ -> false
