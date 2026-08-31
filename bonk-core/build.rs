fn main() {
    // Generate C header for Swift/FFI via cbindgen
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let bindings = cbindgen::Builder::new()
        .with_crate(crate_dir)
        .generate();

    match bindings {
        Ok(b) => {
            b.write_to_file("target/bonk_core.h");
            println!("cargo:rerun-if-changed=cbindgen.toml");
        }
        Err(e) => {
            // Don't fail build if cbindgen config missing - header is optional for now
            println!("cargo:warning=cbindgen failed: {:?}", e);
        }
    }
}
