package async_examples

import http "../.."

// Same-thread split pattern: both mark_async and resume are called on the IO thread
// inside the body callback. No background thread is created.
// Part 2 runs in the same event-loop tick as the callback.

Ping_Pong_Work :: struct {
	body: string,
}

ping_pong_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.async_state == nil {
		// Store h now — the body callback receives user_data (res), not h.
		// Without this, the callback cannot call mark_async with the correct handler.
		res.async_handler = h
		http.body(req, -1, res, ping_pong_callback)
		return
	}

	// Part 2: resume call on the IO thread (same tick as callback).
	work := (^Ping_Pong_Work)(res.async_state)
	defer {res.async_state = nil}

	if work.body == "ping" {
		http.respond_plain(res, "pong")
	} else {
		http.respond(res, http.Status.Unprocessable_Content)
	}
}

// ping_pong_callback runs on the IO thread inside scanner_on_read.
// context.temp_allocator is already set to the connection arena — no save/restore needed.
// mark_async + resume called synchronously here; no other thread is involved.
ping_pong_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	res := (^http.Response)(user_data)
	if err != nil {
		http.respond(res, http.body_error_status(err))
		return
	}

	work := new(Ping_Pong_Work, context.temp_allocator)
	work.body = string(body)

	// mark_async before resume — same ordering invariant as all patterns.
	http.mark_async(res.async_handler, res, work)

	// resume on the IO thread: pushes res onto the queue and wakes the event loop.
	// The loop processes it on the next tick, re-entering the handler at Part 2.
	http.resume(res)
}
