use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let out = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets the manifest"));
    let source = manifest.join("../c/coverage.c");
    let object = out.join("coverage.o");
    let archive = out.join("libdstcoverage.a");
    let compiler = env::var("CC").unwrap_or_else(|_| "cc".to_string());

    let compiled = Command::new(&compiler)
        .args(["-std=c11", "-O2", "-fPIC", "-c"])
        .arg(&source)
        .arg("-o")
        .arg(&object)
        .status()
        .expect("the C compiler runs");

    assert!(compiled.success(), "the coverage shim compiles");

    let archived = Command::new("ar")
        .arg("crs")
        .arg(&archive)
        .arg(&object)
        .status()
        .expect("ar runs");

    assert!(archived.success(), "the coverage shim archives");

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=dstcoverage");
    println!("cargo:rerun-if-changed={}", source.display());
}
