#[cfg(test)]
mod tests {
    use std::{fs, thread};
    use std::path::Path;
    use std::os::unix::net::UnixListener;
    use std::fs::File;
    use std::time::Duration;
    use roadrunner::utils::snapshot_utils::{find_container_path_parallel, get_existing_image};

    /// Helper function to create test files
    fn create_test_file(path: &str, content: Option<&str>) {
        let _ = fs::create_dir_all(Path::new(path).parent().unwrap());
        let mut file = File::create(path).expect("Failed to create test file");
        if let Some(data) = content {
            use std::io::Write;
            file.write_all(data.as_bytes()).expect("Failed to write test content");
        }
    }

    #[test]
    fn test_get_existing_image() {
        let test_dir = "/tmp/test_snapshot";
        let test_image1 = format!("{}/image1.wasm", test_dir);
        let test_image2 = format!("{}/image2.wasm", test_dir);

        // Ensure clean test setup
        let _ = fs::remove_dir_all(test_dir);
        fs::create_dir_all(test_dir).unwrap();

        // Create test image files
        create_test_file(&test_image1, None);
        create_test_file(&test_image2, None);

        let image_names = vec!["image1.wasm".to_string(), "image2.wasm".to_string()];
        let result = get_existing_image(image_names, test_dir.to_string());

        assert_eq!(result.len(), 2);
        assert!(result.contains(&test_image1));
        assert!(result.contains(&test_image2));

        // Cleanup
        let _ = fs::remove_dir_all(test_dir);
    }


    #[test]
    fn test_find_container_path_parallel() {
        let test_dir = "/tmp/test_containers";
        let container_dir = format!("{}/container1", test_dir);
        let config_path = format!("{}/config.json", container_dir);
        let socket_path = format!("{}.sock", container_dir);
        let test_function = "test_function";

        // Ensure a clean test setup
        let _ = fs::remove_dir_all(test_dir);
        fs::create_dir_all(&container_dir).unwrap();

        // Create a valid config.json with expected structure
        let config_content = r#"{ "process": { "args": ["/test_function"] } }"#;
        fs::write(&config_path, config_content).unwrap();

        // Create a test socket file
        let _listener = UnixListener::bind(&socket_path).expect("Failed to create test socket");

        // Give OS time to register the socket
        thread::sleep(Duration::from_millis(100));

        let found_path = find_container_path_parallel(test_dir, test_function);

        // Assert that the function finds the correct container path
        assert_eq!(found_path, container_dir, "Container path should match expected value");

        // Cleanup
        let _ = fs::remove_dir_all(test_dir);
    }

}