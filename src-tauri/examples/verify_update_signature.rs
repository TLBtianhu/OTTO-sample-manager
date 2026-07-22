use std::{env, error::Error, fs, io};

use base64::{Engine, engine::general_purpose::STANDARD};
use minisign_verify::{PublicKey, Signature};

fn invalid_input(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut arguments = env::args_os().skip(1);
    let config_path = arguments
        .next()
        .ok_or_else(|| invalid_input("missing Tauri config path"))?;
    let installer_path = arguments
        .next()
        .ok_or_else(|| invalid_input("missing installer path"))?;
    let signature_path = arguments
        .next()
        .ok_or_else(|| invalid_input("missing signature path"))?;
    if arguments.next().is_some() {
        return Err(invalid_input("unexpected extra argument").into());
    }

    let config: serde_json::Value = serde_json::from_slice(&fs::read(config_path)?)?;
    let public_key_encoded = config
        .pointer("/plugins/updater/pubkey")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| invalid_input("Tauri updater public key is missing"))?;
    let signature_encoded = fs::read_to_string(signature_path)?;
    let public_key_text = String::from_utf8(STANDARD.decode(public_key_encoded.trim())?)?;
    let signature_text = String::from_utf8(STANDARD.decode(signature_encoded.trim())?)?;
    let public_key = PublicKey::decode(&public_key_text)?;
    let signature = Signature::decode(&signature_text)?;
    let installer = fs::read(installer_path)?;

    public_key.verify(&installer, &signature, true)?;
    println!("signature valid");
    Ok(())
}
