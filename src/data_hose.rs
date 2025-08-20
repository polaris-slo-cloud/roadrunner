use std::path::Path;
use log::info;
use oci_spec::runtime::Spec;
use walkdir::WalkDir;
use wasmedge_sdk::{host_function, Caller, WasmValue,Vm, Instance, params};
use wasmedge_sdk::error::HostFuncError;
use crate::remote_transfer::{net_transfer_bind};
use crate::utils::{oci_utils};
use crate::{runtime};
use std::sync::{Arc, Mutex};

extern crate libc;

pub static mut OCI_SPEC:Option<Spec> = None;
pub static mut BUNDLE_PATH:Option<String> = None;

#[host_function]
pub fn read_memory_host(caller: Caller, input: Vec<WasmValue>) -> Result<Vec<WasmValue>, HostFuncError> {
    let mut mem = caller.memory(0).unwrap();
    let arg1_ptr = input[0].to_i32() as u32;
    let arg1_len = input[1].to_i32() as u32;

    let payload = mem.read(arg1_ptr, arg1_len).expect("fail to get string");
    let mut target_function_result = String::new();

    unsafe {
        let function_metadata = find_function_metadata(BUNDLE_PATH.as_deref().unwrap_or(""));

        let (socket_path, function_name, function_address) = match function_metadata {
            Some((socket, name, address)) => (socket, name, address),
            None => {
                log::warn!("No matching function metadata found in annotations.");
                return Err(HostFuncError::User("Function not found.".to_string().parse().unwrap()));
            }
        };

        log::info!(
            "Function Metadata - Name: {}, Address: {}, Socket: {}",
            function_name, function_address, socket_path
        );

        // Try using Unix Socket first
        if let Ok(result) = runtime::connect_unix_socket(payload.clone(), socket_path) {
            target_function_result = result;
        } else {
            // If socket connection fails, fallback to the listener
            if let Err(err) = net_transfer_bind(payload.clone(),function_address) {
                log::error!("Listener failed: {:?}", err);
                return Err(HostFuncError::User("Communication failure.".to_string().parse().unwrap()));
            }
        }
    }

    // Write response back into Wasm VM
    let bytes = target_function_result.as_bytes();
    let len = bytes.len();
    mem.write(bytes, arg1_ptr).unwrap();

    Ok(vec![WasmValue::from_i32(len as i32)])
}


/// Transfers data from the source function within the same Wasm VM.
///
/// - `vm_shared`: A shared reference to the WasmEdge VM.
/// - `source_function_name`: Name of the source function module.
/// - `address`: The address in memory where the data exists.
/// - `len`: The length of the data.
pub fn transfer_data_within_wasm_vm(
    vm_shared: &Arc<Mutex<Vm>>,
    source_function_name: &String,
    address: i32,
    len: i32
) -> Result<(), Box<dyn std::error::Error>> {
    let mut vm_locked = vm_shared.lock().unwrap();

    // Get the source function module instance (acts as the sender)
    let source_instance: Instance = vm_locked.named_module(source_function_name.clone()).unwrap();
    let mut source_memory = source_instance.memory("memory").unwrap();

    // Allocate memory in the source function module for the incoming data
    let allocate = source_instance.func("allocate").unwrap();
    let alloc_result = allocate.call(&mut *vm_locked, params!()).unwrap();
    let allocated_mem_addr = alloc_result[0].to_i32();

    log::info!(
        "Allocated memory in source function `{}` at address: {}",
        source_function_name, allocated_mem_addr
    );

    // Read payload from the main module
    let main_instance: Instance = vm_locked.named_module("main").unwrap();
    let main_memory = main_instance.memory("memory").unwrap();
    let payload = main_memory.read(address as u32, len as u32).expect("Failed to read memory from main module");

    log::info!("Payload read successfully from main module.");

    // Write payload into the source function module's memory space
    let _ = source_memory.write(payload, allocated_mem_addr as u32);

    log::info!("Payload written to source function `{}` memory.", source_function_name);

    // Invoke the source function's processing function (e.g., `process_data`)
    let process_func = source_instance.func("process_data").unwrap();
    let _ = process_func.call(&mut *vm_locked, params!()).unwrap();

    log::info!("Function `{}` executed successfully.", source_function_name);

    Ok(())
}

pub fn find_function_metadata(root_path: &str) -> Option<(String, String, String)> {
    for file in WalkDir::new(root_path).into_iter().filter_map(|file| file.ok()) {
        let file_name = file.file_name().to_str().unwrap();
        if file.metadata().unwrap().is_file() && file_name == "config.json" {
            info!("OCI config spec found: {}", file.path().display());
            let container_path = file.path().display().to_string().replace("/config.json", "");

            // Load OCI spec
            let spec = match oci_utils::load_spec(container_path.clone()) {
                Ok(spec) => spec,
                Err(_) => continue,
            };

            // Retrieve function name and address from annotations
            let function_name = oci_utils::get_wasm_annotations(&spec, "target.function");
            let function_address = oci_utils::get_wasm_annotations(&spec, "target.address");

            if function_name.is_empty() || function_address.is_empty() {
                continue;
            }

            // Ensure function name formatting
            let formatted_function_name = function_name.replace("/", "");
            if formatted_function_name.is_empty() {
                continue;
            }

            // Check if the socket file exists
            let socket_path = format!("{}.sock", container_path);
            if Path::new(&socket_path).exists() {
                return Some((socket_path, formatted_function_name, function_address));
            }
        }
    }
    None
}



