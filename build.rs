use std::{path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=DEVELOPER_DIR");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") { return; }
    // whisper's Objective-C availability checks need Clang's runtime when
    // targeting an older macOS. rustc links with -nodefaultlibs, unlike swiftc.
    let output = Command::new("xcrun").args(["clang", "--print-resource-dir"])
        .output().expect("Xcode command line tools are required");
    assert!(output.status.success(), "could not locate Clang runtime");
    let root = String::from_utf8(output.stdout).expect("Clang resource directory");
    let dir = PathBuf::from(root.trim()).join("lib/darwin");
    assert!(dir.join("libclang_rt.osx.a").is_file(), "Clang macOS runtime missing");
    println!("cargo:rustc-link-search=native={}", dir.display());
    println!("cargo:rustc-link-lib=static=clang_rt.osx");
}
