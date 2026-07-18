// Narrow declaration seam for `utils.js` (Plan 006 Step 4) - declares only
// the two exports `blocks.ts` calls, not the whole upstream-heavy file.

// Forwards `e.message` to the native `logError` bridge handler. Callers
// always pass a caught exception, whose real shape is unknown to the
// compiler (and to `utils.js` itself, which trusts `e.message` without
// validating it) - `unknown` is the honest parameter type, not `Error`.
export declare function logError(e: unknown): void;

// Wraps `msg` in `new Error(msg)` before forwarding to `logError`.
export declare function logErrorMessage(msg: string): void;
