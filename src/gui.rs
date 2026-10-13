use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const MAX_REQUEST_SIZE: usize = 1_048_576;
const MAX_LOG_LINES: usize = 500;
const GUI_STATUS_PREFIX: &str = "[CORPLINK_GUI_STATUS] ";

#[derive(Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ConnectionStatus {
    Disconnected,
    Connecting,
    Verifying,
    Connected,
    Intranet,
    Stopping,
}

impl ConnectionStatus {
    fn from_signal(value: &str) -> Option<Self> {
        match value {
            "connecting" => Some(Self::Connecting),
            "verifying" => Some(Self::Verifying),
            "connected" => Some(Self::Connected),
            "intranet" => Some(Self::Intranet),
            _ => None,
        }
    }
}

#[derive(Clone)]
struct AppState {
    token: String,
    profiles_dir: PathBuf,
    default_config: PathBuf,
    runtime: Arc<Mutex<Runtime>>,
    shutdown: Arc<AtomicBool>,
}

struct Runtime {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    profile: Option<String>,
    status: ConnectionStatus,
    logs: VecDeque<String>,
    last_exit: Option<String>,
}

#[derive(Serialize)]
struct StateResponse {
    connected: bool,
    running: bool,
    status: ConnectionStatus,
    profile: Option<String>,
    profiles: Vec<String>,
    default_config_name: String,
    logs: Vec<String>,
    last_exit: Option<String>,
}

#[derive(Deserialize)]
struct SaveConfigRequest {
    name: String,
    content: String,
}

#[derive(Deserialize)]
struct StartRequest {
    name: String,
}

#[derive(Deserialize)]
struct InputRequest {
    value: String,
}

pub async fn run(config_override: Option<PathBuf>) -> anyhow::Result<()> {
    let config_root = app_config_dir();
    let profiles_dir = config_root.join("profiles");
    fs::create_dir_all(&profiles_dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&config_root, fs::Permissions::from_mode(0o700))?;
        fs::set_permissions(&profiles_dir, fs::Permissions::from_mode(0o700))?;
    }

    let current_default = std::env::current_dir()?.join("config.json");
    let default_config = config_override.unwrap_or_else(|| {
        if current_default.is_file() {
            current_default
        } else {
            profiles_dir.join("default.json")
        }
    });

    let token = std::env::var("CORPLINK_GUI_TOKEN").unwrap_or_else(|_| random_token());
    let bind_address = match std::env::var("CORPLINK_GUI_PORT") {
        Ok(port) => format!("127.0.0.1:{port}"),
        Err(_) => "127.0.0.1:0".to_string(),
    };
    let listener = TcpListener::bind(&bind_address).await?;
    let address = listener.local_addr()?;
    let state = AppState {
        token: token.clone(),
        profiles_dir,
        default_config,
        runtime: Arc::new(Mutex::new(Runtime {
            child: None,
            stdin: None,
            profile: None,
            status: ConnectionStatus::Disconnected,
            logs: VecDeque::new(),
            last_exit: None,
        })),
        shutdown: Arc::new(AtomicBool::new(false)),
    };

    println!("CorpLink GUI: http://{address}/?token={token}");
    println!("仅本机可访问。保持此终端运行即可使用管理界面；按 Ctrl+C 退出。");

    while !state.shutdown.load(Ordering::SeqCst) {
        let accepted =
            tokio::time::timeout(std::time::Duration::from_millis(500), listener.accept()).await;
        let Ok(accepted) = accepted else { continue };
        let (stream, peer) = accepted?;
        if !peer.ip().is_loopback() {
            continue;
        }
        let state = state.clone();
        tokio::spawn(async move {
            if let Err(error) = handle_connection(stream, state).await {
                log::debug!("GUI request failed: {error}");
            }
        });
    }
    Ok(())
}

fn app_config_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("CORPLINK_GUI_HOME") {
        return PathBuf::from(path);
    }
    #[cfg(target_os = "macos")]
    let root = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("Library/Application Support");
    #[cfg(target_os = "windows")]
    let root = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("USERPROFILE").map(PathBuf::from))
        .unwrap_or_else(std::env::temp_dir);
    #[cfg(all(unix, not(target_os = "macos")))]
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_else(std::env::temp_dir);

    root.join("corplink-rs")
}

fn random_token() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

async fn handle_connection(mut stream: TcpStream, state: AppState) -> anyhow::Result<()> {
    let mut request = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    let mut header_end;
    let mut content_length;
    loop {
        if request.len() >= MAX_REQUEST_SIZE {
            return write_response(
                &mut stream,
                413,
                "application/json",
                "{\"error\":\"request too large\"}",
            )
            .await;
        }
        let count = stream.read(&mut chunk).await?;
        if count == 0 {
            return Ok(());
        }
        request.extend_from_slice(&chunk[..count]);
        if let Some(index) = find_bytes(&request, b"\r\n\r\n") {
            header_end = index + 4;
            let headers = String::from_utf8_lossy(&request[..index]);
            content_length = headers
                .lines()
                .filter_map(|line| line.split_once(':'))
                .find(|(key, _)| key.eq_ignore_ascii_case("content-length"))
                .and_then(|(_, value)| value.trim().parse::<usize>().ok())
                .unwrap_or(0);
            if header_end + content_length <= request.len() {
                break;
            }
        }
    }
    if header_end + content_length > MAX_REQUEST_SIZE {
        return write_response(
            &mut stream,
            413,
            "application/json",
            "{\"error\":\"request too large\"}",
        )
        .await;
    }

    let header = String::from_utf8_lossy(&request[..header_end - 4]);
    let mut lines = header.lines();
    let Some(first_line) = lines.next() else {
        return Ok(());
    };
    let mut parts = first_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let headers: Vec<(&str, &str)> = lines.filter_map(|line| line.split_once(':')).collect();
    let authorized = headers.iter().any(|(key, value)| {
        key.eq_ignore_ascii_case("authorization")
            && value.trim() == format!("Bearer {}", state.token)
    });
    let path = target.split('?').next().unwrap_or("/");

    if method == "GET" && path == "/" {
        if query_value(target, "token").as_deref() != Some(state.token.as_str()) {
            return write_response(
                &mut stream,
                401,
                "application/json",
                "{\"error\":\"unauthorized\"}",
            )
            .await;
        }
        let token_script = format!(
            "<script>window.CORPLINK_TOKEN={}</script>",
            serde_json::to_string(&state.token)?
        );
        let html = APP_HTML.replace("</head>", &format!("{token_script}</head>"));
        return write_response(&mut stream, 200, "text/html; charset=utf-8", &html).await;
    }
    if !authorized {
        return write_response(
            &mut stream,
            401,
            "application/json",
            "{\"error\":\"unauthorized\"}",
        )
        .await;
    }

    let body = &request[header_end..header_end + content_length];
    match (method, path) {
        ("GET", "/api/state") => {
            let result = state_response(&state)?;
            write_json(&mut stream, &result).await
        }
        ("GET", "/api/config") => {
            let name = query_value(target, "name").unwrap_or_else(|| "default".to_string());
            match profile_path(&state, &name)
                .and_then(|path| fs::read_to_string(path).map_err(anyhow::Error::from))
            {
                Ok(content) => {
                    write_json(
                        &mut stream,
                        &serde_json::json!({"name": name, "content": content}),
                    )
                    .await
                }
                Err(error) => write_error(&mut stream, 404, &error.to_string()).await,
            }
        }
        ("POST", "/api/config") => {
            let request: SaveConfigRequest = match serde_json::from_slice(body) {
                Ok(value) => value,
                Err(error) => {
                    return write_error(&mut stream, 400, &format!("JSON 格式错误: {error}")).await
                }
            };
            let path = match profile_path(&state, &request.name) {
                Ok(path) => path,
                Err(error) => return write_error(&mut stream, 400, &error.to_string()).await,
            };
            let parsed: serde_json::Value = match serde_json::from_str(&request.content) {
                Ok(value) => value,
                Err(error) => {
                    return write_error(&mut stream, 400, &format!("配置不是有效 JSON: {error}"))
                        .await
                }
            };
            if !parsed.is_object() {
                return write_error(&mut stream, 400, "配置必须是 JSON 对象").await;
            }
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::write(
                &path,
                format!("{}\n", serde_json::to_string_pretty(&parsed)?),
            )?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
            }
            write_json(&mut stream, &serde_json::json!({"ok": true})).await
        }
        ("POST", "/api/start") => {
            let request: StartRequest = match serde_json::from_slice(body) {
                Ok(value) => value,
                Err(error) => {
                    return write_error(&mut stream, 400, &format!("请求错误: {error}")).await
                }
            };
            let config = match profile_path(&state, &request.name) {
                Ok(path) if path.is_file() => path,
                Ok(_) => {
                    return write_error(&mut stream, 404, "配置文件不存在，请先保存配置").await
                }
                Err(error) => return write_error(&mut stream, 400, &error.to_string()).await,
            };
            let config_content = match fs::read_to_string(&config) {
                Ok(content) => content,
                Err(error) => return write_error(&mut stream, 400, &error.to_string()).await,
            };
            let config_value: serde_json::Value = match serde_json::from_str(&config_content) {
                Ok(value) => value,
                Err(error) => {
                    return write_error(&mut stream, 400, &format!("配置 JSON 无效: {error}")).await
                }
            };
            if config_value
                .get("company_name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .is_empty()
                || config_value
                    .get("username")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .is_empty()
            {
                return write_error(&mut stream, 400, "连接前请填写 company_name 和 username")
                    .await;
            }
            match start_client(&state, &request.name, config) {
                Ok(()) => write_json(&mut stream, &serde_json::json!({"ok": true})).await,
                Err(error) => write_error(&mut stream, 409, &error).await,
            }
        }
        ("POST", "/api/stop") => match stop_client(state.clone()).await {
            Ok(()) => write_json(&mut stream, &serde_json::json!({"ok": true})).await,
            Err(error) => write_error(&mut stream, 500, &error).await,
        },
        ("POST", "/api/input") => {
            let request: InputRequest = match serde_json::from_slice(body) {
                Ok(value) => value,
                Err(error) => {
                    return write_error(&mut stream, 400, &format!("请求错误: {error}")).await
                }
            };
            if request.value.len() > 256
                || request.value.contains('\n')
                || request.value.contains('\r')
            {
                return write_error(&mut stream, 400, "验证码长度或格式不正确").await;
            }
            let result: Result<(), String> = state
                .runtime
                .lock()
                .map_err(|_| "运行状态锁定失败".to_string())
                .and_then(|mut runtime| match runtime.stdin.as_mut() {
                    Some(stdin) => writeln!(stdin, "{}", request.value)
                        .map_err(|error| format!("发送验证码失败: {error}")),
                    None => Err("当前没有等待输入的客户端".to_string()),
                });
            match result {
                Ok(()) => write_json(&mut stream, &serde_json::json!({"ok": true})).await,
                Err(error) => write_error(&mut stream, 409, &error).await,
            }
        }
        ("POST", "/api/shutdown") => {
            if let Err(error) = stop_client(state.clone()).await {
                return write_error(&mut stream, 500, &error).await;
            }
            state.shutdown.store(true, Ordering::SeqCst);
            write_json(&mut stream, &serde_json::json!({"ok": true})).await
        }
        _ => write_error(&mut stream, 404, "接口不存在").await,
    }
}

fn profile_path(state: &AppState, name: &str) -> anyhow::Result<PathBuf> {
    if name == "default" {
        return Ok(state.default_config.clone());
    }
    if name.is_empty()
        || name.len() > 48
        || !name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        anyhow::bail!("配置名称仅支持 1 到 48 位英文字母、数字、连字符和下划线");
    }
    Ok(state.profiles_dir.join(format!("{name}.json")))
}

fn profiles(state: &AppState) -> anyhow::Result<Vec<String>> {
    let mut result = vec!["default".to_string()];
    for entry in fs::read_dir(&state.profiles_dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) == Some("json") {
            if let Some(name) = path.file_stem().and_then(|stem| stem.to_str()) {
                if name != "default"
                    && name
                        .chars()
                        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
                {
                    result.push(name.to_string());
                }
            }
        }
    }
    result.sort();
    result.dedup();
    Ok(result)
}

fn state_response(state: &AppState) -> anyhow::Result<StateResponse> {
    let mut runtime = state
        .runtime
        .lock()
        .map_err(|_| anyhow::anyhow!("运行状态锁定失败"))?;
    if let Some(child) = runtime.child.as_mut() {
        if let Some(status) = child.try_wait()? {
            runtime.last_exit = Some(match status.code() {
                Some(0) => "客户端已结束".to_string(),
                Some(code) => format!("客户端已退出（退出码 {code}）"),
                None => "客户端已意外停止".to_string(),
            });
            runtime.child = None;
            runtime.stdin = None;
            runtime.profile = None;
            runtime.status = ConnectionStatus::Disconnected;
        }
    }
    Ok(StateResponse {
        connected: runtime.status == ConnectionStatus::Connected,
        running: runtime.child.is_some() || runtime.status == ConnectionStatus::Stopping,
        status: runtime.status,
        profile: runtime.profile.clone(),
        profiles: profiles(state)?,
        default_config_name: state
            .default_config
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "默认配置".to_string()),
        logs: runtime.logs.iter().cloned().collect(),
        last_exit: runtime.last_exit.clone(),
    })
}

fn start_client(state: &AppState, name: &str, config: PathBuf) -> Result<(), String> {
    let mut runtime = state
        .runtime
        .lock()
        .map_err(|_| "运行状态锁定失败".to_string())?;
    let already_running = match runtime.child.as_mut() {
        Some(child) => child
            .try_wait()
            .map(|status| status.is_none())
            .unwrap_or(true),
        None => false,
    };
    if already_running || runtime.status == ConnectionStatus::Stopping {
        return Err("客户端已经在运行".to_string());
    }
    runtime.child = None;
    runtime.stdin = None;
    runtime.profile = None;
    runtime.status = ConnectionStatus::Disconnected;
    runtime.logs.clear();
    runtime.last_exit = None;
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let mut child = Command::new(executable)
        .arg(&config)
        .env("CORPLINK_GUI_STATE_SIGNAL", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("无法启动客户端: {error}"))?;

    runtime.status = ConnectionStatus::Connecting;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    runtime.stdin = child.stdin.take();
    let logs = state.runtime.clone();
    // flexi_logger writes INFO, WARN and ERROR to stderr and includes the
    // actual level in each line. A stream-based [ERR] prefix mislabels INFO.
    for stream in [
        stdout.map(|s| Box::new(s) as Box<dyn std::io::Read + Send>),
        stderr.map(|s| Box::new(s) as Box<dyn std::io::Read + Send>),
    ] {
        if let Some(stream) = stream {
            let logs = logs.clone();
            std::thread::spawn(move || {
                for line in BufReader::new(stream).lines().flatten() {
                    if let Ok(mut runtime) = logs.lock() {
                        if let Some(signal) = line.strip_prefix(GUI_STATUS_PREFIX) {
                            if runtime.child.is_some()
                                && runtime.status != ConnectionStatus::Stopping
                            {
                                if let Some(status) = ConnectionStatus::from_signal(signal) {
                                    runtime.status = status;
                                }
                            }
                            continue;
                        }
                        runtime.logs.push_back(line);
                        while runtime.logs.len() > MAX_LOG_LINES {
                            runtime.logs.pop_front();
                        }
                    }
                }
            });
        }
    }
    runtime.profile = Some(name.to_string());
    runtime.child = Some(child);
    runtime.logs.push_back(format!("[GUI] 启动配置 {name}"));
    Ok(())
}

async fn stop_client(state: AppState) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let mut child = {
            let mut runtime = state
                .runtime
                .lock()
                .map_err(|_| "运行状态锁定失败".to_string())?;
            runtime.stdin = None;
            let Some(child) = runtime.child.take() else {
                runtime.profile = None;
                runtime.status = ConnectionStatus::Disconnected;
                return Ok(());
            };
            runtime.status = ConnectionStatus::Stopping;
            runtime.logs.push_back("[GUI] 正在停止客户端…".to_string());
            child
        };
        #[cfg(unix)]
        unsafe {
            libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
        }
        #[cfg(windows)]
        child
            .kill()
            .map_err(|error| format!("停止客户端失败: {error}"))?;
        let mut status = None;
        for _ in 0..30 {
            match child.try_wait() {
                Ok(Some(exit_status)) => {
                    status = Some(exit_status);
                    break;
                }
                Ok(None) => std::thread::sleep(std::time::Duration::from_millis(100)),
                Err(error) => return Err(format!("检查客户端退出状态失败: {error}")),
            }
        }
        let exit_status = match status {
            Some(status) => status,
            None => {
                child
                    .kill()
                    .map_err(|error| format!("强制停止客户端失败: {error}"))?;
                child
                    .wait()
                    .map_err(|error| format!("等待客户端退出失败: {error}"))?
            }
        };
        {
            let mut runtime = state
                .runtime
                .lock()
                .map_err(|_| "运行状态锁定失败".to_string())?;
            runtime.profile = None;
            runtime.status = ConnectionStatus::Disconnected;
            runtime.last_exit = Some(match exit_status.code() {
                Some(code) if code != 0 => format!("客户端已停止（退出码 {code}）"),
                _ => "客户端已断开".to_string(),
            });
            runtime.logs.push_back("[GUI] 客户端已停止".to_string());
        }
        Ok(())
    })
    .await
    .map_err(|error| error.to_string())?
}

fn query_value(target: &str, key: &str) -> Option<String> {
    target.split_once('?')?.1.split('&').find_map(|pair| {
        let (candidate, value) = pair.split_once('=')?;
        (candidate == key).then(|| value.replace('+', " "))
    })
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

async fn write_json<T: Serialize>(stream: &mut TcpStream, value: &T) -> anyhow::Result<()> {
    write_response(
        stream,
        200,
        "application/json; charset=utf-8",
        &serde_json::to_string(value)?,
    )
    .await
}

async fn write_error(stream: &mut TcpStream, status: u16, message: &str) -> anyhow::Result<()> {
    write_response(
        stream,
        status,
        "application/json; charset=utf-8",
        &serde_json::json!({"error": message}).to_string(),
    )
    .await
}

async fn write_response(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &str,
) -> anyhow::Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        409 => "Conflict",
        413 => "Payload Too Large",
        _ => "Internal Server Error",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
        body.as_bytes().len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(body.as_bytes()).await?;
    stream.shutdown().await?;
    Ok(())
}

const APP_HTML: &str = include_str!("gui.html");
