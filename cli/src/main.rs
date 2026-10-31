mod analysis;
mod commands;
mod config;
mod model;
mod transport;
mod ui;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[tokio::main]
async fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args
        .iter()
        .any(|arg| matches!(arg.as_str(), "--help" | "-help" | "-h"))
    {
        print!("{}", config::HELP);
        return;
    }
    let args = if args.len() == 1 && matches!(args[0].as_str(), "--version" | "-version") {
        vec!["version".into()]
    } else {
        args
    };
    let config = match config::Config::parse(&args) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("gdobs: {error}");
            std::process::exit(2);
        }
    };
    let result = tokio::select! { result=commands::run(&config)=>result, signal=tokio::signal::ctrl_c()=>signal.map_err(Into::into) };
    if let Err(error) = result {
        eprintln!("gdobs: {error}");
        std::process::exit(1);
    }
}
