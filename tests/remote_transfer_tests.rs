#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::thread;
    use std::time::Duration;
    use roadrunner::remote_transfer::{handle_client, net_transfer_bind};

    fn get_free_port() -> u16 {
        TcpListener::bind("127.0.0.1:0")
            .expect("Failed to bind to get free port")
            .local_addr()
            .unwrap()
            .port()
    }

    #[test]
    fn test_net_transfer_bind() {
        let test_address = format!("127.0.0.1:{}", get_free_port());
        let test_payload = b"Hello, zero-copy transfer!".to_vec();
        let test_payload_clone = test_payload.clone();
        let server_address = test_address.clone(); // Clone for server thread
        let client_address = test_address.clone(); // Clone for client

        // Spawn the server
        let server_thread = thread::spawn(move || {
            net_transfer_bind(test_payload_clone, server_address).unwrap();
        });

        // Wait until the server is ready
        let mut attempts = 0;
        while TcpStream::connect(&client_address).is_err() && attempts < 10 {
            thread::sleep(Duration::from_millis(50));
            attempts += 1;
        }

        // Connect as a client
        let mut client = TcpStream::connect(&client_address).expect("Failed to connect to server");
        let mut received_data = Vec::new();
        client.read_to_end(&mut received_data).expect("Failed to read data");

        // Validate received data
        assert_eq!(received_data, test_payload, "Received data does not match expected payload");

        // Cleanup
        client.shutdown(std::net::Shutdown::Both).unwrap();
        thread::sleep(Duration::from_millis(100));
        server_thread.join().expect("Server thread panicked");
    }

    #[test]
    fn test_handle_client() {
        let test_payload = b"Test payload data".to_vec();
        let test_address = format!("127.0.0.1:{}", get_free_port());

        let listener = TcpListener::bind(&test_address).expect("Failed to bind test listener");

        // Spawn server thread
        let server_thread = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("Failed to accept connection");
            handle_client(stream, &test_payload).expect("Failed to handle client transfer");
        });

        // Wait until server is ready
        let mut attempts = 0;
        while TcpStream::connect(&test_address).is_err() && attempts < 10 {
            thread::sleep(Duration::from_millis(50));
            attempts += 1;
        }

        // Connect as a client
        let mut client = TcpStream::connect(&test_address).expect("Failed to connect to server");
        let mut received_data = Vec::new();
        client.read_to_end(&mut received_data).expect("Failed to read data");

        // Validate received data
        assert_eq!(received_data, test_payload, "Data received does not match expected payload");

        // Cleanup
        client.shutdown(std::net::Shutdown::Both).unwrap();
        server_thread.join().expect("Server thread panicked");
    }
}