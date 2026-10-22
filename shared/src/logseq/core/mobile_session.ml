module Graph = Mobile_graph
module Database = Mobile_database
module Payload = Mobile_payload
module Platform = Platform_crypto
module Keyring = E2ee_keyring
module Assets = Asset_files
module Rpc = Rpc_session
module Types = Session_types
module Sqlite = Sqlite
module Http = Http

type mobile_session =
  { database : Database.mobile_database
  ; keyring : Keyring.e2ee_keyring
  ; session : Types.session ref
  }

let graph_catalog_address = "logseq/graph-catalog/v1"

let snapshot_request =
  {|{"apiVersion":1,"method":"snapshot","params":{}}|}

let discard_value result =
  match result with
  | Ok _ -> Ok ()
  | Error message -> Error message

let host_options (database : Database.mobile_database) ring catalog =
  let graph = database.graph in
  {
    Rpc.default_options with
    Types.configure_identity = Some (Graph.configure_identity graph);
    outliner_projection_limit = Some 32;
    Types.load_graph_catalog =
      (match catalog with
       | Some catalog ->
         Some
           (fun () -> Sqlite.restore_string catalog graph_catalog_address)
       | None -> None);
    load_collapsed_nodes = Option.map (fun catalog graph_id ->
      match Sqlite.restore_string catalog ("logseq/collapsed-nodes/v1/" ^ graph_id) with
      | None -> []
      | Some body ->
        (try match Yojson.Basic.from_string body with
         | `List values -> List.filter_map (function `String uuid -> Some uuid | _ -> None) values
         | _ -> []
         with Yojson.Json_error _ -> [])) catalog;
    save_collapsed_nodes = Option.map (fun catalog graph_id uuids ->
      Sqlite.store_string catalog ("logseq/collapsed-nodes/v1/" ^ graph_id)
        (Yojson.Basic.to_string (`List (List.map (fun uuid -> `String uuid) uuids)))) catalog;
    save_graph_catalog =
      (match catalog with
       | Some catalog ->
         Some
           (fun body ->
             Sqlite.store_string catalog graph_catalog_address body)
       | None -> None);
    open_graph = Some (fun body -> Graph.open_graph graph body);
    import_snapshot = Some (fun body -> Graph.import_snapshot graph body);
    model_for_graph =
      Some (fun graph_id -> Database.model_for_graph database graph_id);
    apply_sync_event =
      Some (fun body -> Graph.apply_sync_event graph body);
    sync_cursor = Some (fun () -> Graph.sync_cursor graph);
    graph_blocks = Some (fun () -> Graph.blocks graph);
    graph_db = Some (fun () -> Graph.projected_db graph);
    authoritative_graph_blocks =
      Some (fun () -> Graph.authoritative_blocks graph);
    graph_sidebar_pages = Some (fun () -> Graph.sidebar_pages graph);
    graph_tag_pages = Some (fun () -> Graph.tag_pages graph);
    graph_node_is_tag = Some (fun uuid -> Graph.node_is_tag graph uuid);
    graph_node_is_property =
      Some (fun uuid -> Graph.node_is_property graph uuid);
    graph_page_blocks =
      Some (fun uuid -> Graph.blocks_for_page graph uuid);
    graph_node_icon = Some (Graph.node_icon graph);
    graph_node_destination =
      Some (fun uuid -> Graph.node_destination graph uuid);
    graph_node_references =
      Some (fun uuid -> Graph.references_for_node graph uuid);
    graph_tag_objects =
      Some (fun uuid -> Graph.objects_for_tag graph uuid);
    graph_normalize_titles =
      Some (fun uuid titles -> Graph.normalize_titles graph uuid titles);
    graph_search = Some (fun query -> Graph.search graph query);
    graph_search_page = Some (fun ~offset ~limit query -> Graph.search_page graph ~offset ~limit query);
    graph_due_flashcards =
      Some (fun now -> Graph.due_flashcards graph now);
    graph_review_flashcard =
      Some (fun uuid rating now operation_id ->
        Graph.review_flashcard graph uuid rating now operation_id);
    graph_set_page_favorite =
      Some (fun uuid favorite operation_id now ->
        Graph.set_page_favorite graph uuid favorite operation_id now);
    graph_delete_page =
      Some (fun uuid operation_id now ->
        Graph.delete_page graph uuid operation_id now);
    load_older_journals =
      Some (fun () -> Graph.load_older_journals graph);
    has_older_journals =
      Some (fun () -> Graph.has_older_journals graph);
    stage_operation =
      Some (fun operation -> Graph.stage graph operation);
    prepare_operation =
      Some (fun operation -> Graph.prepare_sync graph operation);
    pending_operations =
      Some (fun () -> Graph.pending_operations graph);
    load_sync_error = Some (fun () -> Graph.sync_error graph);
    record_sync_failure = Some (Graph.record_sync_failure graph);
    load_cached_graph_key =
      Some (fun config -> discard_value (Keyring.load_cached ring config));
    unlock_graph =
      Some (fun config password ->
        discard_value (Keyring.unlock ring config password));
    ensure_user_keys = Some (fun config password -> Keyring.ensure_user_keys ring config password);
    provision_graph_key =
      Some (fun config -> discard_value (Keyring.provision ring config));
    graph_unlocked =
      Some (fun graph_id ->
        match Keyring.graph_key ring graph_id with
        | Ok _ -> true
        | Error _ -> false);
    encrypt_title =
      Some (fun graph_id title -> Keyring.encrypt_title ring graph_id title);
    import_asset_file = (fun uuid source_path -> Graph.import_asset_file graph uuid source_path);
    resolve_asset_path =
      (fun source_path -> Graph.resolve_asset_path graph source_path);
    decrypt_asset = Some (fun graph_id bytes ->
      let ( let* ) = Result.bind in
      let* key = Keyring.graph_key ring graph_id in
      E2ee.decrypt_bytes ring.crypto key bytes);
    encrypt_asset_file =
      Some (fun graph_id path ->
        Assets.encrypt_file
          (fun gid data -> Keyring.encrypt_asset ring gid data)
          graph_id path);
    journal_page_id =
      Some (fun day -> Graph.journal_page_uuid graph day);
  }

let create crypto_call =
  let ring = Platform.create_keyring crypto_call Http.send in
  let graph =
    Graph.create
      {
        Graph.require_key =
          (fun graph_id ->
            discard_value (Keyring.graph_key ring graph_id));
        encrypt_title =
          (fun graph_id title -> Keyring.encrypt_title ring graph_id title);
        decrypt_title =
          (fun graph_id title -> Keyring.decrypt_title ring graph_id title);
      }
  in
  let database = Database.create graph in
  let session = Rpc.create_session (host_options database ring None) in
  session.Types.state :=
    { !(session.Types.state) with Types.sidebar_deferred = true };
  { database; keyring = ring; session = ref session }

let call (host : mobile_session) request =
  match Payload.database_open_path request with
  | Some path ->
    let catalog = Database.open_catalog host.database path in
    let session =
      Rpc.create_session
        (host_options host.database host.keyring (Some catalog))
    in
    session.Types.state :=
      { !(session.Types.state) with Types.sidebar_deferred = true };
    host.session := session;
    Rpc.call session snapshot_request
  | None -> Rpc.call !(host.session) request

let start crypto_call =
  let host = create crypto_call in
  Callback.register "logseq_mobile_call" (fun request -> call host request)
