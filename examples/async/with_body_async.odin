package async_examples

import http "../.."
import "core:mem"
import "core:thread"
import "core:time"

Body_Context :: struct {
	alloc: mem.Allocator,
}

Body_Work :: struct {
	alloc:  mem.Allocator,
	thread: ^thread.Thread,
	body:   string,
	result: string,
}

body_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.work_data == nil {
		// Store h now — the body callback receives user_data (res), not h.
		// Without this, the callback cannot call mark_async with the correct handler.
		res.async_handler = h
		// Part 1: start async body read; handler returns immediately.
		http.body(req, -1, res, body_callback)
		return
	}

	// Part 2: resume call on the IO thread.
	work := (^Body_Work)(res.work_data)
	defer {
		// thread.join is fast here — background thread already called resume (it finished).
		// res.work_data = nil is mandatory before returning from Part 2.
		thread.join(work.thread)
		thread.destroy(work.thread)
		free(work, work.alloc)
		res.work_data = nil
	}

	http.respond_plain(res, work.result)
}

// body_callback runs on the IO thread after the full body is received.
// This is still Part 1 — the IO thread has not been released yet.
body_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	res := (^http.Response)(user_data)
	ctx := (^Body_Context)(res.async_handler.user_data)

	if err != nil {
		http.respond(res, http.body_error_status(err))
		return
	}

	work := new(Body_Work, ctx.alloc)
	work.alloc = ctx.alloc
	work.body = string(body)

	// mark_async before thread.start — same ordering rule as the direct pattern.
	http.mark_async(res.async_handler, res, work)

	t := thread.create(body_background_proc)
	if t == nil {
		// Two steps are both required on Part 1 failure:
		// 1. cancel_async — rolls back async_pending; without this the server never shuts down.
		// 2. http.respond — without this the client waits forever.
		http.cancel_async(res)
		free(work, ctx.alloc)
		http.respond(res, http.Status.Internal_Server_Error)
		return
	}
	t.data = res
	work.thread = t
	thread.start(t)
}

body_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Body_Work)(res.work_data)

	// context.temp_allocator is the per-connection arena — not thread-safe.
	// Save and restore so this thread's allocation does not corrupt the IO thread's arena.
	old_temp := context.temp_allocator
	defer {context.temp_allocator = old_temp}

	time.sleep(10 * time.Millisecond)

	// Store all results in work BEFORE calling resume.
	// After resume returns, the IO thread owns res — do not touch res or work.
	work.result = work.body
	http.resume(res)
}
