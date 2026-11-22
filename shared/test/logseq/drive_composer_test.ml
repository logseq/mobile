(* Composer capture and tags. Scripts live in logseq/drive/composer/. *)

let snapshot (host : Drive_host.host) model =
  Drive_host.current_graph_projection host model ~extra:(fun projection ->
      projection)

let handle (host : Drive_host.host) model = function
  | Model.SendCaptureEffect (id, title) ->
    Drive_host.append_capture host id title ();
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | Model.SendTaskEffect (id, title, status) ->
    Drive_host.append_capture host id title ~status ();
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | Model.SendTaggedCaptureEffect (id, submission) ->
    Drive_host.append_capture host id submission.Model.capture_text
      ?status:submission.capture_status ~tags:submission.capture_tags ();
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | Model.LoadComposerTagsEffect (id, _) ->
    Some
      (Model.DequeueEffect id
      :: Model.ApplyCoreSnapshot
           {
             (Drive_host.catalog_projection host.graphs) with
             Model.selected_graph_id = model.Model.selected_graph_id;
             tag_choices_update = Some Drive_host.tag_choices;
           }
      :: Drive_host.resolved id)
  | Model.LoadPropertyValuesEffect (id, key, _) ->
    Some
      (Model.DequeueEffect id
      :: Model.ReceivePropertyValues
           ( key
           , Yojson.Basic.to_string
               (`Assoc
                  [
                    ("attr", `String "block/tags");
                    ("valuesDeferred", `Bool false);
                    ( "filterValues"
                    , `List
                        (List.map
                           (fun (tag : Model.sidebar_page) ->
                             `Assoc
                               [
                                 ("title", `String tag.title);
                                 ("match", `List [ `String tag.uuid ]);
                               ])
                           Drive_host.tag_choices) );
                  ]) )
      :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/composer"
