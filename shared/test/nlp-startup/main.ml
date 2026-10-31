external syntax_initializations : unit -> int = "logseq_syntax_init_count"

let () =
  let check () =
    assert (Natural_date.initialization_count () = 0);
    assert (syntax_initializations () = 0) in
  check ();
  let session = Rpc_session.create_session Rpc_session.default_options in
  ignore (Rpc_session.snapshot_visible session);
  ignore (Editor_command.date_day "2026-10-31");
  ignore (Natural_date.day "0044-03-15");
  ignore (Natural_date.timestamp "1792719000000");
  check ();
  print_endline "PASS: core startup and canonical date input do not initialize the NLP or syntax engines"
