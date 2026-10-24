module Ds = Datascript

let page = "f0000000-0000-4000-8000-000000000001"
let code_page = "f0000000-0000-4000-8000-000000000002"
let photo_page = "f0000000-0000-4000-8000-000000000003"
let video_page = "f0000000-0000-4000-8000-000000000004"
let math_page = "f0000000-0000-4000-8000-000000000005"
let formula_page = "f0000000-0000-4000-8000-000000000006"
let discussion_page = "f0000000-0000-4000-8000-000000000007"
let empty_block = "f0000000-0000-4000-8000-000000000013"
let code_block = "f0000000-0000-4000-8000-000000000012"
let ref_uuid uuid = Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid)
let entity uuid fields = Ds.Entity {Ds.db_id = Some (Ds.Temp_id uuid);
  attrs = ("block/uuid", Ds.One_value (Ds.Uuid uuid)) :: fields}
let text attr value = attr, Ds.One_value (Ds.String value)
let reference attr uuid = attr, Ds.One_value (Ds.Ref_to (ref_uuid uuid))
let tag ident = "block/tags", Ds.One_value (Ds.Ref_to (Ds.Ident ident))
let make_page uuid title = entity uuid [text "block/title" title;
  text "block/name" (String.lowercase_ascii title); tag "logseq.class/Page"]
let block uuid parent order title extra = entity uuid
  ([text "block/title" title; reference "block/page" parent;
    reference "block/parent" parent; text "block/order" order] @ extra)
let () =
  let path = Sys.argv.(1) in
  let db = Result.get_ok (Graph_bootstrap.database "Mobile feedback" false (fun value -> Ok value)) in
  let db = Ds.db_with [
    make_page page "Sep 17th, 2026"; make_page code_page "Code continuation";
    make_page photo_page "Photo capture"; make_page video_page "YouTube link";
    make_page math_page "LaTeX regression"; make_page formula_page "Formula";
    make_page discussion_page "Comments and reactions";
    block "f0000000-0000-4000-8000-000000000011" page "a0" "Journal content" [];
    block "f0000000-0000-4000-8000-000000000021" page "a1" "[[Formula]]" [reference "block/refs" formula_page];
    block "f0000000-0000-4000-8000-000000000022" formula_page "a0" "A formula page" [];
    block "f0000000-0000-4000-8000-000000000023" formula_page "a1" "[[Sep 17th, 2026]]" [reference "block/refs" page];
    block code_block code_page "a0" "print(42)" ["logseq.property.node/display-type", Ds.One_value (Ds.Keyword "code")];
    block empty_block photo_page "a0" "" [];
    block "f0000000-0000-4000-8000-000000000014" video_page "a0" "https://youtu.be/dQw4w9WgXcQ" [];
    block "f0000000-0000-4000-8000-000000000015" math_page "a0"
      "For each mouse, let $h_{\\mathrm{wean}}^{\\mathrm{ear}}$ be ear heteroplasmy at weaning, and $h_t^{\\mathrm{cull}}$ be heteroplasmy in tissue t at culling." [];
    block "f0000000-0000-4000-8000-000000000016" math_page "a1"
      "\\underbrace{a-b}_{\\text{ear drift}} + \\underbrace{c-a}_{\\text{organ divergence}}"
      ["logseq.property.node/display-type", Ds.One_value (Ds.Keyword "math")];
    block "f0000000-0000-4000-8000-000000000017" discussion_page "a0" "A note with a discussion" [];
    block "f0000000-0000-4000-8000-000000000018" discussion_page "a1" "Discussion" [tag "logseq.class/Comments"];
    entity "f0000000-0000-4000-8000-000000000019"
      [text "block/title" "This is a comment, separate from the note.";
       reference "block/page" discussion_page; reference "block/parent" "f0000000-0000-4000-8000-000000000018";
       text "block/order" "a0"; tag "logseq.class/Comment"];
    entity "f0000000-0000-4000-8000-000000000020"
      [reference "logseq.property.reaction/target" "f0000000-0000-4000-8000-000000000017";
       text "logseq.property.reaction/emoji-id" "+1"];
  ] db in
  Result.get_ok (Graph_store.begin_import path);
  Result.get_ok (Graph_store.append_rows path (Result.get_ok (Graph_bootstrap.snapshot_rows db)));
  Result.get_ok (Graph_store.activate path);
  Result.get_ok (Sync_checkpoint.save_checkpoint_atomic
    (Filename.concat (Filename.dirname path) "sync.checkpoint")
    (Sync_checkpoint.create "feedback" Graph_bootstrap.schema_version 0));
  print_endline path
