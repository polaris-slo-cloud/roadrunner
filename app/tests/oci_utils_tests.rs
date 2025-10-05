#[cfg(test)]
mod tests {
    use oci_spec::runtime::{Process, Spec};
    use roadrunner::utils::oci_utils::{arg_to_wasi, delete, env_to_wasi, get_wasm_annotations};
    use std::collections::HashMap;
    use std::fs;
    use std::os::unix::net::UnixListener;
    use std::path::Path;

    #[test]
    fn test_env_to_wasi() {
        let mut process = Process::default();
        process.set_env(Some(vec![
            "KEY1=VALUE1".to_string(),
            "KEY2=VALUE2".to_string(),
        ]));

        let mut spec = Spec::default();
        spec.set_process(Some(process));

        let env_vars = env_to_wasi(&spec);
        assert_eq!(env_vars.len(), 2);
        assert_eq!(env_vars[0], "KEY1=VALUE1");
        assert_eq!(env_vars[1], "KEY2=VALUE2");
    }

    #[test]
    fn test_arg_to_wasi() {
        let mut process = Process::default();
        process.set_args(Some(vec![
            "/usr/bin/function".to_string(),
            "--flag".to_string(),
        ]));

        let mut spec = Spec::default();
        spec.set_process(Some(process));

        let args = arg_to_wasi(&spec);
        assert_eq!(args.len(), 2);
        assert_eq!(args[0], "/usr/bin/function");
        assert_eq!(args[1], "--flag");
    }

    #[test]
    fn test_get_wasm_annotations() {
        let mut annotations = HashMap::new();
        annotations.insert("key1".to_string(), "value1".to_string());
        annotations.insert("key2".to_string(), "value2".to_string());

        let mut spec = Spec::default();
        spec.set_annotations(Some(annotations));

        let value = get_wasm_annotations(&spec, "key1");
        assert_eq!(value, "value1");

        let empty_value = get_wasm_annotations(&spec, "non_existent_key");
        assert_eq!(empty_value, "");
    }

    #[test]
    fn test_delete() {
        let test_socket_path = "/tmp/test_bundle.sock";

        // Ensure no existing socket file
        let _ = fs::remove_file(test_socket_path);

        // Create a real Unix socket
        let _listener = UnixListener::bind(test_socket_path).expect("Failed to create test socket");

        // Ensure the file exists before deletion
        assert!(Path::new(test_socket_path).exists());

        // Call the delete function
        let result = delete("/tmp/test_bundle".to_string());

        // Ensure it was deleted
        assert!(result.is_ok());
        assert!(!Path::new(test_socket_path).exists());
    }
}
