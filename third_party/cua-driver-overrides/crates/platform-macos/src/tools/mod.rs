// Derived from Cua (https://github.com/trycua/cua), Copyright (c) 2025 Cua AI, Inc.
// Cua is distributed under the MIT License; see third_party/CUA_LICENSE.md.
// Modified by VelaCU to register only the minimal pixel-click/cursor surface.

//! Minimal macOS tool surface used by VelaCU.
//!
//! This fork intentionally contains only:
//! - pure XY background click (SkyLight + CGEvent, no AX targeting)
//! - display-only agent cursor controls
//!
//! VelaCU owns screenshots, visual reasoning, window binding and coordinate
//! conversion. This crate is only the last-mile background pointer executor.

mod cursor_tools;
pub(crate) mod get_screen_size;
mod velacu_click;
pub(crate) mod px_frame;

use cua_driver_core::tool::ToolRegistry;
use std::sync::Arc;

use crate::cursor::state::CursorRegistry;

// Keep the standalone CLI's private permission-host entrypoints link-compatible.
// They are not registered as VelaCU tools and cannot be invoked by the model.
pub const PERMISSIONS_HOST_REQUEST_ARG: &str = "__permissions-host-request";

pub async fn request_permissions_from_launchservices_host(
    _probe_direct_capture: bool,
) -> cua_driver_core::protocol::ToolResult {
    cua_driver_core::protocol::ToolResult::error(
        "Permission setup is disabled in the VelaCU pixel-only driver build.",
    )
}

/// Shared state required by the tiny VelaCU tool surface.
pub struct ToolState {
    pub cursor_registry: Arc<CursorRegistry>,
    pub cursor_overlay_available: bool,
}

impl ToolState {
    fn new(cursor_overlay_available: bool) -> Self {
        Self {
            cursor_registry: Arc::new(CursorRegistry::new()),
            cursor_overlay_available,
        }
    }
}

pub(crate) fn cursor_overlay_unavailable() -> cua_driver_core::protocol::ToolResult {
    let message = "macOS agent cursor overlay is unavailable for this runtime";
    cua_driver_core::protocol::ToolResult::error(message).with_structured(serde_json::json!({
        "status": "refused",
        "refusal": {
            "code": "facility_unavailable",
            "facility": "macos_cursor_overlay",
            "message": message,
        }
    }))
}

/// Register the deliberately tiny VelaCU backend.
///
/// The signature stays compatible with the upstream Cua constructor so the
/// normal daemon/AppKit host can still be reused for the virtual cursor overlay.
pub fn register_all(
    registry: &mut ToolRegistry,
    compat: bool,
    cursor_overlay_available: bool,
    host_owns_permission_ux: bool,
    host_bundle_id: Option<String>,
) {
    let _ = (compat, host_owns_permission_ux, host_bundle_id);
    let state = Arc::new(ToolState::new(cursor_overlay_available));

    // Keep cursor outcome reporting/lifecycle cleanup so the overlay behaves
    // exactly like upstream Cua even though the rest of the tool surface is gone.
    let cursor_outcome_reader = {
        let cursor_registry = state.cursor_registry.clone();
        cua_driver_core::session::register_scoped_cursor_outcome_reader(Arc::new(
            move |session_id| {
                let cursor = cursor_registry.get(session_id);
                let active_cursor_count = cursor_registry
                    .all_states()
                    .iter()
                    .filter(|state| state.config.cursor_id != "default")
                    .count()
                    .max(1);
                match cursor {
                    Some(state) => cua_driver_core::session::bounded_cursor_outcome(
                        true,
                        state.config.enabled,
                        crate::cursor::overlay::is_visible_for_session(session_id),
                        Some(state.config.theme_id.as_str()),
                        false,
                        active_cursor_count,
                    ),
                    None => cua_driver_core::session::bounded_cursor_outcome(
                        false,
                        false,
                        false,
                        None,
                        false,
                        active_cursor_count,
                    ),
                }
            },
        ))
    };
    registry.retain_cursor_outcome_reader(cursor_outcome_reader);

    {
        let cursor_registry = state.cursor_registry.clone();
        let registration =
            cua_driver_core::session::register_scoped_session_end_hook(move |session_id| {
                cursor_registry.remove(session_id);
                crate::cursor::overlay::remove_cursor(session_id.to_owned());
            });
        registry.retain_session_end_hook(registration);

        let revive_registration =
            cua_driver_core::session::register_scoped_session_revive_hook(move |session_id| {
                crate::cursor::overlay::revive_cursor(session_id.to_owned());
            });
        registry.retain_session_revive_hook(revive_registration);
    }

    // Exactly one action tool: XY click. No AX tree, AX element action, DOM,
    // browser, keyboard, clipboard, capture, launch/kill, drag, scroll, etc.
    registry.register(Box::new(velacu_click::VelaCuClickTool::new(state.clone())));

    // Keep only the controls needed for the visible virtual mouse.
    registry.register(Box::new(cursor_tools::SetAgentCursorEnabledTool::new(
        state.clone(),
    )));
    registry.register(Box::new(cursor_tools::SetAgentCursorMotionTool::new(
        state.clone(),
    )));
    registry.register(Box::new(cursor_tools::SetAgentCursorThemeTool::new(
        state.clone(),
    )));
    registry.register(Box::new(cursor_tools::GetAgentCursorStateTool::new(state)));
}
