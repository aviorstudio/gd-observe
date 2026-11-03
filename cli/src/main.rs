mod analysis;
mod commands;
mod config;
mod model;
mod transport;
mod ui;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[tokio::main]
async fn main() {
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    let global_json = args.first().is_some_and(|arg| arg == "--json");
    if global_json {
        args.remove(0);
    }
    let machine = global_json
        || args
            .iter()
            .take_while(|a| a.as_str() != "--")
            .any(|a| a == "--json");
    if args.first().is_some_and(|arg| arg == "help")
        || args
            .iter()
            .any(|arg| matches!(arg.as_str(), "--help" | "-help" | "-h"))
    {
        if machine {
            println!("{}", serde_json::json!({"help":config::HELP}));
        } else {
            print!("{}", config::HELP);
        }
        return;
    }
    let args = if args.len() == 1 && matches!(args[0].as_str(), "--version" | "-version") {
        vec!["version".into()]
    } else {
        args
    };
    let mut config = match config::Config::parse(&args) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("gdobs: {error}");
            if machine {
                println!(
                    "{}",
                    serde_json::json!({"ok":false,"error":{"code":"invalid_usage","message":error.to_string()}})
                );
            }
            std::process::exit(2);
        }
    };
    config.json |= global_json;
    if config.json && matches!(config.command.as_str(), "watch" | "stream") {
        println!(
            "{}",
            serde_json::json!({"ok":false,"error":{"code":"invalid_usage","message":"--json requires a finite command; watch uses Ratatui and stream uses JSON Lines"}})
        );
        std::process::exit(2);
    }
    let result = tokio::select! { result=commands::run(&config)=>result, signal=tokio::signal::ctrl_c()=>match signal { Ok(()) if config.json => Err("operation cancelled".into()), other => other.map_err(Into::into) } };
    if let Err(error) = result {
        eprintln!("gdobs: {error}");
        if config.json && !commands::output_emitted() {
            println!(
                "{}",
                serde_json::json!({"ok":false,"error":{"code":"operation_failed","message":error.to_string()}})
            );
        }
        std::process::exit(1);
    }
}
