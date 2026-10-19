use super::{handle_fs, handle_read_jobs_tick};
use crate::ipc::Data;
use hbb_common::tokio::{self, sync::mpsc::{UnboundedReceiver, UnboundedSender}};

// Called only after permanent-password authentication and file-transfer authorization.
// Keep this channel private to its connection; no additional IPC listener is exposed.
pub(crate) async fn run(
    mut rx: UnboundedReceiver<Data>,
    tx: UnboundedSender<Data>,
    conn_id: i32,
) {
    let mut write_jobs = Vec::new();
    let mut read_jobs = Vec::new();
    loop {
        let message = if read_jobs.is_empty() {
            rx.recv().await
        } else {
            tokio::select! {
                message = rx.recv() => message,
                _ = tokio::time::sleep(std::time::Duration::from_millis(5)) => {
                    if let Err(error) = handle_read_jobs_tick(&mut read_jobs, &tx, conn_id).await {
                        hbb_common::log::warn!("Service file transfer stopped: {}", error);
                        break;
                    }
                    continue;
                }
            }
        };
        match message {
            Some(Data::FS(operation)) => {
                handle_fs(operation, &mut write_jobs, &mut read_jobs, &tx, None, conn_id).await;
            }
            Some(Data::Close | Data::Disconnected) | None => break,
            _ => {}
        }
    }
}
