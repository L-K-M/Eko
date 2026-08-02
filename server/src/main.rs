//! Binary entry point. All behaviour lives in the library so the integration
//! tests drive the same router the server serves.

use eko_relay::{app, db, AppState, Config};
use std::net::SocketAddr;
use std::sync::Arc;

/// `--healthcheck` probes /readyz over loopback and exits 0 or 1, so the image
/// needs no curl and the container healthcheck exercises the database too.
fn healthcheck(bind: &str) -> ! {
    use std::io::{Read, Write};
    let port = bind.rsplit(':').next().unwrap_or("8080");
    let target = format!("127.0.0.1:{port}");
    let deadline = std::time::Duration::from_secs(3);
    let code = (|| -> Option<()> {
        let addr: SocketAddr = target.parse().ok()?;
        let mut stream = std::net::TcpStream::connect_timeout(&addr, deadline).ok()?;
        stream.set_read_timeout(Some(deadline)).ok()?;
        stream
            .write_all(b"GET /readyz HTTP/1.0\r\nHost: localhost\r\n\r\n")
            .ok()?;
        let mut buf = String::new();
        stream.read_to_string(&mut buf).ok()?;
        // hyper may answer 1.0 or 1.1; the status is what matters.
        (buf.starts_with("HTTP/1.0 200") || buf.starts_with("HTTP/1.1 200")).then_some(())
    })();
    std::process::exit(if code.is_some() { 0 } else { 1 });
}

#[tokio::main]
async fn main() {
    if std::env::args().any(|a| a == "--healthcheck") {
        healthcheck(&Config::from_env().bind);
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "eko_relay=info,tower_http=warn".into()),
        )
        .init();

    let config = Config::from_env();
    tracing::info!(
        bind = %config.bind,
        database = %config.database,
        retention_days = config.retention_days,
        "starting eko-relay"
    );

    let pool = match db::open(&config.database) {
        Ok(pool) => pool,
        Err(e) => {
            tracing::error!("cannot open database: {e}");
            std::process::exit(1);
        }
    };

    let state = AppState {
        pool: pool.clone(),
        config: Arc::new(config.clone()),
    };

    // Retention sweep. The relay's window is deliberately far longer than the
    // phone's 48 h; keeping it drained is the entire reliability argument.
    {
        let pool = pool.clone();
        let days = config.retention_days;
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(3600));
            loop {
                tick.tick().await;
                let pool = pool.clone();
                let removed =
                    tokio::task::spawn_blocking(move || eko_relay::routes::sweep(&pool, days))
                        .await
                        .unwrap_or(Ok(0))
                        .unwrap_or(0);
                if removed > 0 {
                    tracing::info!(removed, "retention sweep");
                }
            }
        });
    }

    let addr: SocketAddr = match config.bind.parse() {
        Ok(a) => a,
        Err(e) => {
            tracing::error!("bad EKO_BIND {}: {e}", config.bind);
            std::process::exit(1);
        }
    };

    let listener = match tokio::net::TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            tracing::error!("cannot bind {addr}: {e}");
            std::process::exit(1);
        }
    };
    tracing::info!("listening on {addr}");

    axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .ok();
}

/// Docker and Kubernetes send SIGTERM, not SIGINT. Listening only for ctrl_c
/// meant the relay never drained in production - it was killed at the end of
/// the termination grace period instead.
async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut sig) => {
                sig.recv().await;
            }
            // Losing the handler must not take the process with it; fall back
            // to ctrl_c being the only way out.
            Err(e) => {
                tracing::error!("cannot install SIGTERM handler: {e}");
                std::future::pending::<()>().await;
            }
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
    tracing::info!("shutting down");
}
