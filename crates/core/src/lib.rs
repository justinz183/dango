//! ShadowCorp core: event schema, classification, scoring, progress, the
//! achievement engine and text rendering. Pure logic — no IO lives here.

pub mod achievements;
pub mod classify;
pub mod event;
pub mod expr;
pub mod progress;
pub mod rank;
pub mod render;
pub mod scoring;
pub mod value;
