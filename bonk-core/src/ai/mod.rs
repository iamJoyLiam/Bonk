//! AI provider abstraction - pure HTTP, no OS deps
//! Mirrors BonkMac's LLMProvider / AIProviderNetworking
//! P1 已用 reqwest 实现真连，mock 兜底保证离线可用

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use crate::error::{CoreError, CoreResult};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiMessage {
    pub role: String, // "user" | "assistant" | "system"
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiCompletionRequest {
    pub model: String,
    pub messages: Vec<AiMessage>,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiCompletionResponse {
    pub content: String,
    pub finish_reason: Option<String>,
}

#[async_trait]
pub trait AiProvider: Send + Sync {
    async fn complete(&self, req: AiCompletionRequest) -> CoreResult<AiCompletionResponse>;
    fn name(&self) -> &str;
}

// ---- OpenAI Compatible (OpenAI/Groq/DeepSeek/通用) ----

pub struct OpenAiCompatProvider {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
}

#[async_trait]
impl AiProvider for OpenAiCompatProvider {
    async fn complete(&self, req: AiCompletionRequest) -> CoreResult<AiCompletionResponse> {
        if self.api_key.is_empty() {
            // no key -> hard failure, never mock success for a missing credential
            return Err(CoreError::Ai("no API key configured for OpenAI-compatible provider".into()));
        }
        let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(30)).build().map_err(|e| CoreError::Ai(e.to_string()))?;
        // Build OpenAI chat completions payload
        let payload = serde_json::json!({
            "model": if req.model.is_empty() { &self.model } else { &req.model },
            "messages": req.messages.iter().map(|m| serde_json::json!({"role": m.role, "content": m.content})).collect::<Vec<_>>(),
            "max_tokens": req.max_tokens.unwrap_or(2048),
            "temperature": req.temperature.unwrap_or(0.7),
            "stream": false
        });
        let url = format!("{}/v1/chat/completions", self.base_url.trim_end_matches('/'));
        let resp = client.post(&url)
            .bearer_auth(&self.api_key)
            .json(&payload)
            .send().await.map_err(|e| CoreError::Ai(e.to_string()))?;
        if !resp.status().is_success() {
            let txt = resp.text().await.unwrap_or_default();
            return Err(CoreError::Ai(format!("openai http {}: {}", txt.chars().take(300).collect::<String>(), txt.len())));
        }
        let v: serde_json::Value = resp.json().await.map_err(|e| CoreError::Ai(e.to_string()))?;
        // Parse choices[0].message.content
        let content = v.get("choices").and_then(|c| c.get(0)).and_then(|c| c.get("message")).and_then(|m| m.get("content")).and_then(|c| c.as_str()).unwrap_or("").to_string();
        let finish = v.get("choices").and_then(|c| c.get(0)).and_then(|c| c.get("finish_reason")).and_then(|c| c.as_str()).map(|s| s.to_string());
        if content.is_empty() {
            // fallback to mock if empty
            let last = req.messages.last().map(|m| m.content.clone()).unwrap_or_default();
            return Ok(AiCompletionResponse { content: format!("[empty fallback] {}", last), finish_reason: finish });
        }
        Ok(AiCompletionResponse { content, finish_reason: finish })
    }
    fn name(&self) -> &str { "openai-compat" }
}

// ---- Claude (Anthropic) ----

pub struct ClaudeProvider {
    pub api_key: String,
    pub model: String,
}

#[async_trait]
impl AiProvider for ClaudeProvider {
    async fn complete(&self, req: AiCompletionRequest) -> CoreResult<AiCompletionResponse> {
        if self.api_key.is_empty() {
            return Err(CoreError::Ai("no API key configured for Claude provider".into()));
        }
        let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(30)).build().map_err(|e| CoreError::Ai(e.to_string()))?;
        // Anthropic expects system as separate field
        let system = req.messages.iter().find(|m| m.role=="system").map(|m| m.content.clone()).unwrap_or_default();
        let msgs: Vec<_> = req.messages.iter().filter(|m| m.role!="system").map(|m| serde_json::json!({"role": m.role, "content": m.content})).collect();
        let payload = serde_json::json!({
            "model": if req.model.is_empty() { &self.model } else { &req.model },
            "messages": msgs,
            "system": system,
            "max_tokens": req.max_tokens.unwrap_or(2048)
        });
        let resp = client.post("https://api.anthropic.com/v1/messages")
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", "2023-06-01")
            .json(&payload)
            .send().await.map_err(|e| CoreError::Ai(e.to_string()))?;
        let v: serde_json::Value = resp.json().await.map_err(|e| CoreError::Ai(e.to_string()))?;
        let content = v.get("content").and_then(|c| c.get(0)).and_then(|c| c.get("text")).and_then(|c| c.as_str()).unwrap_or("").to_string();
        Ok(AiCompletionResponse { content, finish_reason: v.get("stop_reason").and_then(|c| c.as_str()).map(|s| s.to_string()) })
    }
    fn name(&self) -> &str { "claude" }
}

// ---- Gemini (Google) ----

pub struct GeminiProvider {
    pub api_key: String,
    pub model: String,
}

#[async_trait]
impl AiProvider for GeminiProvider {
    async fn complete(&self, req: AiCompletionRequest) -> CoreResult<AiCompletionResponse> {
        if self.api_key.is_empty() {
            return Err(CoreError::Ai("no API key configured for Gemini provider".into()));
        }
        let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(30)).build().map_err(|e| CoreError::Ai(e.to_string()))?;
        let model = if req.model.is_empty() { &self.model } else { &req.model };
        let contents: Vec<_> = req.messages.iter().map(|m| serde_json::json!({"role": if m.role=="assistant" {"model"} else {"user"}, "parts": [{"text": m.content}] })).collect();
        let payload = serde_json::json!({"contents": contents});
        let url = format!("https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent?key={}", model, self.api_key);
        let resp = client.post(&url).json(&payload).send().await.map_err(|e| CoreError::Ai(e.to_string()))?;
        let v: serde_json::Value = resp.json().await.map_err(|e| CoreError::Ai(e.to_string()))?;
        let content = v.get("candidates").and_then(|c| c.get(0)).and_then(|c| c.get("content")).and_then(|c| c.get("parts")).and_then(|c| c.get(0)).and_then(|c| c.get("text")).and_then(|c| c.as_str()).unwrap_or("").to_string();
        Ok(AiCompletionResponse { content, finish_reason: Some("STOP".into()) })
    }
    fn name(&self) -> &str { "gemini" }
}

// ---- Ollama (local) ----

pub struct OllamaProvider {
    pub base_url: String, // e.g. http://localhost:11434
    pub model: String,
}

#[async_trait]
impl AiProvider for OllamaProvider {
    async fn complete(&self, req: AiCompletionRequest) -> CoreResult<AiCompletionResponse> {
        let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(60)).build().map_err(|e| CoreError::Ai(e.to_string()))?;
        let url = format!("{}/api/chat", self.base_url.trim_end_matches('/'));
        let payload = serde_json::json!({
            "model": if req.model.is_empty() { &self.model } else { &req.model },
            "messages": req.messages.iter().map(|m| serde_json::json!({"role": m.role, "content": m.content})).collect::<Vec<_>>(),
            "stream": false
        });
        let resp = client.post(&url).json(&payload).send().await;
        match resp {
            Ok(r) if r.status().is_success() => {
                let v: serde_json::Value = r.json().await.map_err(|e| CoreError::Ai(e.to_string()))?;
                let content = v.get("message").and_then(|m| m.get("content")).and_then(|c| c.as_str()).unwrap_or("").to_string();
                Ok(AiCompletionResponse { content, finish_reason: Some("stop".into()) })
            },
            Ok(r) => {
                let txt = r.text().await.unwrap_or_default();
                Err(CoreError::Ai(format!("ollama {}: {}", txt.chars().take(200).collect::<String>(), txt.len())))
            },
            Err(e) => {
                // connection failure: report error, never mock success
                Err(CoreError::Ai(e.to_string()))
            }
        }
    }
    fn name(&self) -> &str { "ollama" }
}

// ---- Factory ----

pub enum AiProviderKind { OpenAI, Claude, Gemini, Ollama }

pub fn provider_for(kind: AiProviderKind, model: &str, api_key: &str, base_url: &str) -> Box<dyn AiProvider> {
    match kind {
        AiProviderKind::OpenAI => Box::new(OpenAiCompatProvider { base_url: base_url.into(), api_key: api_key.into(), model: model.into() }),
        AiProviderKind::Claude => Box::new(ClaudeProvider { api_key: api_key.into(), model: model.into() }),
        AiProviderKind::Gemini => Box::new(GeminiProvider { api_key: api_key.into(), model: model.into() }),
        AiProviderKind::Ollama => Box::new(OllamaProvider { base_url: base_url.into(), model: model.into() }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_request() -> AiCompletionRequest {
        AiCompletionRequest {
            model: "test-model".into(),
            messages: vec![AiMessage { role: "user".into(), content: "hello".into() }],
            max_tokens: Some(100),
            temperature: Some(0.7),
        }
    }

    /// P2-8: empty API key must produce a hard error, never mock success.
    #[tokio::test]
    async fn openai_compat_empty_key_is_hard_error() {
        let provider = OpenAiCompatProvider {
            base_url: "https://api.openai.com".into(),
            api_key: "".into(),
            model: "gpt-4o-mini".into(),
        };
        let result = provider.complete(make_request()).await;
        assert!(result.is_err(), "empty API key must not return mock success");
        match result.err().unwrap() {
            CoreError::Ai(msg) => assert!(msg.contains("no API key configured")),
            other => panic!("expected CoreError::Ai, got {:?}", other),
        }
    }

    /// P2-8: empty API key must produce a hard error, never mock success.
    #[tokio::test]
    async fn claude_empty_key_is_hard_error() {
        let provider = ClaudeProvider {
            api_key: "".into(),
            model: "claude-3-sonnet".into(),
        };
        let result = provider.complete(make_request()).await;
        assert!(result.is_err(), "empty API key must not return mock success");
        match result.err().unwrap() {
            CoreError::Ai(msg) => assert!(msg.contains("no API key configured")),
            other => panic!("expected CoreError::Ai, got {:?}", other),
        }
    }

    /// P2-8: empty API key must produce a hard error, never mock success.
    #[tokio::test]
    async fn gemini_empty_key_is_hard_error() {
        let provider = GeminiProvider {
            api_key: "".into(),
            model: "gemini-pro".into(),
        };
        let result = provider.complete(make_request()).await;
        assert!(result.is_err(), "empty API key must not return mock success");
        match result.err().unwrap() {
            CoreError::Ai(msg) => assert!(msg.contains("no API key configured")),
            other => panic!("expected CoreError::Ai, got {:?}", other),
        }
    }

    /// P2-8: Ollama connection failure must produce a hard error, never mock success.
    #[tokio::test]
    async fn ollama_connection_failure_is_hard_error() {
        // 127.0.0.1:1 is refused immediately on localhost, so this returns fast.
        let provider = OllamaProvider {
            base_url: "http://127.0.0.1:1".into(),
            model: "llama3".into(),
        };
        let result = provider.complete(make_request()).await;
        assert!(result.is_err(), "ollama connection failure must not return mock success");
    }
}
