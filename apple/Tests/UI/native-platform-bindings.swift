import Darwin

@main struct CheckNativePlatformBindings {
    static func main() async throws {
        guard let executable = dlopen(nil, RTLD_NOW) else { fatalError("Could not open the current executable") }
        defer { dlclose(executable) }
        for name in ["logseq_https_send", "logseq_https_upload_file", "logseq_crypto_call", "logseq_metric_log", "logseq_graph_import_progress"] {
            precondition(dlsym(executable, name) != nil, "Missing native platform entry point: \(name)")
        }
        print("PASS: Release executable resolves all dynamic native platform entry points")
    }
}
