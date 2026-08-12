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

/// Build a provider from an LlmConfig. Call once at program start: the
/// provider state owns copies of the key/model/base_url; call
/// `provider.deinit()` at shutdown.
pub fn fromConfig(allocator: std.mem.Allocator, cfg: config_mod.LlmConfig) !LlmProvider {
    if (std.mem.eql(u8, cfg.provider, "groq")) {
        const key = try config_mod.apiKey(allocator, "GROQ_API_KEY");
        const prov = openai.init(allocator, key, cfg.model, "https://api.groq.com/openai/v1");
        allocator.free(key); // init duped it into its own state
        return prov;
    } else if (std.mem.eql(u8, cfg.provider, "openai")) {
        const key = try config_mod.apiKey(allocator, "OPENAI_API_KEY");
        const prov = openai.init(allocator, key, cfg.model, "https://api.openai.com/v1");
        allocator.free(key); // init duped it into its own state
        return prov;
    } else if (std.mem.eql(u8, cfg.provider, "ollama")) {
        return ollama.init(allocator, cfg.model, "http://localhost:11434");
    }
    return error.UnknownProvider;
}
