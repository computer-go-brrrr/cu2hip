//! cu2hip — orchestrating CLI for the verified CUDA->HIP pipeline (G5).
//!
//! Single file: cu2mini (.cu -> MiniCUDA.json) -> minimap (verified core ->
//! MiniHIP.json) -> hip_print (-> .hip). Batch mode runs a directory with
//! per-file expectations. --validate adds the host shim differential.
//!
//! Exit codes: 0 ok | 1 validation mismatch or batch expectation failure |
//!             2 fail-closed reject (diagnostics in report) | 3 internal error.

mod pipeline;
mod report;
mod validate;

use clap::Parser;
use pipeline::{resolve_tool, run_stage, scratch_dir, StageOutput};
use report::{read_envelope_diagnostics, Diagnostic, Report, Stage};
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(name = "cu2hip", version, about = "Verified CUDA->HIP transpiler driver")]
struct Args {
    /// Input .cu file, or directory of .cu files with --batch
    input: PathBuf,
    /// Output .hip file (single mode) or directory (batch mode)
    #[arg(short, long)]
    output: Option<PathBuf>,
    /// Write JSON report (single mode) or report directory (batch mode)
    #[arg(long)]
    report: Option<PathBuf>,
    /// GPU arch for the frontend (e.g. sm_86)
    #[arg(long, default_value = "sm_86")]
    arch: String,
    /// Batch mode: transpile every *.cu in INPUT dir
    #[arg(long, default_value_t = false)]
    batch: bool,
    /// Expected stage exit code per file in batch mode (0 corpus, 2 rejects)
    #[arg(long, default_value_t = 0)]
    expect_exit: i32,
    /// Run host shim differential after transpile (single mode)
    #[arg(long, default_value_t = false)]
    validate: bool,
    /// tests/shim dir for --validate
    #[arg(long)]
    shim_dir: Option<PathBuf>,
    /// Stage binary overrides
    #[arg(long)]
    cu2mini: Option<PathBuf>,
    #[arg(long)]
    minimap: Option<PathBuf>,
    #[arg(long)]
    hip_print: Option<PathBuf>,
    #[arg(long)]
    nvcc: Option<PathBuf>,
}

struct Tools {
    cu2mini: PathBuf,
    minimap: PathBuf,
    hip_print: PathBuf,
}

fn resolve_tools(a: &Args) -> Result<Tools, String> {
    Ok(Tools {
        cu2mini: resolve_tool(a.cu2mini.clone(), "CU2MINI", "cu2mini")?,
        minimap: resolve_tool(a.minimap.clone(), "MINIMAP", "minimap")?,
        hip_print: resolve_tool(a.hip_print.clone(), "HIP_PRINT", "hip_print")?,
    })
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// Run the three stages for one file. Returns (report, exit).
fn transpile_one(
    tools: &Tools,
    arch: &str,
    cu: &Path,
    hip: &Path,
    scratch: &Path,
) -> (Report, i32) {
    let mut rep = Report::new(cu, hip, arch);
    let cu_json = scratch.join("cu.json");
    let hip_json = scratch.join("hip.json");

    let r: StageOutput = match run_stage(
        &tools.cu2mini,
        &[
            s(cu),
            "-o".to_string(),
            s(&cu_json),
            "--arch".to_string(),
            arch.to_string(),
        ],
    ) {
        Ok(r) => r,
        Err(e) => {
            rep.diagnostics.push(Diagnostic {
                code: "Internal".to_string(),
                feature: "spawn-cu2mini".to_string(),
                loc: s(cu),
                hint: e.to_string(),
            });
            return (rep, 3);
        }
    };
    rep.stages.push(Stage {
        name: "cu2mini".to_string(),
        exit: r.exit,
        ms: r.ms,
    });
    if r.exit == 2 {
        rep.diagnostics = read_envelope_diagnostics(&cu_json);
        return (rep, 2);
    }
    if r.exit != 0 {
        return (rep, 3);
    }

    let r = match run_stage(
        &tools.minimap,
        &[s(&cu_json), "-o".to_string(), s(&hip_json)],
    ) {
        Ok(r) => r,
        Err(e) => {
            rep.diagnostics.push(Diagnostic {
                code: "Internal".to_string(),
                feature: "spawn-minimap".to_string(),
                loc: s(cu),
                hint: e.to_string(),
            });
            return (rep, 3);
        }
    };
    rep.stages.push(Stage {
        name: "minimap".to_string(),
        exit: r.exit,
        ms: r.ms,
    });
    if r.exit == 2 {
        rep.diagnostics = read_envelope_diagnostics(&hip_json);
        return (rep, 2);
    }
    if r.exit != 0 {
        return (rep, 3);
    }

    let r = match run_stage(
        &tools.hip_print,
        &[s(&hip_json), "-o".to_string(), s(hip)],
    ) {
        Ok(r) => r,
        Err(e) => {
            rep.diagnostics.push(Diagnostic {
                code: "Internal".to_string(),
                feature: "spawn-hip_print".to_string(),
                loc: s(cu),
                hint: e.to_string(),
            });
            return (rep, 3);
        }
    };
    rep.stages.push(Stage {
        name: "hip_print".to_string(),
        exit: r.exit,
        ms: r.ms,
    });
    if r.exit != 0 {
        return (rep, 3);
    }
    (rep, 0)
}

fn single(a: &Args) -> i32 {
    let tools = match resolve_tools(a) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("cu2hip: {e}");
            return 3;
        }
    };
    let out = match &a.output {
        Some(o) => o.clone(),
        None => {
            eprintln!("cu2hip: single mode requires -o");
            return 3;
        }
    };
    if let Some(parent) = out.parent() {
        if !parent.as_os_str().is_empty() {
            let _ = std::fs::create_dir_all(parent);
        }
    }
    let scratch = match scratch_dir("one") {
        Ok(d) => d,
        Err(e) => {
            eprintln!("cu2hip: scratch: {e}");
            return 3;
        }
    };
    let (mut rep, code) = transpile_one(&tools, &a.arch, &a.input, &out, &scratch);
    if code == 0 && a.validate {
        match validate::find_nvcc(a.nvcc.clone()) {
            None => {
                rep.validation = Some(report::Validation {
                    status: "skipped".to_string(),
                    cuda_stdout: String::new(),
                    hip_stdout: String::new(),
                    cuda_exit: 3,
                    hip_exit: 3,
                    note: "nvcc not found".to_string(),
                });
            }
            Some(nvcc) => {
                let shim = a.shim_dir.clone().unwrap_or_else(|| PathBuf::from("tests/shim"));
                let v = validate::shim_differential(&nvcc, &shim, &a.input, &out, &scratch);
                let mismatch = v.status == "mismatch";
                rep.validation = Some(v);
                if mismatch {
                    if let Some(rp) = &a.report {
                        let _ = rep.write(rp);
                    }
                    eprintln!("cu2hip: validation MISMATCH (see report)");
                    return 1;
                }
            }
        }
    }
    if let Some(rp) = &a.report {
        if let Err(e) = rep.write(rp) {
            eprintln!("cu2hip: report write: {e}");
            return 3;
        }
    }
    for d in &rep.diagnostics {
        eprintln!("{}: Unsupported[{}] at {}: {}", rep.input, d.feature, d.loc, d.hint);
    }
    code
}

fn batch(a: &Args) -> i32 {
    let tools = match resolve_tools(a) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("cu2hip: {e}");
            return 3;
        }
    };
    let out_dir = match &a.output {
        Some(o) => o.clone(),
        None => {
            eprintln!("cu2hip: batch mode requires -o <out-dir>");
            return 3;
        }
    };
    let _ = std::fs::create_dir_all(&out_dir);
    let rep_dir = a.report.clone();
    if let Some(rd) = &rep_dir {
        let _ = std::fs::create_dir_all(rd);
    }
    let mut files: Vec<PathBuf> = match std::fs::read_dir(&a.input) {
        Ok(rd) => rd
            .filter_map(|e| e.ok().map(|x| x.path()))
            .filter(|p| p.extension().map(|x| x == "cu").unwrap_or(false))
            .collect(),
        Err(e) => {
            eprintln!("cu2hip: batch dir: {e}");
            return 3;
        }
    };
    files.sort();
    if files.is_empty() {
        eprintln!("cu2hip: no .cu files in {}", a.input.to_string_lossy());
        return 3;
    }
    let arch = a.arch.clone();
    let tools_ref = &tools;
    let arch_ref = &arch;
    let results: Vec<(PathBuf, i32, u128, usize)> = std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for cu in &files {
            let stem = cu.file_stem().unwrap().to_string_lossy().into_owned();
            let hip = out_dir.join(format!("{stem}.hip"));
            let rep_path = rep_dir.clone().map(|d| d.join(format!("{stem}.json")));
            handles.push(scope.spawn(move || {
                let scratch = scratch_dir(&stem).expect("scratch");
                let t0 = std::time::Instant::now();
                let (rep, code) = transpile_one(tools_ref, arch_ref, cu, &hip, &scratch);
                let ndiag = rep.diagnostics.len();
                if let Some(rp) = rep_path {
                    let _ = rep.write(&rp);
                }
                (cu.clone(), code, t0.elapsed().as_millis(), ndiag)
            }));
        }
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });
    let mut bad = 0;
    for (cu, code, ms, ndiag) in &results {
        let ok = *code == a.expect_exit;
        if !ok {
            bad += 1;
        }
        println!(
            "{}: exit={} (expect {}) ms={} diags={} {}",
            cu.to_string_lossy(),
            code,
            a.expect_exit,
            ms,
            ndiag,
            if ok { "OK" } else { "FAIL" }
        );
    }
    if bad > 0 {
        eprintln!("cu2hip batch: {bad} file(s) missed expectations");
        return 1;
    }
    println!("cu2hip batch: all {} file(s) as expected", results.len());
    0
}

fn main() {
    let a = Args::parse();
    if a.batch && a.validate {
        eprintln!("cu2hip: --validate is single-mode only in v1");
        std::process::exit(3);
    }
    let code = if a.batch { batch(&a) } else { single(&a) };
    std::process::exit(code);
}
