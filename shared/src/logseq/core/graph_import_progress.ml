let send = lazy (Foreign.foreign "logseq_graph_import_progress"
  Ctypes.(string @-> string @-> int64_t @-> int64_t @-> returning void))

let report graph_id phase completed total =
  try Lazy.force send graph_id phase (Int64.of_int completed)
      (Int64.of_int (Option.value ~default:(-1) total))
  with _ -> ()
