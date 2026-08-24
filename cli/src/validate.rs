//! validate.rs — host differential validation (test-only shim).
//! Compiles the original .cu with nvcc and the transpiled .hip through
//! tests/shim (which maps the v1 HIP surface back onto CUDA), runs both
//! on the host GPU, and compares stdout + exit codes. This validates the
//! *emitted bodies and glue*; a real hipcc/AMD-GPU check lands at G6.

use crate::report::Validation;
use std::path::{Path, PathBuf};
use std::process::Command;

fn run_to_string(bin: &Path) -> (i32, String) {
    match Command::new(bin).output() {
        Ok(o) => (
            o.status.code().unwrap_or(3),
            String::from_utf8_lossy(&o.stdout).into_owned(),
        ),
        Err(e) => (3, format!("spawn failed: {e}")),
    }
}

pub fn shim_differential(
    nvcc: &Path,
    shim_dir: &Path,
    cu: &Path,
    hip: &Path,
    scratch: &Path,
) -> Validation {
    let mk = |tag: &str, extra: &[&str], src: &Path| -> Option<(i32, String)> {
        let out = scratch.join(tag);
        let mut cmd = Command::new(nvcc);
        cmd.arg("-O2")
            .arg("-std=c++17")
            .args(extra)
            .arg("-o")
            .arg(&out)
            .arg(src);
        let c = cmd.output().ok()?;
        if !c.status.success() {
            return None;
        }
        Some(run_to_string(&out))
    };
    let Some((c_exit, c_out)) = mk("orig", &[], cu) else {
        return Validation {
            status: "skipped".to_string(),
            cuda_stdout: String::new(),
            hip_stdout: String::new(),
            cuda_exit: 3,
            hip_exit: 3,
            note: "nvcc compile of original .cu failed".to_string(),
        };
    };
    let shim_inc = format!("-I{}", shim_dir.to_string_lossy());
    // hip_print output is HIP source; compile it as CUDA via the shim.
    let trans_cu = scratch.join("trans.cu");
    if std::fs::copy(hip, &trans_cu).is_err() {
        return Validation {
            status: "skipped".to_string(),
            cuda_stdout: c_out,
            hip_stdout: String::new(),
            cuda_exit: c_exit,
            hip_exit: 3,
            note: "could not stage transpiled output".to_string(),
        };
    }
    let Some((h_exit, h_out)) = mk("trans", &[&shim_inc], &trans_cu) else {
        return Validation {
            status: "mismatch".to_string(),
            cuda_stdout: c_out,
            hip_stdout: String::new(),
            cuda_exit: c_exit,
            hip_exit: 3,
            note: "nvcc+shim compile of transpiled .hip failed".to_string(),
        };
    };
    let status = if c_exit == h_exit && c_out == h_out {
        "match"
    } else {
        "mismatch"
    };
    Validation {
        status: status.to_string(),
        cuda_stdout: c_out,
        hip_stdout: h_out,
        cuda_exit: c_exit,
        hip_exit: h_exit,
        note: "shim differential on host GPU (see tests/shim)".to_string(),
    }
}

pub fn find_nvcc(flag: Option<PathBuf>) -> Option<PathBuf> {
    if let Some(p) = flag {
        return p.is_file().then_some(p);
    }
    std::env::var_os("PATH").and_then(|dirs| {
        std::env::split_paths(&dirs)
            .map(|d| d.join("nvcc"))
            .find(|p| p.is_file())
    })
}
