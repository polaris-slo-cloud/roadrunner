use anyhow::Context;
use chrono::{DateTime, Utc};
use containerd_shim_wasm::sandbox::error::Error;
use containerd_shim_wasm::sandbox::{exec, ShimCli};
use containerd_shim_wasm::sandbox::oci;
use containerd_shim_wasm::sandbox::{EngineGetter, Instance, InstanceConfig};
use libc::{dup, dup2, SIGINT, SIGKILL, STDERR_FILENO, STDIN_FILENO, STDOUT_FILENO};
use log::{error, info};
use std::fs::OpenOptions;
use std::io::ErrorKind;
use std::os::unix::io::{IntoRawFd, RawFd};
use std::path::Path;
use std::sync::{
    mpsc::Sender,
    {Arc, Condvar, Mutex},
};
use std::thread;
use wasmedge_sdk::{config::{CommonConfigOptions, ConfigBuilder, HostRegistrationConfigOptions}, params, ImportObjectBuilder, PluginManager, Vm};
use roadrunner::error::WasmRuntimeError;
use regex::Regex;
use itertools::Itertools;
use roadrunner::{data_hose, runtime};
use roadrunner::data_hose::transfer_data_within_wasm_vm;
use roadrunner::utils::{oci_utils, snapshot_utils};

static mut STDIN_FD: Option<RawFd> = None;
static mut STDOUT_FD: Option<RawFd> = None;
static mut STDERR_FD: Option<RawFd> = None;

type ExitCode = (Mutex<Option<(u32, DateTime<Utc>)>>, Condvar);
pub struct Wasi {
    exit_code: Arc<ExitCode>,
    engine: Vm,

    stdin: String,
    stdout: String,
    stderr: String,
    bundle: String,
    pidfd: Arc<Mutex<Option<exec::PidFD>>>,
}



pub fn reset_stdio() {
    unsafe {
        if STDIN_FD.is_some() {
            dup2(STDIN_FD.unwrap(), STDIN_FILENO);
        }
        if STDOUT_FD.is_some() {
            dup2(STDOUT_FD.unwrap(), STDOUT_FILENO);
        }
        if STDERR_FD.is_some() {
            dup2(STDERR_FD.unwrap(), STDERR_FILENO);
        }
    }
}

pub fn maybe_open_stdio(path: &str) -> Result<Option<RawFd>, Error> {
    if path.is_empty() {
        return Ok(None);
    }
    match OpenOptions::new().read(true).write(true).open(path) {
        Ok(f) => Ok(Some(f.into_raw_fd())),
        Err(err) => match err.kind() {
            ErrorKind::NotFound => Ok(None),
            _ => Err(err.into()),
        },
    }
}


pub fn prepare_module(mut vm: Vm, spec: &oci::Spec, stdin_path: String, stdout_path: String, stderr_path: String ) -> Result<Vm, WasmRuntimeError> {
    info!("opening rootfs");
    let rootfs_path = oci::get_root(spec).to_str().unwrap();
    let root = format!("/:{}", rootfs_path);
    let mut preopens = vec![root.as_str()];

    info!("opening mounts");
    let mut mounts = oci_utils::get_wasm_mounts(spec);
    preopens.append(&mut mounts);

    let args = oci::get_args(spec);
    info!("args {:?}", args);
    let envs = oci_utils::env_to_wasi(spec);
    info!("envs {:?}", envs);

    info!("opening stdin");
    let stdin = maybe_open_stdio(&stdin_path).context("could not open stdin")?;
    if stdin.is_some() {
        unsafe {
            STDIN_FD = Some(dup(STDIN_FILENO));
            dup2(stdin.unwrap(), STDIN_FILENO);
        }
    }

    info!("opening stdout");
    let stdout = maybe_open_stdio(&stdout_path).context("could not open stdout")?;
    if stdout.is_some() {
        unsafe {
            STDOUT_FD = Some(dup(STDOUT_FILENO));
            dup2(stdout.unwrap(), STDOUT_FILENO);
        }
    }

    info!("opening stderr");
    let stderr = maybe_open_stdio(&stderr_path).context("could not open stderr")?;
    if stderr.is_some() {
        unsafe {
            STDERR_FD = Some(dup(STDERR_FILENO));
            dup2(stderr.unwrap(), STDERR_FILENO);
        }
    }

    let mut cmd = args[0].clone();
    let stripped = args[0].strip_prefix(std::path::MAIN_SEPARATOR);
    if let Some(strpd) = stripped {
        cmd = strpd.to_string();
    }

    let mod_path = oci::get_root(spec).join(cmd);

    info!("setting up wasi");
    let mut new_args = args.to_vec();
    let mut wasi_instance = vm.wasi_module()?;
    wasi_instance.initialize(
        Some(new_args.iter().map(|s| s as &str).collect()),
        Some(envs.iter().map(|s| s as &str).collect()),
        Some(preopens),
    );
    let target: String = new_args.get(0).cloned().unwrap_or_default();
    let vm_shared = Arc::new(Mutex::new(vm.clone()));

    let import = ImportObjectBuilder::new()
        .with_func::<(i32, i32), i32>("read_memory_host", move |caller, input| {
            // parse the first argument of WasmValue type
            //println!("[+] external function called: read_memory_host");

            let address = input[0].to_i32();
            let len = input[1].to_i32();
            transfer_data_within_wasm_vm(&vm_shared, &target, address, len).unwrap();
            let result = data_hose::read_memory_host(caller, input)?;

            Ok(result) // Return the result of the function to match the expected type
        })?
        .build("wasi_export")?;

    let vm= vm.register_import_module(import)?.register_module_from_file("main", mod_path)?;
    info!("module registered");
    Ok(vm)
}

pub fn extract_modules_from_wat(path: &Path) -> Vec<String>{
    let mod_wat = wasmprinter::print_file(path).unwrap();
    info!("module wat {:?}",mod_wat);
    let re = Regex::new(r#"\bimport\s+\S+"#).unwrap();
    let matches = re.find_iter(mod_wat.as_str()).map(|s| s.as_str()).unique().collect_vec();
    let mut modules: Vec<String> = vec![];
    for cap in matches {
        let module = cap.replace("import ","").replace("\"","") + ".wasm";
        modules.push(module.to_string());
    }
    info!("extracted import modules from wat {:#?}", modules);
    let modules_path: Vec<String> = snapshot_utils::get_existing_image(modules, path.to_str().unwrap().to_string());
    info!("Modules path: {:#?}",modules_path);
    return modules_path;
}

impl Instance for Wasi {
    type E = Vm;
    fn new(_id: String, cfg: Option<&InstanceConfig<Self::E>>) -> Self {
        info!(">>> new instance");
        let cfg = cfg.unwrap();
        Wasi {
            exit_code: Arc::new((Mutex::new(None), Condvar::new())),
            engine: cfg.get_engine(),
            stdin: cfg.get_stdin().unwrap_or_default(),
            stdout: cfg.get_stdout().unwrap_or_default(),
            stderr: cfg.get_stderr().unwrap_or_default(),
            bundle: cfg.get_bundle().unwrap_or_default(),
            pidfd: Arc::new(Mutex::new(None)),
        }
    }

    fn start(&self) -> Result<u32, Error> {

        info!(">>> shim starts");
        let engine = self.engine.clone();
        let stdin = self.stdin.clone();
        let stdout = self.stdout.clone();
        let stderr = self.stderr.clone();

        let spec = oci_utils::load_spec(self.bundle.clone())?;
        let bundle_path = self.bundle.as_str();
        info!("bundle path {:?}", bundle_path);
        info!("loading specs {:?}", spec);
        unsafe {
            data_hose::OCI_SPEC=Some(spec.clone());
            data_hose::BUNDLE_PATH=Some(bundle_path.rsplitn(3, '/').nth(2).unwrap().to_string()+"/");
        }
        let vm = prepare_module(engine, &spec, stdin, stdout, stderr)
            .map_err(|e| Error::Others(format!("error setting up module: {}", e)))?;
        info!("vm created");
        let cg = oci::get_cgroup(&spec)?;

        oci::setup_cgroup(cg.as_ref(), &spec)
            .map_err(|e| Error::Others(format!("error setting up cgroups: {}", e)))?;
        let res = unsafe { exec::fork(Some(cg.as_ref())) }?;
        match res {
            exec::Context::Parent(tid, pidfd) => {
                let mut lr = self.pidfd.lock().unwrap();
                *lr = Some(pidfd.clone());

                info!("started wasi instance with tid {} at {}", tid,self.bundle.as_str());

                let code = self.exit_code.clone();
                let bundle_path = self.bundle.clone();
                let _ = thread::spawn(move || {
                    let (lock, cvar) = &*code;
                    let status = match pidfd.wait() {
                        Ok(status) => status,
                        Err(e) => {
                            error!("error waiting for pid {}: {}", tid, e);
                            oci_utils::delete(bundle_path).expect("static delete");
                            cvar.notify_all();
                            return;
                        }
                    };

                    info!("wasi instance exited with status {}", status.status);
                    let mut ec = lock.lock().unwrap();
                    *ec = Some((status.status, Utc::now()));
                    drop(ec);
                    cvar.notify_all();
                });
                Ok(tid)
            }
            exec::Context::Child => {
                // child process
                let secondary_function = oci_utils::get_wasm_annotations(&spec, "secondary.function");
                println!("Secondary function {}",secondary_function);
                if secondary_function == "true" {
                    match runtime::init_listener(bundle_path.to_string(), spec, vm) {
                         Ok(_) => std::process::exit(0),
                        Err(_) => std::process::exit(137),
                    };

                }else {
                    match vm.run_func(Some("main"), "_start", params!()) {
                        Ok(_) => std::process::exit(0),
                        Err(_) => std::process::exit(137),
                    };
                }
            }
        }
    }

    fn kill(&self, signal: u32) -> Result<(), Error> {
        info!("killcw {}",self.bundle.as_str());
        let binding = self.bundle.as_str().to_owned() + ".sock";
        let socket_path = Path::new(&binding);
        if socket_path.exists() {
            std::fs::remove_file(&socket_path).unwrap();
            info!("Socket {:?} deleted",self.bundle.as_str());
        }
        if signal as i32 != SIGKILL && signal as i32 != SIGINT {
            println!("{:?}", signal);
            return Err(Error::InvalidArgument(
                "only SIGKILL and SIGINT are supported".to_string(),
            ));
        }

        let lr = self.pidfd.lock().unwrap();
        let fd = lr
            .as_ref()
            .ok_or_else(|| Error::FailedPrecondition("module is not running".to_string()))?;
        fd.kill(SIGKILL as i32)

    }

    fn delete(&self) -> Result<(), Error> {
        info!("deletecw {}",self.bundle.as_str());
        let spec = match oci_utils::load_spec(self.bundle.clone()){
            Ok(spec) => spec,
            Err(err) => {
                error!("Could not load spec, skipping cgroup cleanup: {}", err);
                return Ok(());
            }
        };
        let cg = oci::get_cgroup(&spec)?;
        cg.delete()?;

        let binding = self.bundle.as_str().to_owned() + ".sock";
        let socket_path = Path::new(&binding);
        if socket_path.exists() {
            std::fs::remove_file(&socket_path).unwrap();
            info!("Socket {:?} deleted",self.bundle.as_str());
        }
        Ok(())
    }

    fn wait(&self, channel: Sender<(u32, DateTime<Utc>)>) -> Result<(), Error> {
        info!("wait");
        let code = self.exit_code.clone();
        thread::spawn(move || {
            let (lock, cvar) = &*code;
            let mut exit = lock.lock().unwrap();
            while (*exit).is_none() {
                exit = cvar.wait(exit).unwrap();
            }
            let ec = (*exit).unwrap();
            channel.send(ec).unwrap();
        });

        Ok(())
    }
}

impl EngineGetter for Wasi {
    type E = Vm;
    fn new_engine() -> Result<Vm, Error> {
        info!("new engine");
        PluginManager::load_from_default_paths();
        let mut host_options = HostRegistrationConfigOptions::default();
        host_options = host_options.wasi(true);
        #[cfg(all(target_os = "linux", feature = "wasi_nn", target_arch = "x86_64"))]
        {
            host_options = host_options.wasi_nn(true);
        }
        let config = ConfigBuilder::new(CommonConfigOptions::default())
            .with_host_registration_config(host_options)
            .build()
            .map_err(anyhow::Error::msg)?;

        let vm = Vm::new(Some(config)).map_err(anyhow::Error::msg)?;
        Ok(vm)
    }
}


fn main() {
    containerd_shim::run::<ShimCli<Wasi, wasmedge_sdk::Vm>>("io.containerd.rr.v1", None);
}
