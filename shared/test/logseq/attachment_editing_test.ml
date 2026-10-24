open Test_util
module State = Outliner_state
module Cache = Cache_model
module Ds = Datascript
module U = Yojson.Basic.Util

let attachment_presenters_commit_and_release_the_editor () =
  let context = Outliner_state_test.context_for [Outliner_state_test.block "a" ""] in
  List.iter (fun toolbar ->
    let current = Outliner_state_test.start context "a" "Draft before photo" 18 in
    let next, commands = State.update context current (State.Toolbar toolbar) in
    check ~msg:"The editor must finish before a native attachment presenter opens" (next.editing = None);
    match commands with
    | State.Commit_title value :: _ -> check_eq value.Pending_ops.title "Draft before photo"
    | _ -> fail "The draft must be saved before requesting the camera or file picker"
  ) [State.Camera; State.Attachment; State.Audio]

let cases = [case "attachment presenters commit and release the editor" attachment_presenters_commit_and_release_the_editor]
