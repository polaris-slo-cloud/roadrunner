#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File};
    use std::io::Write;
    use std::sync::{Arc, Mutex};
    use std::path::Path;
    use tempfile::tempdir;
    use wasmedge_sdk::{Vm, WasmValue, Caller, Store, CallingFrame};
    use roadrunner::data_hose::{find_function_metadata, read_memory_host, transfer_data_within_wasm_vm};
    use wasmedge_sdk::error::HostFuncError;

    #[test]
    fn test_find_function_metadata() {
        let temp_dir = tempdir().expect("Failed to create temp directory");
        let container_path = temp_dir.path().join("test_container");
        let config_path = container_path.join("config.json");
        let socket_path = container_path.join("test_container.sock");

        fs::create_dir_all(&container_path).expect("Failed to create container path");

        // Create a mock OCI config file
        let oci_config = r#"
        {
            "annotations": {
                "target.function": "test_function",
                "target.address": "127.0.0.1:8080"
            }
        }"#;

        let mut config_file = File::create(&config_path).expect("Failed to create config.json");
        config_file.write_all(oci_config.as_bytes()).expect("Failed to write config.json");

        // Create a mock socket file
        File::create(&socket_path).expect("Failed to create mock socket file");

        let result = find_function_metadata(temp_dir.path().to_str().unwrap());

        assert!(result.is_some(), "Function metadata should be found");
        let (found_socket, function_name, function_address) = result.unwrap();

        assert_eq!(found_socket, socket_path.to_str().unwrap(), "Socket path mismatch");
        assert_eq!(function_name, "test_function", "Function name mismatch");
        assert_eq!(function_address, "127.0.0.1:8080", "Function address mismatch");

        temp_dir.close().expect("Failed to clean up temp directory");
    }

    #[test]
    fn test_transfer_data_within_wasm_vm() {
        let vm_shared = Arc::new(Mutex::new(Vm::new(None).expect("Failed to create VM")));
        let source_function_name = "test_module".to_string();
        let address = 0;
        let len = 10;

        let result = transfer_data_within_wasm_vm(&vm_shared, &source_function_name, address, len);

        assert!(result.is_ok(), "transfer_data_within_wasm_vm should execute successfully");
    }
}