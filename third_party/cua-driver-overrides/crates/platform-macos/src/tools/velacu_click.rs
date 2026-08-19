use async_trait::async_trait;
use cua_driver_core::{
    action_record::{
        ActionEffect, ActionEvidence, ActionExecutionRecord, ActionTransport, ActualDelivery,
        EvidenceKind, RequestedDelivery,
    },
    protocol::ToolResult,
    tool::{Tool, ToolDef},
    tool_args::ArgsExt,
};
use serde_json::Value;
use std::sync::Arc;

use super::ToolState;

extern "C" {
    fn CGPreflightPostEventAccess() -> bool;
}

/// VelaCU's deliberately tiny last-mile executor.
///
/// Contract:
/// - accepts ONLY pid + exact window_id + window-local logical-point x/y
/// - never resolves AX elements, never accepts element_index/token, never performs AXPress
/// - uses Cua's proven SkyLight/CGEvent background mouse recipe
/// - keeps Cua's visible agent cursor overlay, but never moves the user's real pointer
pub struct VelaCuClickTool {
    state: Arc<ToolState>,
}

impl VelaCuClickTool {
    pub fn new(state: Arc<ToolState>) -> Self {
        Self { state }
    }
}

fn action_record() -> ActionExecutionRecord {
    ActionExecutionRecord::builder(
        ActionEffect::Unverifiable,
        ActionTransport::MacosCgEventPid,
        RequestedDelivery::Background,
    )
    .actual_delivery(ActualDelivery::Background)
    .evidence(ActionEvidence {
        kind: EvidenceKind::NativeApiResult,
        detail: "VelaCU dispatched the SkyLight/CGEvent background XY event stream to the requested pid/window".into(),
    })
    .build()
    .expect("VelaCU click action record is valid")
}

static DEF: std::sync::OnceLock<ToolDef> = std::sync::OnceLock::new();

fn def() -> &'static ToolDef {
    DEF.get_or_init(|| ToolDef {
        name: "click".into(),
        description: "Pure XY background click for VelaCU. x/y are window-local logical points. No AX targeting or AX click path exists in this tool. The user's real pointer is not moved; the agent cursor overlay remains visible.".into(),
        input_schema: serde_json::json!({
            "type": "object",
            "required": ["pid", "window_id", "x", "y"],
            "properties": {
                "session": { "type": "string" },
                "pid": { "type": "integer" },
                "window_id": { "type": "integer" },
                "x": { "type": "number", "description": "Window-local X in logical points." },
                "y": { "type": "number", "description": "Window-local Y in logical points." },
                "count": { "type": "integer", "minimum": 1, "maximum": 2, "default": 1 }
            },
            "additionalProperties": false
        }),
        read_only: false,
        destructive: false,
        idempotent: false,
        open_world: false,
    })
}

#[async_trait]
impl Tool for VelaCuClickTool {
    fn def(&self) -> &ToolDef {
        def()
    }

    async fn invoke(&self, args: Value) -> ToolResult {
        let pid = match args.require_i32("pid") {
            Ok(v) => v,
            Err(e) => return e,
        };
        let window_id = match args.require_u64("window_id") {
            Ok(v) => v as u32,
            Err(e) => return e,
        };
        let x = match args.require_f64("x") {
            Ok(v) => v,
            Err(e) => return e,
        };
        let y = match args.require_f64("y") {
            Ok(v) => v,
            Err(e) => return e,
        };
        let count = args.u64_or("count", 1).clamp(1, 2) as usize;
        let post_event_access = unsafe { CGPreflightPostEventAccess() };
        if !post_event_access {
            return ToolResult::error("VelaCU Cua driver lacks CGPostEvent access");
        }

        // Resolve only the live WindowServer frame. VelaCU already owns capture and
        // coordinate scaling, so this executor never captures the screen and never
        // walks AX. x/y arrive as window-local logical points.
        let Some(bounds) = crate::windows::window_bounds_by_id(window_id) else {
            return ToolResult::error(format!("VelaCU window_id {window_id} is not live"));
        };
        if x < 0.0 || y < 0.0 || x > bounds.width || y > bounds.height {
            return ToolResult::error(format!(
                "VelaCU click ({x:.1},{y:.1}) lies outside window {window_id} {:.0}x{:.0} pt",
                bounds.width, bounds.height
            ));
        }
        let local_x = x;
        let local_y = y;
        let screen_x = bounds.x + local_x;
        let screen_y = bounds.y + local_y;

        // Keep Cua's DISPLAY-ONLY virtual cursor. This does not move the physical pointer.
        let cursor_key = super::cursor_tools::resolve_cursor_key(&args);
        crate::cursor::overlay::send_command(
            cursor_key.clone(),
            cursor_overlay::OverlayCommand::PinAbove(window_id as u64),
        );
        crate::cursor::overlay::animate_cursor_to(cursor_key.clone(), screen_x, screen_y).await;
        self.state
            .cursor_registry
            .update_position(&cursor_key, screen_x, screen_y);

        // Cua's successful background recipe: activate AppKit routing without raising,
        // re-pin overlay, then send the Chromium-compatible SkyLight/CGEvent stream.
        let activated = tokio::task::spawn_blocking(move || {
            crate::input::mouse::prepare_background_pixel_click(pid, window_id)
        })
        .await
        .unwrap_or(false);

        crate::cursor::overlay::send_command(
            cursor_key.clone(),
            cursor_overlay::OverlayCommand::PinAbove(window_id as u64),
        );
        crate::cursor::overlay::send_command(
            cursor_key,
            cursor_overlay::OverlayCommand::ClickPulse {
                x: screen_x,
                y: screen_y,
            },
        );

        let result = tokio::task::spawn_blocking(move || {
            crate::input::mouse::click_at_xy_with_window_local(
                pid,
                screen_x,
                screen_y,
                local_x,
                local_y,
                window_id,
                count,
                &[],
            )
        })
        .await;

        match result {
            Ok(Ok(())) => ToolResult::text("VelaCU XY background click delivered.")
                .with_structured(serde_json::json!({
                    "ok": true,
                    "route": "skylight_cgevent_xy",
                    "ax_used": false,
                    "physical_cursor_moved": false,
                    "agent_cursor_visible": true,
                    "post_event_access": post_event_access,
                    "activated_without_raise": activated,
                    "pid": pid,
                    "window_id": window_id,
                    "raw_x": x,
                    "raw_y": y,
                    "screen_x": screen_x,
                    "screen_y": screen_y,
                    "window_local_x": local_x,
                    "window_local_y": local_y
                }))
                .with_action_record(action_record()),
            Ok(Err(error)) => ToolResult::error(format!("VelaCU XY click failed: {error}")),
            Err(error) => ToolResult::error(format!("VelaCU XY click task failed: {error}")),
        }
    }
}
