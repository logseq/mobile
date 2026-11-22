(* Sidebar pages, favorites, and page deletion. Scripts live in
   logseq/drive/sidebar/. *)

let snapshot (host : Drive_host.host) model =
  Drive_host.current_graph_projection host model ~extra:(fun projection ->
      projection)

let handle (host : Drive_host.host) model = function
  | Model.SetPageFavoriteEffect (id, uuid, favored) ->
    host.Drive_host.favorites <-
      (if favored then
         host.favorites
         @ [ { Model.uuid; title = Drive_host.page_title host uuid uuid } ]
       else
         List.filter
           (fun (page : Model.sidebar_page) -> page.uuid <> uuid)
           host.favorites);
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | Model.SelectSidebarPageEffect (id, uuid) ->
    let page = Drive_host.remember_page host uuid in
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             {
               projection with
               Model.sidebar =
                 {
                   (Drive_host.host_sidebar host) with
                   selected_page = Some page;
                   linked_reference_rows = host.rows;
                 };
             })
      :: Drive_host.resolved id)
  | Model.ClearSelectedPageEffect id ->
    host.selected_page <- None;
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | Model.NodePropertyEffect (id, _key, payload) ->
    let fields = Drive_host.json_fields payload in
    let action = Drive_host.json_string fields "action" in
    let attr = Drive_host.json_string fields "attr" in
    let value = Drive_host.json_string fields "value" in
    (match (action, attr, value) with
    | Some "add", Some attr, _ ->
      if not (List.mem attr host.Drive_host.schema_attrs) then
        host.schema_attrs <- host.schema_attrs @ [ attr ]
    | Some "remove", Some attr, _ ->
      host.schema_attrs <- List.filter (( <> ) attr) host.schema_attrs
    | Some "setTags", _, _ -> host.page_tags <- true
    | Some "setCodeLanguage", _, Some language ->
      (match Drive_host.json_string fields "blockUuid" with
      | Some uuid ->
        Drive_host.map_row host uuid (fun row ->
            {
              row with
              Model.markup_json =
                Yojson.Basic.to_string
                  (`List [ `Assoc [ ("style", `String language) ] ]);
            })
      | None -> ())
    | Some "removeTag", _, _ ->
      (match Drive_host.json_string fields "blockUuid" with
      | Some uuid ->
        Drive_host.map_row host uuid (fun row -> { row with Model.tags = [] })
      | None -> ())
    | _, Some "done", Some "true" -> host.property_done <- true
    | _, Some "done", Some "false" -> host.property_done <- false
    | _, Some "block/title", Some title when title <> "" ->
      (match host.selected_page with
      | Some page -> Drive_host.rename_page host page.uuid title
      | None -> ())
    | _ -> ());
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | Model.PresentPageShareEffect (id, _, _) ->
    let title =
      match host.selected_page with
      | Some page -> page.title
      | None -> "page"
    in
    host.runtime_log <-
      {
        Model.id = "share-" ^ string_of_int id;
        level = "info";
        source = "drive";
        timestamp = "Now";
        message = "Shared " ^ title;
      }
      :: host.runtime_log;
    Some (Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.DeletePageEffect (id, uuid) ->
    let drop pages =
      List.filter (fun (page : Model.sidebar_page) -> page.uuid <> uuid) pages
    in
    host.favorites <- drop host.favorites;
    host.recents <- drop host.recents;
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/sidebar"
