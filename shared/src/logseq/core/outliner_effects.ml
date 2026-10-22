module State = Outliner_state
module Model = Cache_model
module Ops = Pending_ops
module Order = Fractional_order

type outliner_platform_command =
  | Platform_haptic of State.outliner_haptic
  | Focus_block of string
  | Confirm_delete of string list
  | Set_clipboard_text of string
  | Set_clipboard_references of string list
  | Set_clipboard_urls of string list
  | Platform_pick_attachment of string
  | Platform_take_photo of string
  | Platform_record_audio of string

type outliner_effects =
  { operations : Ops.pending_operation list
  ; platform : outliner_platform_command list
  }

let result operations platform = { operations; platform }

let find_block context uuid = State.find_block context uuid

let sorted_siblings (context : State.outliner_context) parent =
  List.sort
    (fun (left : Model.block) (right : Model.block) ->
      match (left.order, right.order) with
      | Some a, Some b ->
        if a <> b then compare a b else compare left.uuid right.uuid
      | Some _, None -> -1
      | None, Some _ -> 1
      | _ -> compare left.uuid right.uuid)
    (List.filter
       (fun (block : Model.block) -> block.parent_id = parent)
       context.blocks)

let next_order context (block : Model.block) =
  let siblings = sorted_siblings context block.parent_id in
  match State.index_of_uuid block.uuid siblings with
  | Some index ->
    let rec find rest =
      match rest with
      | [] -> None
      | (candidate : Model.block) :: remaining ->
        (match (block.order, candidate.order) with
         | Some lower, Some upper ->
           if compare upper lower > 0 then Some upper else find remaining
         | _ -> find remaining)
    in
    let rec drop n xs =
      if n <= 0 then xs
      else match xs with [] -> [] | _ :: rest -> drop (n - 1) rest
    in
    find (drop (index + 1) siblings)
  | None -> None

let operation base_t fresh_uuid intent =
  {
    Ops.operation_id = fresh_uuid ();
    base_t;
    state = Ops.Queued;
    intent;
  }

let status_reference (status : Model.status) =
  match status.ident with
  | Some ident -> Ops.Ref_ident ident
  | None -> Ops.Ref_uuid status.uuid

let next_status_value (block : Model.block) =
  match block.status with
  | Some { Model.ident = Some "logseq.property/status.todo"; _ } ->
    Some (Ops.Ref_ident "logseq.property/status.doing")
  | Some { Model.ident = Some "logseq.property/status.doing"; _ } ->
    Some (Ops.Ref_ident "logseq.property/status.done")
  | Some { Model.ident = Some "logseq.property/status.done"; _ } -> None
  | _ -> Some (Ops.Ref_ident "logseq.property/status.todo")

let append_result left right =
  result (left.operations @ right.operations) (left.platform @ right.platform)

let command base_t now fresh_uuid context cmd =
  let ( let* ) = Result.bind in
  match cmd with
  | State.Haptic haptic -> Ok (result [] [ Platform_haptic haptic ])
  | State.Commit_title value ->
    Ok (result [ operation base_t fresh_uuid (Ops.Save_title value) ] [])
  | State.Split_at value ->
    (match find_block context value.State.split_uuid with
     | Some block ->
       let* new_order =
         Order.between block.order (next_order context block)
       in
       let operation_id = fresh_uuid () in
       let new_uuid = fresh_uuid () in
       let intent =
         Ops.Split_block
           {
             uuid = value.split_uuid;
             expected_title = value.split_expected_title;
             before = value.before;
             after = value.after;
             new_uuid;
             new_order;
             created_at = now ();
           }
       in
       Ok
         (result
            [
              {
                Ops.operation_id;
                base_t;
                state = Ops.Queued;
                intent;
              };
            ]
            [ Focus_block new_uuid ])
     | None -> Error "split source no longer exists")
  | State.Merge_into_previous value ->
    Ok
      (result
         [
           operation base_t fresh_uuid
             (Ops.Merge_backward
                {
                  uuid = value.State.merge_uuid;
                  expected_title = value.merge_expected_title;
                  title = value.merge_title;
                  previous_uuid = value.previous_uuid;
                  expected_previous_title = value.expected_previous_title;
                  merged_title = None;
                });
         ]
         [ Focus_block value.previous_uuid ])
  | State.Reparent_blocks moves ->
    if moves = [] then Error "move batch must not be empty"
    else
      Ok (result [ operation base_t fresh_uuid (Ops.Move_blocks { moves }) ] [])
  | State.Request_delete_confirmation uuids ->
    Ok (result [] [ Confirm_delete uuids ])
  | State.Remove_blocks uuids ->
    Ok
      (result
         (if uuids = [] then []
          else
            [
              operation base_t fresh_uuid (Ops.Delete_blocks { uuids });
            ])
         [])
  | State.Cycle_task_status uuid ->
    (match find_block context uuid with
     | Some block ->
       Ok
         (result
            [
              operation base_t fresh_uuid
                (Ops.Set_property
                   {
                     uuid;
                     attr = "logseq.property/status";
                     expected =
                       (match block.Model.status with
                        | Some status -> Some (status_reference status)
                        | None -> None);
                     value = next_status_value block;
                   });
            ]
            [])
     | None -> Error "task block no longer exists")
  | State.Set_task_status_value value ->
    (match find_block context value.State.status_uuid with
     | Some block ->
       Ok
         (result
            [
              operation base_t fresh_uuid
                (Ops.Set_property
                   {
                     uuid = value.status_uuid;
                     attr = "logseq.property/status";
                     expected =
                       (match block.Model.status with
                        | Some status -> Some (status_reference status)
                        | None -> None);
                     value = Some value.status;
                   });
            ]
            [])
     | None -> Error "task block no longer exists")
  | State.Set_task_priority_value value ->
    (match find_block context value.State.priority_uuid with
     | Some block ->
       Ok (result [operation base_t fresh_uuid (Ops.Set_property {
         uuid = value.priority_uuid; attr = "logseq.property/priority";
         expected = Option.map status_reference block.Model.priority;
         value = value.priority;
       })] [])
     | None -> Error "task block no longer exists")
  | State.Create_linked_page title ->
    let title = String_kit.trim title in
    if title = "" then Error "page title must not be empty"
    else
      let uuid = fresh_uuid () in
      Ok
        (result
           [
             operation base_t fresh_uuid
               (Ops.Create_page
                  { uuid; title; created_at = now () });
           ]
           [])
  | State.Assign_tag value ->
    if Option.is_some (find_block context value.State.tag_target_uuid) then
      match
        List.find_opt
          (fun (candidate : State.outliner_candidate) ->
            candidate.value = value.value)
          context.tags
      with
      | Some candidate ->
        Ok
          (result
             [
               operation base_t fresh_uuid
                 (Ops.Add_tag
                    {
                      uuid = value.tag_target_uuid;
                      tag_uuid = candidate.value;
                    });
             ]
             [])
      | None ->
        let title = String_kit.trim value.value in
        if title = "" then Error "tag title must not be empty"
        else
          let tag_uuid = fresh_uuid () in
          let create =
            operation base_t fresh_uuid
              (Ops.Create_tag
                 { uuid = tag_uuid; title; created_at = now () })
          in
          let add =
            operation base_t fresh_uuid
              (Ops.Add_tag
                 { uuid = value.tag_target_uuid; tag_uuid })
          in
          Ok (result [ create; add ] [])
    else Error "tag target block no longer exists"
  | State.Insert_root_block value ->
    let lower =
      match List.rev (sorted_siblings context (Some value.State.page_uuid)) with
      | last :: _ -> last.order
      | [] -> None
    in
    let* position = Order.between lower None in
    let operation_id = fresh_uuid () in
    let uuid = fresh_uuid () in
    let intent =
      Ops.Insert_block
        {
          uuid;
          title = "";
          page_uuid = value.page_uuid;
          parent_uuid = value.page_uuid;
          order = position;
          created_at = now ();
        }
    in
    Ok
      (result
         [ { Ops.operation_id; base_t; state = Ops.Queued; intent } ]
         [ Focus_block uuid ])
  | State.Pick_attachment uuid ->
    Ok (result [] [ Platform_pick_attachment uuid ])
  | State.Take_photo uuid -> Ok (result [] [ Platform_take_photo uuid ])
  | State.Record_audio uuid -> Ok (result [] [ Platform_record_audio uuid ])
  | State.Copy_text text -> Ok (result [] [ Set_clipboard_text text ])
  | State.Copy_references uuids ->
    Ok (result [] [ Set_clipboard_references uuids ])
  | State.Copy_urls uuids -> Ok (result [] [ Set_clipboard_urls uuids ])

let interpret base_t now fresh_uuid context commands =
  let rec loop index operations platform =
    if index = List.length commands then Ok (result operations platform)
    else
      match
        command base_t now fresh_uuid context (List.nth commands index)
      with
      | Ok next ->
        loop (index + 1) (operations @ next.operations)
          (platform @ next.platform)
      | Error _ as error -> error
  in
  loop 0 [] []
