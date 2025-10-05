extern crate libc;
use crate::data_hose::BUNDLE_PATH;
use crate::utils::{oci_utils, snapshot_utils};
use anyhow::Error;
use chrono;
use chrono::{SecondsFormat, Utc};
use oci_spec::runtime::Spec;
use std::io::{BufReader, Read, Write};
use std::net::TcpStream;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::result::Result;
use wasmedge_sdk::{params, Instance, Vm, WasmVal};

#[derive(Clone)]
pub struct Runtime {
    pub bundle_path: String,
    pub oci_spec: Spec,
    pub vm: Option<Vm>
}

impl Runtime {
    pub fn new(bundle_path: String, oci_spec: Spec, wasm_vm: Vm) -> Runtime {
        Runtime {
            bundle_path,
            oci_spec,
            vm :Some(wasm_vm)
        }
    }

    unsafe fn handle_connection(&mut self, mut socket: UnixStream) -> Result<(), Box<dyn std::error::Error>> {

        let mut chunk = [0u8; 4];


        // Pre-allocate a buffer for chunked reading (8 KB in this case)
        let mut buffer = Vec::new(); // Buffer to accumulate the entire input

        let mut reader = BufReader::new(socket.try_clone()?);
        loop {
            let bytes_read = reader.read(&mut chunk)?;
            if bytes_read == 0 {
                // Client closed the connection
                break;
            }
            buffer.extend_from_slice(&chunk[..bytes_read]);
        }


        if !buffer.is_empty() {
            let result = self.call_vm_with_input(buffer)?;
            socket.write_all(&result.to_le_bytes())?;
            socket.flush()?;
        }
        Ok(())
    }


    pub fn create_server_socket(&mut self) -> Result<(), Box<dyn std::error::Error>> {

        let binding = self.bundle_path.to_owned() + ".sock";
        let socket_path = Path::new(&binding);
        if socket_path.exists() {
            std::fs::remove_file(&socket_path).unwrap();
        }

        let listener = UnixListener::bind(&socket_path)?;
        println!("Socket created successfully at {:?} {}", &socket_path, Utc::now());
        for stream in listener.incoming().next() {
            match stream {
                Ok(socket) => unsafe {
                    // Handle the connection (consider using threads or async for concurrency)
                    self.handle_connection(socket).unwrap_or_else(|e| eprintln!("Error: {}", e));
                }
                Err(e) => eprintln!("Connection failed: {}", e),
            }
        }
        Ok(())
    }

    fn call_vm_with_input(&mut self, input: Vec<u8>) -> Result<i64, Box<dyn std::error::Error>>{
        //println!("Value from func a {}",input);
        // Set new arguments on the wasi instance
        let vm = self.vm.as_mut().unwrap();
        let mut wasi_instance = vm.wasi_module()?;
        wasi_instance.initialize(
            Some(vec![]),
            Some(vec![]),
            Some(vec![]),
        );
        let start= Utc::now();
        println!("Run wasm func at {:?}",Utc::now());
        // wasm module main function: https://github.com/containerd/runwasi/blob/f3bc0c436077bdca3ed105b12ffe8eff1517ecad/crates/containerd-shim-wasmedge/src/instance.rs#L52
        let main_instance = vm.named_module("main").unwrap();
        //Allocate memory
        let allocate = main_instance.func("allocate_memory").unwrap();
        let len = input.len() as i32;
        let result = allocate.call(vm, params!(len)).unwrap();
        let func_addr = result[0].to_i32();
        // Write to WasmVM
        Self::write_memory_host(&main_instance,func_addr,input);
        // Execute main function
        let main_func = main_instance.func("start").unwrap();
        let res = main_func.call(vm, params!(func_addr, len)).unwrap();

        //Deallocate memory
        let allocate = main_instance.func("deallocate_memory").unwrap();
        let _result = allocate.call(vm, params!(func_addr)).unwrap();

        let end= Utc::now();
        println!("Run func finished at {:?} Duration {}",end,end-start);
        let result = res[0].to_i64();
        Ok(result)
    }
    // Write to WasmVM
    fn write_memory_host(main_instance: &Instance, address:i32, data:Vec<u8>) {
        let mut memory = main_instance.memory("memory").unwrap();
        let _ = memory.write(data, address as u32);
    }


    pub fn stop_socket (&self) -> Result<(), Box<dyn std::error::Error>>{
        let binding = self.bundle_path.as_str().to_owned() + ".sock";
        connect_unix_socket(String::from("exit").into_bytes(),self.bundle_path.as_str().to_owned())?;
        let socket_path = Path::new(&binding);
        if socket_path.exists() {
            std::fs::remove_file(&socket_path).unwrap();
            println!("Socket {:?} deleted",self.bundle_path.as_str());
        }
        Ok(())
    }
}


pub fn connect_unix_socket(input_fn_a:Vec<u8>, mut socket_path: String) -> Result<String, Error> {

    const MAX_RETRIES: u32 = 1000; // Maximum value for u32 (4,294,967,295)

    let mut retries = 0;
    let mut stream: UnixStream;

    loop {
        match UnixStream::connect(socket_path.clone() + ".sock") {
            Ok(s) => {
                stream = s;
                break;
            },
            Err(_err) => {
                retries += 1;
                if retries >= MAX_RETRIES {
                    panic!("Exceeded maximum retries, failed to connect to socket.");
                }
                socket_path = unsafe{snapshot_utils::find_container_path_parallel(BUNDLE_PATH.as_deref().unwrap_or(""), "alice-lib.wasm")};
            }
        }
    }

    if let Err(e) = stream.write_all(input_fn_a.as_slice()) {
        eprintln!("Failed to write data: {:?}", e);
    }
    stream.shutdown(std::net::Shutdown::Write).expect("shutdown failed");
    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    Ok(response)
}



#[tokio::main(flavor = "current_thread")]
pub async fn init_listener(bundle_path: String, oci_spec: Spec, vm: Vm) -> Result<(), Box<dyn std::error::Error>>{
    println!("before init");
    let address = oci_utils::arg_to_wasi(&oci_spec).first().unwrap().to_string();
    let mut listener = Runtime::new(bundle_path.clone(), oci_spec.clone(), vm.clone());
    let input = connect_to_source(address)?;
    listener.call_vm_with_input(input).expect("TODO: panic message");
    Ok(())
}

fn connect_to_source(address: String) -> Result<Vec<u8>, Box<dyn std::error::Error>>{
    let mut buffer = Vec::new();
    loop {
        match TcpStream::connect(address.clone()) {
            Ok(mut stream) => {
                // Read all the data from the server until the connection is closed
                let bytes_read = stream.read_to_end(&mut buffer)?;

                let end_time = chrono::offset::Utc::now().to_rfc3339_opts(SecondsFormat::Nanos, true);
                println!("Received {} bytes at {:?}", bytes_read, end_time);
                return Ok(buffer);
            }
            _ => {}
        }
    }

}