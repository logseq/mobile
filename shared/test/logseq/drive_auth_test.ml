(* Sign-in and sign-out. Scripts live in logseq/drive/auth/. *)

let handle (host : Drive_host.host) _model = function
  | Model.SignInEffect (id, _) ->
    Some
      (if host.Drive_host.fail_sign_in then
         [ Model.DequeueEffect id
         ; Model.ResolveEffect (id, true, "{\"__type\":\"NotAuthorizedException\"}") ]
       else
         [ Model.DequeueEffect id
         ; Model.ApplyLocalGraphIds (Drive_host.graph_ids host)
         ; Model.ApplyCoreSnapshot (Drive_host.catalog_projection host.graphs)
         ; Model.ResolveEffect (id, true, "{\"signedIn\":true}") ])
  | Model.SignOutEffect id ->
    Some (Model.DequeueEffect id :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/auth"
