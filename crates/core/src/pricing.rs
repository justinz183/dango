//! What the models cost (docs/DESIGN.md v5): token counts by model, priced
//! from assets/model_prices.toml, and the economic leverage — what the work
//! would have cost a person ÷ what the models cost at API prices.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

pub const BUILTIN_TOML: &str = include_str!("../../../assets/model_prices.toml");

/// OpenAI prices a request over this many input tokens at its long-context rate.
pub const OPENAI_LONG_CONTEXT: u64 = 272_000;
/// Claude Haiku 5.5 prices a prompt over this many tokens at its higher rate.
pub const HAIKU_LONG_PROMPT: u64 = 100_000;
/// Below this cost there is nothing meaningful to divide by.
pub const MIN_COST: f64 = 0.01;

/// Tokens of one model, split the way they are priced.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Tokens {
    /// Input not read from or written to a cache.
    pub input: u64,
    /// Written to a short-lived cache (Anthropic 5 min, OpenAI 30 min).
    pub cache_write: u64,
    /// Written to a long-lived cache (Anthropic 1 h, OpenAI 12 h).
    pub cache_write_long: u64,
    pub cache_read: u64,
    /// Output, reasoning included.
    pub output: u64,
}

impl Tokens {
    pub fn add(&mut self, o: &Tokens) {
        self.input += o.input;
        self.cache_write += o.cache_write;
        self.cache_write_long += o.cache_write_long;
        self.cache_read += o.cache_read;
        self.output += o.output;
    }

    pub fn total(&self) -> u64 {
        self.input + self.cache_write + self.cache_write_long + self.cache_read + self.output
    }
}

/// Dollars per million tokens.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Price {
    pub id: String,
    pub input: f64,
    /// Missing write prices fall back to the input price.
    pub cache_write: Option<f64>,
    pub cache_write_long: Option<f64>,
    pub cache_read: f64,
    pub output: f64,
}

impl Price {
    pub fn cost(&self, t: &Tokens) -> f64 {
        let w = self.cache_write.unwrap_or(self.input);
        let wl = self.cache_write_long.unwrap_or(w);
        (t.input as f64 * self.input
            + t.cache_write as f64 * w
            + t.cache_write_long as f64 * wl
            + t.cache_read as f64 * self.cache_read
            + t.output as f64 * self.output)
            / 1e6
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct PriceTable {
    pub source: String,
    pub as_of: String,
    pub model: Vec<Price>,
}

impl PriceTable {
    pub fn parse(src: &str) -> Result<PriceTable, String> {
        toml::from_str(src).map_err(|e| e.to_string())
    }

    pub fn builtin() -> &'static PriceTable {
        static T: OnceLock<PriceTable> = OnceLock::new();
        T.get_or_init(|| PriceTable::parse(BUILTIN_TOML).expect("built-in model_prices.toml"))
    }

    pub fn get(&self, model: &str) -> Option<&Price> {
        self.model.iter().find(|p| p.id == model)
    }

    /// Cost of tokens by model, and the tokens of models without a price.
    pub fn cost(&self, by_model: &BTreeMap<String, Tokens>) -> (f64, u64) {
        let (mut usd, mut unpriced) = (0.0, 0);
        for (m, t) in by_model {
            match self.get(m) {
                Some(p) => usd += p.cost(t),
                None => unpriced += t.total(),
            }
        }
        (usd, unpriced)
    }
}

/// The price-table key for one request: the model, with "@long" when the
/// request is over the model's long-context threshold.
pub fn price_key(model: &str, prompt_tokens: u64) -> String {
    let long = if model.starts_with("gpt-") {
        prompt_tokens > OPENAI_LONG_CONTEXT
    } else {
        model == "claude-haiku-5-5" && prompt_tokens > HAIKU_LONG_PROMPT
    };
    if long { format!("{model}@long") } else { model.to_string() }
}

/// Economic leverage: dollars of work per dollar of model, when there is a cost.
pub fn leverage(usd: f64, cost: f64) -> Option<f64> {
    (cost >= MIN_COST).then(|| usd / cost)
}

/// "19.7x", "250x" past a hundred, "—" with no cost.
pub fn fmt_leverage(l: Option<f64>) -> String {
    match l {
        None => "—".to_string(),
        Some(x) if x >= 100.0 => format!("{}x", x.round() as i64),
        Some(x) => format!("{x:.1}x"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(input: u64, cw: u64, cwl: u64, cr: u64, out: u64) -> Tokens {
        Tokens { input, cache_write: cw, cache_write_long: cwl, cache_read: cr, output: out }
    }

    #[test]
    fn prices_from_the_official_pages() {
        let p = PriceTable::builtin();
        // Opus 5.5: $4 in, $5 5m write, $8 1h write, $0.20 read, $20 out.
        let m = 1_000_000;
        let opus = p.get("claude-opus-5-5").unwrap();
        assert!((opus.cost(&t(m, m, m, m, m)) - (4.0 + 5.0 + 8.0 + 0.20 + 20.0)).abs() < 1e-9);
        // Fable 5.1 cache reads at 0.025x input.
        assert!((p.get("claude-fable-5-1").unwrap().cost(&t(0, 0, 0, m, 0)) - 0.25).abs() < 1e-9);
        // gpt-5.5 has no cache-write price: writes cost input.
        assert!((p.get("gpt-5.5").unwrap().cost(&t(0, m, 0, 0, 0)) - 5.0).abs() < 1e-9);
        assert!((p.get("gpt-6-astra@long").unwrap().cost(&t(m, 0, 0, 0, m)) - 95.0).abs() < 1e-9);
    }

    #[test]
    fn unknown_models_are_counted_not_priced() {
        let by: BTreeMap<String, Tokens> =
            [("claude-opus-5-5".to_string(), t(0, 0, 0, 0, 1_000_000)), ("codex-auto-review".to_string(), t(500, 0, 0, 0, 0))].into();
        let (usd, unpriced) = PriceTable::builtin().cost(&by);
        assert!((usd - 20.0).abs() < 1e-9);
        assert_eq!(unpriced, 500);
    }

    #[test]
    fn long_context_and_leverage() {
        assert_eq!(price_key("gpt-6-astra", 272_000), "gpt-6-astra");
        assert_eq!(price_key("gpt-6-astra", 272_001), "gpt-6-astra@long");
        assert_eq!(price_key("claude-opus-5-5", 900_000), "claude-opus-5-5");
        assert_eq!(price_key("claude-haiku-5-5", 100_001), "claude-haiku-5-5@long");
        assert_eq!(leverage(100.0, 0.005), None);
        assert_eq!(fmt_leverage(leverage(1672.0, 84.9)), "19.7x");
        assert_eq!(fmt_leverage(Some(250.4)), "250x");
        assert_eq!(fmt_leverage(None), "—");
    }
}
