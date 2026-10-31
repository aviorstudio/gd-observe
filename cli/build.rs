use std::{env, process::Command};

fn main() {
    for name in ["VERSION", "COMMIT", "DATE"] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    let commit = env::var("COMMIT")
        .ok()
        .or_else(|| {
            let output = Command::new("git")
                .args(["rev-parse", "HEAD"])
                .output()
                .ok()?;
            output
                .status
                .success()
                .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        })
        .unwrap_or_else(|| "unknown".into());
    for (key, value) in [
        (
            "GDOBS_VERSION",
            env::var("VERSION").unwrap_or_else(|_| "dev".into()),
        ),
        ("GDOBS_COMMIT", commit),
        (
            "GDOBS_DATE",
            env::var("DATE").unwrap_or_else(|_| "unknown".into()),
        ),
    ] {
        assert!(!value.contains(['\n', '\r']), "invalid build identity");
        println!("cargo:rustc-env={key}={value}");
    }
    println!("cargo:rerun-if-changed=../.git");
}
