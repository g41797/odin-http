/*
Async handler examples for odin-http.

The IO thread runs the event loop. If your handler does slow work — a database call,
a file read, an external API, heavy computation — it blocks that thread for the whole
duration. With a small fixed thread pool (one thread per CPU core by default), this
caps throughput to thread_count concurrent blocking requests regardless of backend
capacity. Async handlers fix this: the handler returns immediately to the event loop,
the work runs elsewhere, and when it finishes the IO thread re-invokes(resumes) the same handler
to send the response.

---

The Split Handler Pattern

One handler proc handles both invocations, distinguished by res.work_data:

	my_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	    if res.work_data == nil {
	        // Part 1 (IO thread): allocate work struct, call mark_async,
	        // start background work, return immediately.
	    } else {
	        // Part 2 (IO thread, resume call): read result from work struct,
	        // send response, clean up.
	        defer { res.work_data = nil }
	    }
	}

The work struct is the only bridge between Part 1 and Part 2. Allocate it in Part 1,
store its pointer via mark_async (which saves it in res.work_data), read it in Part 2,
free it before Part 2 returns.

---

Three Variants

without_body_async.odin — Direct: no body read needed. Part 1 calls mark_async then
starts a background thread. Part 2 reads the result when the thread signals completion.

with_body_async.odin — Body-first: the body must be read before work can start.
The body callback (running on the IO thread) calls mark_async then starts a background
thread. The handler proc handles only Part 2.

ping_pong.odin — Same-thread split: no background thread at all. The body callback
calls mark_async and http.resume synchronously on the IO thread. Part 2 fires in the
same event-loop tick.

---

Note on Thread Usage

These examples use thread.create per request to illustrate the flow clearly.
This is a learning pattern, not for production. A real server uses a worker pool;
only the glue code that signals completion calls http.resume(res).

---

API

mark_async(h, res, work)
	Records h as the exact handler to call in Part 2 (middleware-safe: resumes the
	handler that went async, not the head of the chain) and stores work in
	res.work_data. Increments async_pending on the owning IO thread.
	Call this BEFORE starting background work.

cancel_async(res)
	Rolls back mark_async when background work fails to start. Decrements async_pending
	and clears res.work_data. Must be paired with http.respond — omitting cancel_async
	leaves async_pending permanently incremented and graceful shutdown hangs forever;
	omitting http.respond silently drops the request and the client waits forever.

resume(res)
	Called from the background thread when work is complete. Pushes res onto the
	per-IO-thread MPSC queue and calls nbio.wake_up. The IO thread dequeues res on
	the next tick and re-invokes the handler at Part 2. Call exactly once.
	After resume returns, the IO thread owns res — do not touch res or any connection
	field after this point.

---

Ownership

	Phase                        | Owner       | Background thread may
	-----------------------------|-------------|------------------------------------------
	Part 1 (first call)          | IO thread   | —
	Background work              | Bkg thread  | read/write work struct; call resume once
	Part 2 (resume call)         | IO thread   | —

In the background phase: do not read or write res fields directly. Do not call any
http.* proc except http.resume. Do not allocate from context.temp_allocator — the
per-connection arena is not thread-safe and allocating from a background thread is a
data race.

---

Hard Rules

1. Call mark_async BEFORE starting background work.
   If the background thread calls resume before mark_async runs, async_pending is
   incremented after the decrement — the server's shutdown loop waits for zero and
   never exits.

2. On Part 1 failure (thread creation fails, queue is full, etc.): call BOTH
   cancel_async AND http.respond. cancel_async fixes the pending counter; http.respond
   tells the client. Omitting either one hangs the server or the client.

3. Call resume exactly once.
   Zero calls: the request is permanently lost; the client waits forever; the server
   never shuts down. Two calls: undefined behavior, likely a crash or corrupted
   connection.

4. Set res.work_data = nil before Part 2 returns.
   The server uses this field to detect when the async cycle is finished and to know
   it is safe to reset the connection for the next request.
   Use defer { res.work_data = nil } at the top of the Part 2 branch.

5. Part 2 runs even if the client disconnected. Always join the thread and free the
   work struct — the server requires Part 2 for cleanup regardless of connection state.

6. If your body callback needs to call mark_async, store res.async_handler = h in the
   handler before calling http.body(). The callback receives only user_data (which is
   res), not h — without this the callback cannot reach the correct handler pointer.
*/
package async_examples
