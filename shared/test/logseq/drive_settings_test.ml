(* Settings sheets and the runtime log. Scripts live in logseq/drive/settings/. *)

let handle (host : Drive_host.host) _model = function
  | Model.ReportErrorEffect (id, message) ->
    host.Drive_host.runtime_log <-
      {
        Model.id = "error-" ^ string_of_int id;
        level = "ERROR";
        source = "ui";
        timestamp = "Now";
        message;
      }
      :: host.runtime_log;
    Some (Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.SaveSettingsEffect (id, settings) ->
    host.Drive_host.saved_settings <- Some settings;
    Some (Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.ExportGraphDatabaseEffect id ->
    host.runtime_log <-
      {
        Model.id = "export-" ^ string_of_int id;
        level = "info";
        source = "drive";
        timestamp = "Now";
        message = "Exported graph database";
      }
      :: host.runtime_log;
    Some (Model.DequeueEffect id :: Drive_host.resolved id)
  | Model.RefreshRuntimeLogEffect (id, _, errors_only, _) ->
    let records =
      if errors_only then
        List.filter
          (fun (record : Model.runtime_log_record) ->
            String.lowercase_ascii record.level = "error")
          host.runtime_log
      else host.runtime_log
    in
    Some
      (Model.DequeueEffect id
      :: Model.ApplyRuntimeLog (records, None)
      :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/settings"
