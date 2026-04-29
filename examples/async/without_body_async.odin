package async_examples

import "core:mem"
import "core:thread"
import "core:time"
import http "http:."

Without_Body_Context :: struct {
	alloc: mem.Allocator,
}

Without_Body_Work :: struct {
	alloc:  mem.Allocator,
	thread: ^thread.Thread,
	result: string,
}

without_body_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	ctx := (^Without_Body_Context)(h.user_data)

	// Part 1: first call on the IO thread.
	if res.async_state == nil {
		work := new(Without_Body_Work, ctx.alloc)
		work.alloc = ctx.alloc

		// mark_async before thread.start — if the thread calls resume before mark_async,
		// async_pending is incremented after the decrement and shutdown hangs forever.
		http.mark_async(h, res, work)

		t := thread.create(without_body_background_proc)
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
		return
	}

	// Part 2: resume call on the IO thread.
	work := (^Without_Body_Work)(res.async_state)
	defer {
		// thread.join here is fast — background thread already called resume, meaning it finished.
		// res.async_state = nil tells the server the async cycle is finished.
		thread.join(work.thread)
		thread.destroy(work.thread)
		free(work, work.alloc)
		res.async_state = nil
	}

	http.respond_plain(res, work.result)
}

without_body_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Without_Body_Work)(res.async_state)

	// context.temp_allocator is the per-connection arena — not thread-safe.
	// Save and restore so this thread's allocation does not corrupt the IO thread's arena.
	old_temp := context.temp_allocator
	defer {context.temp_allocator = old_temp}

	time.sleep(10 * time.Millisecond)

	// Store all results in work BEFORE calling resume.
	// After resume returns, the IO thread owns res — do not touch res or work.
	work.result = "hello from background"
	http.resume(res)
}
