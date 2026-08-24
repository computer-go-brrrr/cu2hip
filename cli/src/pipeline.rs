//! pipeline.rs — stage discovery and execution.
//! Exit-code contract (documented, stable): stage binaries use
//! 0 ok / 2 fail-closed reject / 3 internal error. cu2hip passes
//! stage exits through and adds exit 1 for validation mismatch.

use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

pub struct StageOutput {
    pub exit: i32,
    pub stderr: String,
    pub ms: u128,
}

/// Resolve a stage binary: explicit flag > CU2HIP_<NAME> env > PATH search.
pub fn resolve_tool(flag: Option<PathBuf>, env_name: &str, name: &str) -> Result<PathBuf, String> {
    if let Some(p) = flag {
        return Ok(p);
    }
    if let Ok(p) = std::env::var(env_name) {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Ok(p);
        }
    }
    if let Some(dirs) = std::env::var_os("PATH") {
        for d in std::env::split_paths(&dirs) {
            let p = Path::new(&d).join(name);
            if p.is_file() {
                return Ok(p);
            }
        }
    }
    Err(format!(
        "cannot locate stage binary '{name}' (flag, ${env_name}, or PATH)"
    ))
}

pub fn run_stage(bin: &Path, args: &[String]) -> io::Result<StageOutput> {
    let t0 = Instant::now();
    let out = Command::new(bin).args(args).output()?;
    Ok(StageOutput {
        exit: out.status.code().unwrap_or(3),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        ms: t0.elapsed().as_millis(),
    })
}

/// Scratch dir for one transpile: <tmp>/cu2hip-<pid>[-<tag>].
pub fn scratch_dir(tag: &str) -> io::Result<PathBuf> {
    let mut d = std::env::temp_dir();
    d.push(format!("cu2hip-{}-{}", std::process::id(), tag));
    std::fs::create_dir_all(&d)?;
    Ok(d)
}
