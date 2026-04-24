package http

import mpsc  "internal/mpsc"
import nbio  "core:nbio"
import "base:intrinsics"
import "core:log"

// Start the async process for this request.
// Call this from your handler or body callback on the io thread.
// Pass 'h' to make sure middleware resume works correctly.
mark_async :: proc(h: ^Handler, res: ^Response, state: rawptr) {
	if res == nil || res._conn == nil || res._conn.owning_thread == nil {
		log.error("mark_async: invalid response or connection state")
		return
	}

	if atomic_load(&res._conn.server.closing) {
		log.warn("mark_async: server is closing, ignoring")
		return
	}

	if h != nil {
		res.async_handler = h
	} else if res.async_handler == nil {
		// We need a handler pointer to resume correctly.
		// If you are in a middleware chain, you MUST pass h.
		assert(false, "mark_async: h is nil and res.async_handler not set. Always pass h in middleware.")
		res.async_handler = &res._conn.server.handler // fallback
	}

	res.async_state = state
	intrinsics.atomic_add(&res._conn.owning_thread.async_pending, 1)
	log.debugf("mark_async: pending count is %d", intrinsics.atomic_load(&res._conn.owning_thread.async_pending))
}

// Roll back async intent if something fails before starting background work.
// This fixes the pending counter so the server can shut down later.
// You must also send an error response to the client.
cancel_async :: proc(res: ^Response) {
	if res == nil || res._conn == nil || res._conn.owning_thread == nil {
		log.error("cancel_async: invalid response or connection state")
		return
	}

	if res.async_state == nil {
		log.error("cancel_async called but response is not async. Ignoring to protect counter.")
		return
	}

	intrinsics.atomic_add(&res._conn.owning_thread.async_pending, -1)
	log.debugf("cancel_async: pending count is %d", intrinsics.atomic_load(&res._conn.owning_thread.async_pending))
	res.async_state = nil
	res.async_handler = nil
}

// Tell the io thread that background work is done.
// Safe to call from any thread. Do not touch 'res' after calling this.
resume :: proc(res: ^Response) {
	if res == nil || res._conn == nil || res._conn.owning_thread == nil {
		log.error("resume: invalid response or connection state")
		return
	}

	td := res._conn.owning_thread
	msg: Maybe(^Response) = res
	if mpsc.push(&td.resume_queue, &msg) {
		nbio.wake_up(td.event_loop)
	}
}
