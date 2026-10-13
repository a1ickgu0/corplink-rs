use std::ffi::{c_void, CStr, CString};
use std::time;

use anyhow::{anyhow, Context, Result};
use libc;

use crate::{config, utils};

#[allow(clippy::all)]
#[allow(
    dead_code,
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals
)]
mod libwg {
    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

fn start_wg(log_level: i32, protocol: i32, interface_name: &str) -> Result<i32> {
    let input_cstring = CString::new(interface_name.as_bytes()).context("buff contains null character")?;
    unsafe { Ok(libwg::startWg(log_level, protocol, input_cstring.as_ptr())) }
}

fn stop_wg() {
    unsafe {
        libwg::stopWg();
    }
}

fn uapi(buff: &[u8]) -> Result<Vec<u8>> {
    let input_cstring = CString::new(buff).context("buff contains null character")?;
    unsafe {
        let result_ptr = libwg::uapi(input_cstring.as_ptr());
        if result_ptr.is_null() {
            return Err(anyhow!("libwg::uapi() returned null pointer"));
        }
        let result = CStr::from_ptr(result_ptr).to_bytes().to_vec();
        libc::free(result_ptr as *mut c_void);
        Ok(result)
    }
}

pub fn stop_wg_go() {
    stop_wg();
}

/// 查询并打印 wg 隧道统计（收发字节数、最近握手时间），用于诊断保活失败时隧道数据面是否存活
pub fn log_wg_stats() {
    let data = match uapi(b"get=1\n\n") {
        Ok(d) => d,
        Err(e) => {
            log::warn!("failed to query uapi stats: {}", e);
            return;
        }
    };
    let s = String::from_utf8_lossy(&data);
    let mut tx = None;
    let mut rx = None;
    let mut handshake = None;
    for line in s.split('\n') {
        if let Some(v) = line.strip_prefix("transfer_tx=") {
            tx = Some(v.to_string());
        } else if let Some(v) = line.strip_prefix("transfer_rx=") {
            rx = Some(v.to_string());
        } else if let Some(v) = line.strip_prefix("last_handshake_time_sec=") {
            if let Ok(sec) = v.trim().parse::<i64>() {
                handshake = chrono::DateTime::from_timestamp(sec, 0)
                    .map(|t| t.with_timezone(&chrono::Local).format("%H:%M:%S").to_string());
            }
        }
    }
    log::warn!(
        "wg tunnel stats: tx={} bytes, rx={} bytes, last_handshake={}",
        tx.as_deref().unwrap_or("n/a"),
        rx.as_deref().unwrap_or("n/a"),
        handshake.as_deref().unwrap_or("none")
    );
}

pub fn set_performance_config(
    mtu: u32,
    keepalive_interval: u32,
    tcp_buffer_size: u32,
    socket_buffer_size: u32,
    batch_size: u32,
    queue_size: u32,
) {
    unsafe {
        libwg::setPerformanceConfig(mtu, keepalive_interval, tcp_buffer_size, socket_buffer_size, batch_size, queue_size);
    }
    log::info!(
        "Performance config set: MTU={}, Keepalive={}s, TCPBuf={}KB, SocketBuf={}KB, BatchSize={}, QueueSize={}",
        mtu, keepalive_interval, tcp_buffer_size / 1024, socket_buffer_size / 1024, batch_size, queue_size
    );
}

#[allow(dead_code)]
pub fn get_performance_config() -> (u32, u32, u32, u32, u32, u32) {
    unsafe {
        let result = libwg::getPerformanceConfig();
        (result.r0, result.r1, result.r2, result.r3, result.r4, result.r5)
    }
}

pub fn get_performance_metrics() -> (u64, u64, u64, u64) {
    unsafe {
        let result = libwg::getPerformanceMetrics();
        (result.r0, result.r1, result.r2, result.r3)
    }
}

/// 周期性输出隧道吞吐统计（聚合自 libwg 各 peer 的传输计数器），
/// 用于诊断数据面是否在转发流量以及吞吐水平。
pub fn log_wg_metrics() {
    let (tx_bytes, rx_bytes, tx_packets, rx_packets) = get_performance_metrics();
    log::info!(
        "wg tunnel metrics: tx={} bytes / {} packets, rx={} bytes / {} packets",
        tx_bytes,
        tx_packets,
        rx_bytes,
        rx_packets
    );
}

pub fn start_wg_go(name: &str, protocol: i32, with_log: bool) -> Result<()> {
    let protocol_str = match protocol {
        0 => "UDP",
        1 => "TCP",
        _ => "Unknown",
    };
    log::info!("start wg-corplink with protocol: {}", protocol_str);
    let mut log_level = libwg::LogLevelError;
    if with_log {
        log_level = libwg::LogLevelVerbose;
    }
    let ret = start_wg(log_level, protocol, name)?;
    if !matches!(ret, 0) {
        return Err(anyhow!("start_wg returned non-zero code: {ret}"));
    }
    log::info!("WireGuard started successfully with {} protocol", protocol_str);
    Ok(())
}

pub struct UAPIClient {
    pub name: String,
}

impl UAPIClient {
    pub async fn config_wg(&mut self, conf: &config::WgConf, perf_conf: Option<&config::PerformanceConfig>) -> Result<()> {
        let mut buff = String::from("set=1\n");
        let private_key = utils::b64_decode_to_hex(&conf.private_key)
            .context("failed to decode private key")?;
        let public_key = utils::b64_decode_to_hex(&conf.peer_key)
            .context("failed to decode peer key")?;
        buff.push_str(format!("private_key={private_key}\n").as_str());
        buff.push_str("replace_peers=true\n".to_string().as_str());
        buff.push_str(format!("public_key={public_key}\n").as_str());
        buff.push_str("replace_allowed_ips=true\n".to_string().as_str());
        buff.push_str(format!("endpoint={}\n", conf.peer_address).as_str());
        
        let keepalive_interval = perf_conf
            .and_then(|p| p.keepalive_interval)
            .unwrap_or(10);
        buff.push_str(format!("persistent_keepalive_interval={}\n", keepalive_interval).as_str());
        
        for route in &conf.route {
            if route.contains("/") {
                buff.push_str(format!("allowed_ip={route}\n").as_str());
            } else {
                buff.push_str(format!("allowed_ip={route}/32\n").as_str());
            }
        }

        let addr = &conf.address;
        let addr6 = &conf.address6;
        let mtu = perf_conf
            .and_then(|p| p.mtu)
            .unwrap_or(conf.mtu);
        buff.push_str(format!("address={addr}\n").as_str());
        if !addr6.is_empty() {
            buff.push_str(format!("address={addr6}\n").as_str());
        }
        buff.push_str(format!("mtu={mtu}\n").as_str());
        buff.push_str("up=true\n".to_string().as_str());
        for route in &conf.route {
            if route.contains("/") {
                buff.push_str(format!("route={route}\n").as_str());
            } else {
                let prefix_len = if route.contains(":") { 128 } else { 32 };
                buff.push_str(format!("route={route}/{prefix_len}\n").as_str());
            }
        }

        if let Some(perf) = perf_conf {
            let tcp_buf = perf.tcp_buffer_size.unwrap_or(256 * 1024);
            let socket_buf = perf.socket_buffer_size.unwrap_or(256 * 1024);
            let batch = perf.batch_size.unwrap_or(256);
            let queue = perf.queue_size.unwrap_or(8192);
            set_performance_config(mtu, keepalive_interval, tcp_buf, socket_buf, batch, queue);
        }

        buff.push('\n');
        log::info!("send config to uapi");
        let data = uapi(buff.as_bytes()).context("call uapi")?;
        let s = String::from_utf8(data).context("failed to decode uapi response")?;
        if !s.contains("errno=0") {
            return Err(anyhow!("uapi returns unexpected result: {}", s));
        }
        Ok(())
    }

    pub async fn check_wg_connection(&mut self) {
        let handshake_timeout = time::Duration::from_secs(45);
        let stale_interval = time::Duration::from_secs(5 * 60);
        let started = time::Instant::now();
        let mut verified = false;

        loop {
            // 首次握手需要及时确认；建立后按原来的 120 秒周期检查。
            let poll_interval = if verified {
                time::Duration::from_secs(120)
            } else {
                time::Duration::from_secs(2)
            };
            tokio::time::sleep(poll_interval).await;

            if verified {
                log_wg_metrics();
            }

            let name = self.name.as_str();
            let data = match uapi(b"get=1\n\n") {
                Ok(data) => data,
                Err(e) => {
                    log::warn!("failed to call uapi for {}: {}", name, e);
                    if !verified && started.elapsed() >= handshake_timeout {
                        return;
                    }
                    continue;
                }
            };
            let s = match String::from_utf8(data) {
                Ok(s) => s,
                Err(err) => {
                    log::warn!("failed to parse uapi response for {}: {}", name, err);
                    if !verified && started.elapsed() >= handshake_timeout {
                        return;
                    }
                    continue;
                }
            };
            let handshake = s
                .lines()
                .find_map(|line| line.strip_prefix("last_handshake_time_sec="))
                .and_then(|value| value.trim().parse::<i64>().ok());

            let Some(timestamp) = handshake else {
                if verified || started.elapsed() >= handshake_timeout {
                    log::warn!("no valid handshake time from {}, reconnecting", name);
                    return;
                }
                continue;
            };
            if timestamp == 0 {
                if verified || started.elapsed() >= handshake_timeout {
                    log::warn!(
                        "VPN handshake not established within {}s, reconnecting",
                        handshake_timeout.as_secs()
                    );
                    return;
                }
                continue;
            }
            let Some(handshake_at) = chrono::DateTime::from_timestamp(timestamp, 0) else {
                log::warn!("invalid handshake timestamp from {}, reconnecting", name);
                return;
            };
            let elapsed = chrono::Utc::now().signed_duration_since(handshake_at);
            if elapsed < chrono::Duration::zero()
                || elapsed > chrono::Duration::from_std(stale_interval).unwrap()
            {
                log::warn!("VPN handshake is stale or invalid, reconnecting");
                return;
            }

            if !verified {
                verified = true;
                log::info!("VPN handshake confirmed");
                crate::signal_gui_status("connected");
            }
        }
    }
}
