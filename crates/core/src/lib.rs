//! ShadowCorp core: event schema, classification, scoring, progress, the
//! achievement engine and text rendering. Pure logic — no IO lives here.

pub mod achievements;
pub mod classify;
pub mod event;
pub mod expr;
pub mod occupation;
pub mod pricing;
pub mod progress;
pub mod render;
pub mod scoring;
