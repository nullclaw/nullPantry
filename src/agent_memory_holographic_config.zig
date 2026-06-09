pub const default_db_path = ".nullpantry/holographic_memory.db";

pub const Config = struct {
    db_path: ?[]const u8 = null,
    default_trust: f64 = 0.5,
    trust_reward: f64 = 0.05,
    trust_penalty: f64 = 0.10,
};
