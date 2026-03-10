use std::env;
use std::path::PathBuf;

fn main() {
    let keystone_sdk = env::var("KEYSTONE_SDK")
        .unwrap_or_else(|_| "../keystone/sdk".to_string());

    let include_root = format!("{}/include", keystone_sdk);
    let include_host = format!("{}/include/host", keystone_sdk);
    let lib_dir      = format!("{}/lib", keystone_sdk);

    // Compile the thin C++ wrapper around the Keystone C++ API.
    cc::Build::new()
        .cpp(true)
        .file("keystone_wrapper.cpp")
        .include(&include_root)
        .include(&include_host)
        .include("../enclave")
        .flag("-std=c++14")
        .flag("-O2")
        .compile("keystone_wrapper");

    // Link the Keystone host library (prefer libkeystone-host.a, fall back to libkeystone.a).
    println!("cargo:rustc-link-search=native={}", lib_dir);
    let lib_host = PathBuf::from(format!("{}/libkeystone-host.a", lib_dir));
    let lib_ks   = PathBuf::from(format!("{}/libkeystone.a",      lib_dir));
    if lib_host.exists() {
        println!("cargo:rustc-link-lib=static=keystone-host");
    } else if lib_ks.exists() {
        println!("cargo:rustc-link-lib=static=keystone");
    } else {
        // Default — user must ensure the library is present at build time.
        println!("cargo:rustc-link-lib=static=keystone-host");
    }

    println!("cargo:rustc-link-lib=pthread");
    println!("cargo:rustc-link-lib=stdc++");

    println!("cargo:rerun-if-changed=keystone_wrapper.cpp");
    println!("cargo:rerun-if-changed=keystone_wrapper.hpp");
    println!("cargo:rerun-if-changed=../enclave/common.h");
    println!("cargo:rerun-if-env-changed=KEYSTONE_SDK");
}
