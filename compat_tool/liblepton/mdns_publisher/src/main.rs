use std::collections::HashMap;
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use clap::{Arg, ArgAction, ArgGroup, Command};

fn parse_txt_record(raw: &str) -> Result<(String, Vec<u8>), String> {
    match raw.split_once('=') {
        Some((key, value)) => Ok((key.to_string(), value.as_bytes().to_vec())),
        None => Err(format!("TXT record '{}' is not in 'key=value' form", raw)),
    }
}

/// Builds the D-Bus object path systemd-resolved uses for a registered service id, escaping it
/// the same way as sd_bus_path_encode(): [A-Za-z0-9] verbatim, every other byte as "_xx".
fn service_object_path(id: &str) -> String {
    let mut path = String::from("/org/freedesktop/resolve1/dnssd/");
    if id.is_empty() {
        path.push('_');
    }
    for b in id.bytes() {
        if b.is_ascii_alphanumeric() {
            path.push(b as char);
        } else {
            path.push_str(&format!("_{:02x}", b));
        }
    }
    path
}

/// Returns the major version of the running systemd (e.g. 255 for "255.4-1ubuntu8"), if known.
fn systemd_version(connection: &zbus::blocking::Connection) -> Option<u32> {
    let reply = connection
        .call_method(
            Some("org.freedesktop.systemd1"),
            "/org/freedesktop/systemd1",
            Some("org.freedesktop.DBus.Properties"),
            "Get",
            &("org.freedesktop.systemd1.Manager", "Version"),
        )
        .ok()?;
    let version: zbus::zvariant::OwnedValue = reply.body().deserialize().ok()?;
    let version: String = version.try_into().ok()?;
    parse_major_version(&version)
}

fn parse_major_version(version: &str) -> Option<u32> {
    let version = version.trim_start_matches('v');
    let end = version.find(|c: char| !c.is_ascii_digit()).unwrap_or(version.len());
    version[..end].parse().ok()
}

fn main() -> ExitCode {
    let matches = Command::new("lepton-mdns-publish")
        .version("1.0")
        .about("Publishes or unpublishes a DNS-SD/mDNS service via systemd-resolved")
        .arg(
            Arg::new("publish")
                .long("publish")
                .help("Register the service with systemd-resolved")
                .action(ArgAction::SetTrue),
        )
        .arg(
            Arg::new("unpublish")
                .long("unpublish")
                .help("Unregister the service previously published under NAME")
                .action(ArgAction::SetTrue),
        )
        .group(ArgGroup::new("mode").args(["publish", "unpublish"]).required(true))
        .arg(
            Arg::new("name")
                .help("The DNS-SD service instance name, e.g. 'lepton-foo'")
                .required(true)
                .index(1),
        )
        .arg(
            Arg::new("type")
                .help("The DNS-SD service type, e.g. '_adb._tcp' (--publish only)")
                .required_if_eq("publish", "true")
                .conflicts_with("unpublish")
                .index(2),
        )
        .arg(
            Arg::new("port")
                .help("The TCP/UDP port the service is reachable on (--publish only)")
                .required_if_eq("publish", "true")
                .index(3),
        )
        .arg(
            Arg::new("txt")
                .help("A 'key=value' TXT record to attach to the service; may be given multiple times (--publish only)")
                .action(ArgAction::Append)
                .index(4),
        )
        .get_matches();

    let name = matches.get_one::<String>("name").unwrap();

    let connection = match zbus::blocking::Connection::system() {
        Ok(connection) => connection,
        Err(e) => {
            eprintln!("Failed to connect to the D-Bus system bus: {}", e);
            return ExitCode::FAILURE;
        }
    };

    if matches.get_flag("unpublish") {
        // The service was registered with id = name; see RegisterService below.
        let path = match zbus::zvariant::ObjectPath::try_from(service_object_path(name)) {
            Ok(path) => path,
            Err(e) => {
                eprintln!("Invalid service name '{}': {}", name, e);
                return ExitCode::FAILURE;
            }
        };
        if let Err(e) = connection.call_method(
            Some("org.freedesktop.resolve1"),
            "/org/freedesktop/resolve1",
            Some("org.freedesktop.resolve1.Manager"),
            "UnregisterService",
            &(path,),
        ) {
            eprintln!("Failed to unregister '{}' from systemd-resolved: {}", name, e);
            return ExitCode::FAILURE;
        }
        return ExitCode::SUCCESS;
    }

    let service_type = matches.get_one::<String>("type").unwrap();
    let port: u16 = match matches.get_one::<String>("port").unwrap().parse() {
        Ok(port) => port,
        Err(e) => {
            eprintln!("Invalid port: {}", e);
            return ExitCode::FAILURE;
        }
    };

    let mut txt_record = HashMap::new();
    for raw in matches.get_many::<String>("txt").unwrap_or_default() {
        match parse_txt_record(raw) {
            Ok((key, value)) => {
                txt_record.insert(key, value);
            }
            Err(e) => {
                eprintln!("{}", e);
                return ExitCode::FAILURE;
            }
        }
    }

    // RegisterService(id, name_template, type, port, priority, weight, txt_datas) -> service_path
    // See org.freedesktop.resolve1(5).
    let body = (
        name.as_str(),
        name.as_str(),
        service_type.as_str(),
        port,
        0u16,
        0u16,
        vec![txt_record],
    );

    if let Err(e) = connection.call_method(
        Some("org.freedesktop.resolve1"),
        "/org/freedesktop/resolve1",
        Some("org.freedesktop.resolve1.Manager"),
        "RegisterService",
        &body,
    ) {
        eprintln!("Failed to register '{}' with systemd-resolved: {}", name, e);
        return ExitCode::FAILURE;
    }

    // systemd-resolved before v262 keeps the service after we disconnect, so we can exit.
    // From v262 on it withdraws the service as soon as the D-Bus connection that registered it
    // closes, so stay alive (keeping `connection` open) until our caller kills us. If the
    // version can't be determined, stay alive too, to be safe.
    if !matches!(systemd_version(&connection), Some(version) if version < 262) {
        loop {
            thread::sleep(Duration::from_secs(u64::MAX));
        }
    }

    ExitCode::SUCCESS
}

