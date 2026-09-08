use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=src/speaker_helper.swift");
    let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let dest = out.join("pods-speaker-helper");
    if env::var("CARGO_CFG_TARGET_OS").ok().as_deref() != Some("macos") {
        let _ = std::fs::write(&dest, []);
        return;
    }
    let status = Command::new("swiftc")
        .args([
            "-O",
            "-parse-as-library",
            "-target",
            default_target(),
            "-o",
            dest.to_str().expect("helper dest"),
            "src/speaker_helper.swift",
            "-framework",
            "AVFoundation",
            "-framework",
            "CoreMedia",
            "-framework",
            "Foundation",
        ])
        .status()
        .expect("swiftc must run to embed the Mac speaker helper");
    if !status.success() {
        panic!("swiftc failed to compile backend/src/speaker_helper.swift");
    }
}

fn default_target() -> &'static str {
    match env::var("CARGO_CFG_TARGET_ARCH").ok().as_deref() {
        Some("aarch64") => "arm64-apple-macosx13.0",
        _ => "x86_64-apple-macosx13.0",
    }
}
