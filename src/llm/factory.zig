//! Provider construction from config.

const std = @import("std");
const provider = @import("provider.zig");
const openai = @import("openai.zig");
const ollama = @import("ollama.zig");
const config_mod = @import("../utils/config.zig");

pub const LlmProvider = provider.LlmProvider;

pub const Error = error{
    UnknownProvider,
    MissingApiKey,
};

/// OpenAI-compatible providers: name → base URL + API key env var.
/// All are Bearer-auth OpenAI-compatible chat-completions endpoints;
/// openai.init appends /chat/completions.
const Provider = struct { name: []const u8, url: []const u8, key_env: []const u8 };

const providers = [_]Provider{
    .{ .name = "groq",       .url = "https://api.groq.com/openai/v1",       .key_env = "GROQ_API_KEY" },
    .{ .name = "openai",     .url = "https://api.openai.com/v1",             .key_env = "OPENAI_API_KEY" },
    .{ .name = "deepseek",   .url = "https://api.deepseek.com/v1",           .key_env = "DEEPSEEK_API_KEY" },
    .{ .name = "mistral",    .url = "https://api.mistral.ai/v1",             .key_env = "MISTRAL_API_KEY" },
    .{ .name = "together",   .url = "https://api.together.xyz/v1",           .key_env = "TOGETHER_API_KEY" },
    .{ .name = "fireworks",  .url = "https://api.fireworks.ai/inference/v1", .key_env = "FIREWORKS_API_KEY" },
    .{ .name = "xai",        .url = "https://api.x.ai/v1",                   .key_env = "XAI_API_KEY" },
    .{ .name = "cerebras",   .url = "https://api.cerebras.ai/v1",            .key_env = "CEREBRAS_API_KEY" },
    .{ .name = "openrouter", .url = "https://openrouter.ai/api/v1",          .key_env = "OPENROUTER_API_KEY" },
    .{ .name = "perplexity", .url = "https://api.perplexity.ai",             .key_env = "PERPLEXITY_API_KEY" },
    .{ .name = "sambanova",  .url = "https://api.sambanova.ai/v1",           .key_env = "SAMBANOVA_API_KEY" },
    .{ .name = "deepinfra",  .url = "https://api.deepinfra.com/v1/openai",   .key_env = "DEEPINFRA_API_KEY" },
    .{ .name = "github",     .url = "https://models.inference.ai.azure.com", .key_env = "GITHUB_TOKEN" },
};

comptime {
    for (providers, 0..) |p, i| {
        std.debug.assert(!std.mem.eql(u8, p.name, "ollama"));
        for (providers[0..i]) |q| std.debug.assert(!std.mem.eql(u8, q.name, p.name));
    }
}

/// First provider whose API-key env var is set, or null. Table order wins
/// when several keys are set; the CLI --provider flag or config.json beats it.
pub fn detectProvider() ?[]const u8 {
    for (providers) |p| {
        if (config_mod.getEnvPosix(p.key_env)) |v| {
            if (v.len > 0) return p.name;
        }
    }
    return null;
}

/// Build a provider from an LlmConfig. Call once at program start: the
/// provider state owns copies of the key/model/base_url; call
/// `provider.deinit()` at shutdown.
pub fn fromConfig(allocator: std.mem.Allocator, cfg: config_mod.LlmConfig) !LlmProvider {
    const name = cfg.provider orelse (detectProvider() orelse return error.MissingApiKey);
    // Ollama: separate protocol (/api/generate), no API key.
    if (std.mem.eql(u8, name, "ollama")) {
        return ollama.init(allocator, cfg.model, "http://localhost:11434");
    }
    for (providers) |p| {
        if (!std.mem.eql(u8, name, p.name)) continue;
        const key = try config_mod.apiKey(allocator, p.key_env);
        const prov = openai.init(allocator, key, cfg.model, p.url);
        allocator.free(key); // init duped it into its own state
        return prov;
    }
    return error.UnknownProvider;
}
