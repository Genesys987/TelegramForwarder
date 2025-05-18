// Solana Sandwich Bot – Ultimate MEV Engine
// =============================================================================
// Features:
//  - Coin-sharded Monitoring: párhuzamos tokengyűrűk követése minden szálon
//  - WebSocket Pool Detection: valós idejű swap/addLiquidity események érzékelése
//  - Priority Tip Bidding: dinamikus computeUnitPrice emelés sikertelen tranzakciók után
//  - Liquidity-Based Route Selection: 1-hop vs. 2-hop útvonal döntés pool likviditás alapján
//  - Jupiter Swap Caching: Jupiter API hívások cache-elése 3 s TTL-lel a gyorsításért
//  - Jito Bundle Submission: front+target+back tranzakciók bundle-ként privát relay-be küldése
//  - Real-Time Backtest Logging: minden bundle-örmény logolása fájlba részletes paraméterekkel
//  - Telegram Alerts: sikeres éles bundle indításról értesítés Telegramon
// =============================================================================

use std::{
    collections::HashMap,            // Cache tárolása: kulcs->(base64Tx, timestamp)
    fs::OpenOptions,                 // Log fájl megnyitás append módban
    io::Write,                       // Log üzenetek írása
    path::Path,                      // Trigger flag fájl meglétének ellenőrzése
    sync::atomic::{AtomicU64, Ordering}, // Atomikus tipp számláló versenyhelyzethez
    thread,                          // Szálak indítása WebSocket és monitorozás számára
    time::{Duration, SystemTime, UNIX_EPOCH}, // Időbélyegek, sleep
};
use rayon::prelude::*;            // `par_iter()` párhuzamos token monitor futtatáshoz
use tungstenite::connect;         // WebSocket kliens pool eseményekhez
use url::Url;                     // WebSocket URL-ek parse-olása

use reqwest::blocking::Client;   // HTTP kliens Jupiter és Jito API hívásokhoz
use serde_json::Value;            // JSON választípusok kezelése
use base64;                       // Base64 kódolt tranzakció dekódolása
use bincode;                      // Bincode formátum deserialize a `Transaction`-höz
use chrono::Local;                // Időbélyeg a log sorokhoz
use solana_client::rpc_client::RpcClient; // Solana RPC kliens
use solana_sdk::{
    commitment_config::CommitmentConfig, // RPC Confirmed commitment
    signature::{Keypair, Signer},        // Wallet aláíró kulcsok kezelése
    transaction::Transaction,             // Solana tranzakció típus
};

// === Configuration constants ===
const RPC_URL: &str = "https://rpc.ironforge.network/YOUR_ENDPOINT";  // Privát Solana RPC
const SLIPPAGE_BPS: u16 = 500;                                          // slippage: 5.00%
const USDC_MINT: &str = "Es9vMFrzaCERCLQxZhvY2Jt2eycB4D2vrT1MAjCjKDXk"; // USDC token mint
const JUPITER_API_URL: &str = "https://quote-api.jup.ag/v6/swap";      // Jupiter Quote API
const TELEGRAM_ALERT_HOOK: &str = "https://api.telegram.org/bot<token>/sendMessage?chat_id=<chat_id>&text="; // Bot webhook prefix
const SIMULATION_MODE: bool = true;                                      // Ha true: nem küld élő tranzakciót
const LIQUIDITY_THRESHOLD: f64 = 1000.0;                                 // Pool likviditás limit 1-hop/2-hop döntéshez
const JUPITER_CACHE_TTL_MS: u64 = 3000;                                  // Cache élettartam 3000 ms
static PRIORITY_BASE: AtomicU64 = AtomicU64::new(300_000);               // Alap tipérték (300k µLamports)
static mut JUPITER_CACHE: Option<HashMap<String, (String, u64)>> = None;  // Globális Jupiter cache

// Monitored tokens (példa memecoin minta)
static MINTS: [&str; 3] = [
    "DezX...BONK",   // BONK token mint
    "GJwrR...WENQ",  // WEN token mint
    "HtNha...HADES", // HADES token mint
];

fn main() {
    // RPC és wallet inicializálása
    let client = RpcClient::new_with_commitment(RPC_URL.to_string(), CommitmentConfig::confirmed());
    let payer = Keypair::from_base58_string("PASTE_YOUR_PRIVATE_KEY_BASE58_HERE");
    println!("🧠 SandwichBot-ULTRA LAUNCHED | {}", Local::now());

    // WebSocket pool eseményfigyelő indítása háttérszálban
    thread::spawn(listen_to_pool_activity);

    // Párhuzamos tokenciklus: minden tokenre külön szál
    MINTS.par_iter().for_each(|&token_mint| {
        let client_clone = client.clone();
        let payer_clone = payer.clone();
        run_token_monitor(token_mint.to_string(), client_clone, payer_clone);
    });
}

/// Fő monitor loop egy adott tokenre
/// - Ellenőrzi a trigger flag-et
/// - Dinamikus tip kiszámítása
/// - Sandwich bundle generálás és küldés/logolás
fn run_token_monitor(token_mint: String, client: RpcClient, payer: Keypair) {
    loop {
        if detect_victim_activity() {
            let now = Local::now();
            let tip = estimate_tip(); // adaptív tipp
            if let Some((front_tx, back_tx, est_profit)) = create_sandwich_bundle(&client, &payer, tip, &token_mint) {
                if SIMULATION_MODE {
                    // Log simulation esetén: paraméterek + becsült profit
                    log_event(&format!(
                        "{} [SIM] {} | F:{} instr | B:{} instr | Tip:{} | EstP/L:{:.4} USDC",
                        now.format("%Y-%m-%d %H:%M:%S"), token_mint,
                        front_tx.message.instructions.len(), back_tx.message.instructions.len(), tip, est_profit
                    ));
                } else {
                    // Élő futtatás: küldés Jito bundle-rel, log, Telegram
                    send_jito_bundle(front_tx.clone(), back_tx.clone());
                    log_event(&format!(
                        "{} ✅ LIVE {} | F:{} instr | B:{} instr | Tip:{} | EstP/L:{:.4} USDC",
                        now.format("%Y-%m-%d %H:%M:%S"), token_mint,
                        front_tx.message.instructions.len(), back_tx.message.instructions.len(), tip, est_profit
                    ));
                    send_telegram_alert(&format!(
                        "📈 {} bundle sent | Tip: {} | EstP/L:{:.4} USDC",
                        token_mint, tip, est_profit
                    ));
                }
            }
        }
        thread::sleep(Duration::from_millis(250)); // Polling delay
    }
}

/// WebSocket listener: ha swap vagy addLiquidity esemény jön, trigger flag fájl létrehozása
fn listen_to_pool_activity() {
    let ws_url = Url::parse("wss://public-mainnet.rpcpool.com/ws").unwrap();
    let (mut socket, _) = connect(ws_url).expect("WebSocket connect failed");
    loop {
        if let Ok(msg) = socket.read_message() {
            let txt = msg.to_text().unwrap_or("");
            if txt.contains("swap") || txt.contains("addLiquidity") {
                // trigger flag beállítása
                let _ = std::fs::write("/tmp/pool_trigger.flag", "1");
                thread::sleep(Duration::from_secs(2));
                let _ = std::fs::remove_file("/tmp/pool_trigger.flag");
            }
        }
    }
}

/// Flag file meglétének ellenőrzése a loop-ban
fn detect_victim_activity() -> bool {
    Path::new("/tmp/pool_trigger.flag").exists()
}

/// Priority tip emelése sikertelen futtatás után, max 900k, utána reset
fn estimate_tip() -> u64 {
    let mut current = PRIORITY_BASE.load(Ordering::Relaxed);
    if current < 900_000 {
        current += 50_000;
        PRIORITY_BASE.store(current, Ordering::Relaxed);
    } else {
        PRIORITY_BASE.store(300_000, Ordering::Relaxed);
    }
    current
}

/// Sandwich bundle elkészítése: front-run és back-run tx, becsült profit
fn create_sandwich_bundle(
    client: &RpcClient,
    payer: &Keypair,
    tip_micro_lamports: u64,
    token_mint: &str,
) -> Option<(Transaction, Transaction, f64)> {
    let liquidity = fetch_pool_liquidity(token_mint);  // lekérdezett vagy mock likviditás
    let use_direct = liquidity >= LIQUIDITY_THRESHOLD;  // döntés 1-hop vs. 2-hop
    let front = create_jupiter_swap_tx(client, payer, USDC_MINT, token_mint, 1_000_000, tip_micro_lamports, use_direct);
    let back  = create_jupiter_swap_tx(client, payer, token_mint, USDC_MINT, 0, tip_micro_lamports, use_direct);
    match (front, back) {
        (Ok(f), Ok(b)) => Some((f, b, estimate_profit())),
        _ => None,
    }
}

/// Mock: Pool likviditás visszaadása (TODO: Jupiter pool API integration)
fn fetch_pool_liquidity(_token_mint: &str) -> f64 {
    850.0
}

/// Mock: PnL becslés USDC-ben (TODO: valós árszámítás implementálása)
fn estimate_profit() -> f64 {
    0.0123
}

/// Jito bundle JSON összeállítása és kiküldése privát relay-nek
fn send_jito_bundle(front: Transaction, back: Transaction) {
    let payload = serde_json::json!({
        "transactions": [
            base64::encode(bincode::serialize(&front).unwrap()),
            base64::encode(bincode::serialize(&back).unwrap())
        ],
        "simulation": false
    });
    let client = Client::new();
    match client.post("https://jito-relay.mainnet.block-engine.jito.wtf/api/v1/bundles")
        .json(&payload)
        .send() {
        Ok(resp) => println!("✅ Bundle submitted: {:?}", resp.status()),
        Err(err) => eprintln!("❌ Bundle submission failed: {}", err),
    }
}

/// Jupiter swapTransaction cache+TTL ellenőrzés, kérés, dekódolás és aláírás
fn create_jupiter_swap_tx(
    client: &RpcClient,
    payer: &Keypair,
    input_mint: &str,
    output_mint: &str,
    amount: u64,
    tip: u64,
    only_direct: bool,
) -> Result<Transaction, Box<dyn std::error::Error>> {
    // Cache kulcs felépítése: bemenet, kimenet, amount, tip
    let key = format!("{}:{}:{}:{}", input_mint, output_mint, amount, tip);
    let now_ms = SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis() as u64;
    let cached_b64: Option<String>;
    unsafe {
        if let Some(cache) = &mut JUPITER_CACHE {
            if let Some((b64, ts)) = cache.get(&key) {
                if now_ms - *ts <= JUPITER_CACHE_TTL_MS {
                    cached_b64 = Some(b64.clone());
                } else {
                    cache.remove(&key); cached_b64 = None;
                }
            } else { cached_b64 = None; }
        } else {
            JUPITER_CACHE = Some(HashMap::new()); cached_b64 = None;
        }
    }
    // Cache miss: kérjük le és tároljuk
    let swap_tx_b64 = if let Some(b64) = cached_b64 { b64 } else {
        let url = format!(
            "{}?inputMint={}&outputMint={}&amount={}&slippageBps={}&onlyDirectRoutes={}&computeUnitPriceMicroLamports={}",
            JUPITER_API_URL, input_mint, output_mint, amount, SLIPPAGE_BPS, only_direct, tip
        );
        let resp: Value = Client::new().get(&url).send()?.json()?;
        let b64 = resp["swapTransaction"].as_str().unwrap().to_string();
        unsafe { if let Some(cache) = &mut JUPITER_CACHE { cache.insert(key.clone(), (b64.clone(), now_ms)); } }
        b64
    };
    // Dekódolás és aláírás
    let tx_bytes = base64::decode(swap_tx_b64)?;
    let mut tx: Transaction = bincode::deserialize(&tx_bytes)?;
    tx.partial_sign(&[payer], client.get_latest_blockhash()?);
    Ok(tx)
}
