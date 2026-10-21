(* Temporary repro: drive the sign-in resolve path headlessly to see if
   Signal.stabilize loops on the post-sign-in view. *)

let ios_profile () =
  Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost

let graphs =
  [
    { Model.id = "g1"; name = "alpha"; is_encrypted = false; is_ready = true; role = None };
    { Model.id = "g2"; name = "beta"; is_encrypted = true; is_ready = true; role = None };
  ]

let sign_in_resolve () =
  let session = Drive_scenario_test.mount ~profile:(ios_profile ()) () in
  let app = session.Drive.Session.app in
  ignore (Lui_app.send app (Model.ApplyAuthentication ("signedOut", None)));
  ignore (Lui_app.flush app);
  ignore (Lui_app.send app Model.SignIn);
  ignore (Lui_app.flush app);
  let model = Drive.Session.read_model session in
  let sign_in_id =
    List.find_map
      (fun eff -> match eff with Model.SignInEffect id -> Some id | _ -> None)
      (model.Model.pending_effects @ model.Model.in_flight_effects)
    |> Option.value ~default:(-1)
  in
  Alcotest.(check bool) "sign-in effect enqueued" true (sign_in_id >= 0);
  (* mirror the real drain: applySnapshot of the effect's response, then
     resolveEffect — with a populated catalog so the graph picker renders
     real rows through the same flush *)
  ignore
    (Lui_app.send app
       (Model.ApplyCoreSnapshot
          (Drive_scenario_test.catalog_projection graphs)));
  ignore (Lui_app.flush app);
  ignore (Lui_app.send app (Model.DequeueEffect sign_in_id));
  ignore (Lui_app.send app (Model.ResolveEffect (sign_in_id, true, "")));
  ignore (Lui_app.flush app);
  Drive.Session.dispose session

let cases =
  [ Alcotest.test_case "sign-in resolve" `Quick sign_in_resolve ]
