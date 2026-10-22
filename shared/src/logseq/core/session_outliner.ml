module Types = Session_types
module Rpc = Rpc
module Model = Cache_model
module Ops = Pending_ops
module Outliner = Outliner_state

let sidebar_pages (session : Types.session) =
  (* While deferred, snapshots ship an empty sidebar so the scan stays
     off the launch path; the "loadSidebar" dispatch disarms this. *)
  if (Types.state session).sidebar_deferred then Types.empty_sidebar
  else
    match (Types.host session).graph_sidebar_pages with
    | Some load ->
      (match load () with Some sidebar -> sidebar | None -> Types.empty_sidebar)
    | None -> Types.empty_sidebar

let summary_candidate (page : Model.entity_summary) =
  { Outliner.label = page.title; value = page.uuid }

let outliner_context_with_blocks session sidebar blocks =
  let sidebar =
    match sidebar with
    | Some sidebar -> sidebar
    | None -> sidebar_pages session
  in
  let pages =
    List.map summary_candidate
      (sidebar.Graph_read.favorites @ sidebar.Graph_read.recent_pages)
  in
  let tags =
    match (Types.host session).Types.graph_tag_pages with
    | Some load ->
      List.map summary_candidate
        (match load () with Some pages -> pages | None -> [])
    | None -> []
  in
  let search_nodes query =
    let hits = match (Types.host session).graph_search_page, (Types.host session).graph_search with
      | Some search, _ -> fst (search ~offset:0 ~limit:12 query)
      | None, Some search -> search query
      | None, None -> [] in
    List.map (fun (hit : Search_index.indexed_search_hit) ->
      { Outliner.label = hit.title; value = hit.uuid }) hits
  in
  let is_block_reference uuid =
    match (Types.host session).graph_node_destination with
    | Some resolve ->
      (match resolve uuid with
       | Some (_, zoom) -> zoom
       | None -> List.exists (fun (block : Model.block) -> block.uuid = uuid) blocks)
    | None -> List.exists (fun (block : Model.block) -> block.uuid = uuid) blocks in
  Outliner.context ~search_nodes ~is_block_reference blocks pages tags

let sidebar_node_destination (session : Types.session) (node : Model.entity_summary) =
  match (Types.host session).graph_node_destination with
  | Some resolve -> Option.value ~default:(node, false) (resolve node.uuid)
  | None -> node, false

let base_outliner_context_live (session : Types.session) =
  let s = Types.state session in
  let h = Types.host session in
  let blocks =
    match (s.selected_sidebar_page, h.graph_page_blocks, h.graph_blocks) with
    | Some node, Some load, _ ->
      let page, _ = sidebar_node_destination session node in
      (match load page.Model.uuid with
       | Some blocks -> blocks
       | None -> [])
    | _, _, Some load ->
      (match load () with Some blocks -> blocks | None -> [])
    | _ -> Model.visible_blocks s.model
  in
  outliner_context_with_blocks session None blocks

let page_overlay (session : Types.session) page_id blocks =
  Rpc.page_blocks_with_optimistic_overlay
    (Types.state session).outliner_optimistic_blocks
    (Outliner.editing_uuid (Types.state session).outliner_state <> None)
    page_id blocks

let scope_selected_page (session : Types.session)
    (context : Outliner.outliner_context) =
  match (Types.state session).selected_sidebar_page with
  | Some node ->
    let page, _ = sidebar_node_destination session node in
    {
      context with
      Outliner.blocks = page_overlay session page.uuid context.blocks;
    }
  | None ->
    (* Journal launch reads are bounded. While editing, refreshes must keep
       the complete active page so insertions cannot push its editor out. *)
    (match Outliner.editing_uuid (Types.state session).outliner_state,
           (Types.host session).graph_page_blocks with
     | Some uuid, Some load ->
       let find blocks = List.find_opt (fun (block : Model.block) -> block.uuid = uuid) blocks in
       let source = match find context.Outliner.blocks with
         | Some block -> Some block
         | None -> Option.bind (Types.state session).outliner_optimistic_blocks find in
       (match Option.bind source (fun block ->
          Option.map (fun blocks -> block.Model.page_id, blocks) (load block.page_id)) with
        | Some (page, blocks) ->
          { context with Outliner.blocks = blocks @ List.filter
              (fun (block : Model.block) -> block.page_id <> page) context.blocks }
        | None -> context)
     | _ -> context)

let base_outliner_context_with_blocks session sidebar blocks =
  scope_selected_page session
    (outliner_context_with_blocks session sidebar blocks)

let base_outliner_context session =
  scope_selected_page session (base_outliner_context_live session)

let page_outliner_context (session : Types.session) uuid =
  match (Types.host session).graph_page_blocks with
  | Some load ->
    (match load uuid with
     | Some blocks -> Some (outliner_context_with_blocks session None blocks)
     | None -> None)
  | None -> None

let node_route_context session (route : Types.node_route) =
  let blocks =
    match (Types.host session).graph_page_blocks with
    | Some load ->
      (match load route.page.Model.uuid with
       | Some blocks -> blocks
       | None -> [])
    | None -> []
  in
  outliner_context_with_blocks session None
    (page_overlay session route.page.uuid blocks)

let active_node_route (session : Types.session) =
  let routes = (Types.state session).node_routes in
  match List.rev routes with
  | route :: _ -> Some route
  | [] -> None

let deferred_references session =
  (Types.host session).outliner_projection_limit <> None

let synchronize_reference_cache session =
  let state = Types.state session in
  let generation = (Option.map (fun config -> config.Api.graph_id) state.config,
    Types.projection_server_t session, state.outliner_revision) in
  if !(session.Types.reference_generation) <> Some generation then begin
    Hashtbl.clear session.reference_cache;
    session.reference_generation := Some generation
  end

let references_for_node session uuid =
  if deferred_references session then begin
    synchronize_reference_cache session;
    Option.value ~default:[] (Hashtbl.find_opt session.Types.reference_cache uuid)
  end else
    match (Types.host session).graph_node_references with
    | Some load -> Option.value ~default:[] (load uuid)
    | None -> []

let active_reference_uuid session =
  match active_node_route session with
  | Some route -> Some route.uuid
  | None -> Option.map (fun (page : Model.entity_summary) -> page.uuid)
      (Types.state session).selected_sidebar_page

let pending_reference_uuid session =
  if not (deferred_references session) then None
  else begin
    synchronize_reference_cache session;
    match active_reference_uuid session with
    | Some uuid when not (Hashtbl.mem session.Types.reference_cache uuid) -> Some uuid
    | _ -> None
  end

let load_page_references session uuid =
  synchronize_reference_cache session;
  if active_reference_uuid session = Some uuid
     && not (Hashtbl.mem session.Types.reference_cache uuid) then begin
    let blocks = match (Types.host session).graph_node_references with
      | Some load -> Option.value ~default:[] (load uuid)
      | None -> [] in
    Hashtbl.replace session.reference_cache uuid blocks
  end

let node_route_related_blocks session (route : Types.node_route) =
  if not route.is_tag then references_for_node session route.uuid
  else match (Types.host session).Types.graph_tag_objects with
  | Some load ->
    (match load route.uuid with
     | Some blocks -> blocks
     | None -> route.related_blocks)
  | None -> route.related_blocks

let node_route_linked_reference_blocks session (route : Types.node_route) =
  if route.is_tag then references_for_node session route.uuid else []

let page_for_visible_block (block : Model.block) =
  let title =
    match block.journal with
    | Some (title, _) when not (String_kit.is_blank title) -> Some title
    | _ -> None
  in
  let title =
    match title with
    | Some _ -> title
    | None ->
      (match
         List.find_opt
           (fun (page : Model.entity_summary) -> page.uuid = block.page_id)
           block.breadcrumbs
       with
       | Some page -> Some page.title
       | None -> Some block.title)
  in
  { Model.uuid = block.page_id; title = Option.value title ~default:"" }

let projected_node_destination (session : Types.session) uuid =
  let s = Types.state session in
  let h = Types.host session in
  let graph_blocks =
    match h.graph_blocks with
    | Some load -> (match load () with Some blocks -> blocks | None -> [])
    | None -> []
  in
  let selected_blocks =
    match (s.selected_sidebar_page, h.graph_page_blocks) with
    | Some node, Some load ->
      let page, _ = sidebar_node_destination session node in
      (match load page.Model.uuid with Some blocks -> blocks | None -> [])
    | _ -> []
  in
  let route_blocks =
    List.concat_map
      (fun route -> (node_route_context session route).Outliner.blocks)
      s.node_routes
  in
  let blocks =
    graph_blocks @ selected_blocks @ route_blocks @ s.related_blocks
    @ Option.value s.outliner_optimistic_blocks ~default:[]
  in
  let candidate =
    match
      List.find_opt (fun block -> block.Model.uuid = uuid) blocks
    with
    | Some block -> Some (block, true)
    | None ->
      (match
         List.find_opt (fun block -> block.Model.page_id = uuid) blocks
       with
       | Some block -> Some (block, false)
       | None -> None)
  in
  match candidate with
  | Some (block, zoom) when block.Model.page_id <> "" ->
    Some (page_for_visible_block block, zoom)
  | _ -> None

let with_extra_blocks (context : Outliner.outliner_context) extra =
  let present = Hashtbl.create (List.length context.blocks) in
  List.iter (fun (block : Model.block) -> Hashtbl.replace present block.uuid ()) context.blocks;
  {
    context with
    Outliner.blocks =
      context.blocks
      @ List.filter
          (fun (block : Model.block) ->
            if Hashtbl.mem present block.uuid then false
            else begin Hashtbl.add present block.uuid (); true end)
          extra;
  }

let outliner_context (session : Types.session) =
  match active_node_route session with
  | Some route ->
    with_extra_blocks
      (node_route_context session route)
      (node_route_related_blocks session route
       @ node_route_linked_reference_blocks session route)
  | None ->
    with_extra_blocks
      (base_outliner_context session)
      (Types.state session).related_blocks

let project_outliner_operations (context : Outliner.outliner_context)
    operations =
  {
    context with
    Outliner.blocks =
      List.fold_left
        (fun blocks (operation : Ops.pending_operation) ->
          Rpc.project_outliner_intent blocks operation.intent)
        context.blocks operations;
  }

let selected_graph (session : Types.session) =
  match (Types.state session).config with
  | Some config ->
    List.find_opt
      (fun (graph : Api.api_graph) -> graph.id = config.Api.graph_id)
      (Types.state session).available_graphs
  | None -> None

let selected_graph_is_encrypted session =
  match selected_graph session with
  | Some graph -> graph.Api.e2ee
  | None -> false

let selected_graph_is_unlocked (session : Types.session) =
  match ((Types.state session).config, selected_graph session) with
  | config, Some graph ->
    if not graph.Api.e2ee then true
    else
      (match (config, (Types.host session).graph_unlocked) with
       | Some config, Some unlocked -> unlocked config.Api.graph_id
       | _ -> false)
  | _ -> false

let selected_page_is_tag (session : Types.session) =
  match
    ( (Types.state session).selected_sidebar_page
    , (Types.host session).graph_node_is_tag )
  with
  | Some page, Some check -> check page.Model.uuid
  | _ -> false

let selected_page_is_property (session : Types.session) =
  match
    ( (Types.state session).selected_sidebar_page
    , (Types.host session).graph_node_is_property )
  with
  | Some page, Some check -> check page.Model.uuid
  | _ -> false

let snapshot_related_blocks (session : Types.session) =
  if selected_page_is_tag session then
    match
      ( (Types.state session).selected_sidebar_page
      , (Types.host session).graph_tag_objects )
    with
    | Some page, Some load ->
      (match load page.Model.uuid with
       | Some blocks -> blocks
       | None -> [])
    | _ -> []
  else if deferred_references session then
    (match (Types.state session).selected_sidebar_page with
     | Some page -> references_for_node session page.Model.uuid
     | None -> [])
  else (Types.state session).related_blocks

let snapshot_linked_reference_blocks (session : Types.session) =
  if selected_page_is_tag session then
    match (Types.state session).selected_sidebar_page with
    | Some page -> references_for_node session page.Model.uuid
    | None -> []
  else []

let has_pending_operations (session : Types.session) =
  let s = Types.state session in
  s.semantic_queue <> []
  || s.semantic_active <> None
  || s.pending_sync <> None
  || Model.pending_blocks s.model <> []

let collapsed_graph_key (session : Types.session) =
  match (Types.state session).config with
  | Some config -> config.Api.graph_id
  | None -> ""

let saved_collapsed_nodes (session : Types.session) =
  let key = collapsed_graph_key session in
  match Hashtbl.find_opt session.collapsed_nodes key with
  | Some collapsed -> collapsed
  | None ->
    let collapsed =
      match (Types.host session).load_collapsed_nodes with
      | Some load -> Outliner.Sset.of_list (load key)
      | None -> Outliner.Sset.empty
    in
    Hashtbl.replace session.collapsed_nodes key collapsed;
    collapsed

(* Collapse choices belong to the graph, including retained navigation views. *)
let restore_collapsed_nodes (session : Types.session) =
  let collapsed = saved_collapsed_nodes session in
  let restore (state : Outliner.outliner_state) = { state with collapsed } in
  let current = Types.state session in
  session.state := { current with
    outliner_state = restore current.outliner_state;
    node_base_state = Option.map restore current.node_base_state;
    node_routes = List.map (fun (route : Types.node_route) ->
      { route with state = restore route.state }) current.node_routes }

let persist_collapsed_nodes (session : Types.session) =
  let key = collapsed_graph_key session in
  let collapsed = (Types.state session).outliner_state.collapsed in
  Hashtbl.replace session.collapsed_nodes key collapsed;
  Option.iter (fun save -> save key (Outliner.Sset.elements collapsed))
    (Types.host session).save_collapsed_nodes;
  restore_collapsed_nodes session

let reset_outliner (session : Types.session) =
  session.state :=
    {
      !(session.state) with
      outliner_state = { Outliner.empty with collapsed = saved_collapsed_nodes session };
      outliner_optimistic_blocks = None;
      outliner_commands = [];
      outliner_revision = (Types.state session).outliner_revision + 1;
    }

let clear_node_navigation (session : Types.session) =
  (match (Types.state session).node_base_state with
   | Some base ->
     session.state := { !(session.state) with outliner_state = base }
   | None -> ());
  session.state :=
    { !(session.state) with node_routes = []; node_base_state = None }

let persist_active_node_state (session : Types.session) =
  let s = Types.state session in
  let routes = s.node_routes in
  match List.length routes with
  | 0 -> ()
  | count ->
    let index = count - 1 in
    session.state :=
      {
        !(session.state) with
        node_routes =
          List.mapi
            (fun i (route : Types.node_route) ->
              if i = index then { route with state = s.outliner_state }
              else route)
            routes;
      }

let initial_node_state session (route : Types.node_route) =
  let initial = { Outliner.empty with collapsed = saved_collapsed_nodes session } in
  if route.zoom_to_block then
    fst
      (Outliner.update
         (node_route_context session route)
         initial
         (Outliner.Zoom_in route.uuid))
  else initial

let push_node_route (session : Types.session) (route : Types.node_route) =
  persist_active_node_state session;
  if (Types.state session).node_routes = [] then
    session.state :=
      {
        !(session.state) with
        node_base_state = Some (Types.state session).outliner_state;
      };
  let current = initial_node_state session route in
  session.state :=
    {
      !(session.state) with
      node_routes = (Types.state session).node_routes @ [ { route with state = current } ];
      outliner_state = current;
      outliner_commands = [];
      outliner_revision = (Types.state session).outliner_revision + 1;
    }

let pop_node_route (session : Types.session) =
  persist_active_node_state session;
  let routes = (Types.state session).node_routes in
  if routes <> [] then begin
    session.state :=
      {
        !(session.state) with
        node_routes = Rpc.sub_list routes 0 (List.length routes - 1);
      };
    (match active_node_route session with
     | Some route ->
       session.state := { !(session.state) with outliner_state = route.state }
     | None ->
       session.state :=
         {
           !(session.state) with
           outliner_state =
             (match (Types.state session).node_base_state with
              | Some base -> base
              | None -> Outliner.empty);
           node_base_state = None;
         });
    session.state :=
      {
        !(session.state) with
        outliner_commands = [];
        outliner_revision = (Types.state session).outliner_revision + 1;
      }
  end

let aggregate_return_context session payload
    (message : Outliner.outliner_message) =
  let s = Types.state session in
  let return =
    match message with
    | Outliner.Return_pressed -> true
    | Outliner.Return_pressed_with_text _ -> true
    | _ -> false
  in
  if s.selected_sidebar_page = None && s.node_routes = [] && return then
    match Rpc.outliner_structure_source payload with
    | Some source ->
      (match (Types.host session).graph_node_destination with
       | Some destination ->
         (match destination source with
          | Some (page, _) ->
            (match page_outliner_context session page.Model.uuid with
             | Some context -> Some (context, page.uuid)
             | None -> None)
          | None -> None)
       | None -> None)
    | None -> None
  else None

type outliner_patch_plan =
  | Patch_blocks of string list
  | Structural_diff

let event_patch_plan (message : Outliner.outliner_message) operations =
  match message with
  | Outliner.Toggle_collapsed _ -> Structural_diff
  | _ ->
    (match operations with
     | [ operation ] ->
       (match operation.Ops.intent with
        | Ops.Save_title title -> Patch_blocks [ title.uuid ]
        | Ops.Set_property property -> Patch_blocks [ property.uuid ]
        | _ -> Structural_diff)
     | [] ->
       (match message with
        | Outliner.Tap_block _ -> Patch_blocks []
        | Outliner.Long_press_block _ -> Patch_blocks []
        | Outliner.Text_changed _ -> Patch_blocks []
        | Outliner.Caret_moved _ -> Patch_blocks []
        | Outliner.Choose_autocomplete _ -> Patch_blocks []
        | Outliner.Save_editing -> Patch_blocks []
        | Outliner.Cancel_editing -> Patch_blocks []
        | Outliner.Toolbar _ -> Patch_blocks []
        | _ -> Structural_diff)
     | _ -> Structural_diff)

let refresh_reference_metadata session aggregate projected operations =
  if
    List.exists
      (fun (operation : Ops.pending_operation) ->
        match operation.intent with
        | Ops.Save_title _ -> true
        | Ops.Add_tag _ -> true
        | _ -> false)
      operations
  then
    let live =
      match aggregate with
      | Some uuid ->
        (match page_outliner_context session uuid with
         | Some context -> context
         | None -> outliner_context session)
      | None -> outliner_context session
    in
    let by_id =
      List.map (fun (b : Model.block) -> (b.uuid, b)) live.Outliner.blocks
    in
    {
      projected with
      Outliner.blocks =
        List.map
          (fun (block : Model.block) ->
            match List.assoc_opt block.uuid by_id with
            | Some current ->
              {
                block with
                references = current.references;
                tags = current.tags;
              }
            | None -> block)
          projected.Outliner.blocks;
    }
  else projected
