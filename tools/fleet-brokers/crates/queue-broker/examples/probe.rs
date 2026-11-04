use std::time::{Duration, Instant};

fn get_secret(agent: &ureq::Agent, tok: &str, name: &str) -> String {
    let url = format!("http://100.99.113.103:4800/secret/{name}");
    let mut resp = agent.get(&url).header("X-Agent-Token", tok).call().unwrap();
    let text = resp.body_mut().read_to_string().unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    v["value"].as_str().unwrap().to_string()
}

fn main() {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(15)))
        .build()
        .into();
    let home = std::env::var("HOME").unwrap();
    let stok = std::fs::read_to_string(format!("{home}/.config/secrets-broker/token"))
        .unwrap()
        .trim()
        .to_string();
    let t = Instant::now();
    let key = get_secret(&agent, &stok, "supabase.service-role-key");
    let url = get_secret(&agent, &stok, "supabase.project-url");
    println!("creds in {:?} (key len {})", t.elapsed(), key.len());
    let base = url.trim_end_matches('/');
    let path = "tasks?select=id,created_at&queue=eq.repo-health-code-pilot&status=eq.queued&order=created_at.asc&limit=1";
    let full = format!("{base}/rest/v1/{path}");
    let t = Instant::now();
    let r = agent
        .get(&full)
        .header("apikey", &key)
        .header("Authorization", &format!("Bearer {key}"))
        .header("Accept-Profile", "agent")
        .header("Prefer", "count=exact")
        .call();
    match r {
        Ok(mut resp) => {
            let s = resp.status().as_u16();
            let cr = resp
                .headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string());
            let txt = resp.body_mut().read_to_string().unwrap_or_default();
            println!("pg OK {s} in {:?} cr={cr:?}: {}", t.elapsed(), &txt[..txt.len().min(120)]);
        }
        Err(e) => println!("pg ERR in {:?}: {e}", t.elapsed()),
    }
}
