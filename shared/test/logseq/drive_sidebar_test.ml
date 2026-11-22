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
