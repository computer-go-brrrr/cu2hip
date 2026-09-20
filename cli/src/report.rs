//! report.rs — cu2hip JSON report schema (report/v1).
//! Written to --report on every run, success or fail-closed reject.

use serde::Serialize;
use std::path::Path;

#[derive(Serialize, Clone)]
pub struct Stage {
    pub name: String,
    pub exit: i32,
    pub ms: u128,
}

#[derive(Serialize, Clone, Default)]
pub struct Diagnostic {
    pub code: String,
    pub feature: String,
    pub loc: String,
    pub hint: String,
}

#[derive(Serialize, Clone)]
pub struct Validation {
    /// "match" | "mismatch" | "skipped"
    pub status: String,
    pub cuda_stdout: String,
    pub hip_stdout: String,
    pub cuda_exit: i32,
    pub hip_exit: i32,
    pub note: String,
}

#[derive(Serialize)]
pub struct Report {
    pub version: String,
    pub input: String,
    pub output: String,
    pub arch: String,
    pub cuda_path: String,
    pub stages: Vec<Stage>,
    pub diagnostics: Vec<Diagnostic>,
    pub validation: Option<Validation>,
}

impl Report {
    pub fn new(input: &Path, output: &Path, arch: &str, cuda_path: &str) -> Self {
        Report {
            version: "cu2hip-report/v1".to_string(),
            input: input.to_string_lossy().into_owned(),
            output: output.to_string_lossy().into_owned(),
            arch: arch.to_string(),
            cuda_path: cuda_path.to_string(),
            stages: Vec::new(),
            diagnostics: Vec::new(),
            validation: None,
        }
    }

    pub fn write(&self, path: &Path) -> std::io::Result<()> {
        let mut s = serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string());
        s.push('\n');
        std::fs::write(path, s)
    }
}

/// Diagnostics embedded in a stage-output envelope (cu2mini/minimap format).
pub fn read_envelope_diagnostics(path: &Path) -> Vec<Diagnostic> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    let v: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    if let Some(arr) = v.get("diagnostics").and_then(|d| d.as_array()) {
        for d in arr {
            out.push(Diagnostic {
                code: d.get("code").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                feature: d
                    .get("feature")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string(),
                loc: d.get("loc").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                hint: d.get("hint").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            });
        }
    }
    out
}
