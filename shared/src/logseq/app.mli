val update : Model.logseq_model -> Model.logseq_action -> Model.logseq_model

val create :
  Lui_protocol.backend -> (Model.logseq_model, Model.logseq_action) Lui_app.reducer_app

val create_with_authentication :
  Lui_protocol.backend ->
  string -> (Model.logseq_model, Model.logseq_action) Lui_app.reducer_app

val model :
  (Model.logseq_model, Model.logseq_action) Lui_app.reducer_app -> Model.logseq_model
