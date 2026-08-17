# lean-aws-lambda

Running Lean on AWS Lambda, as a native custom runtime on `provided.al2023`. No web adapter, no
managed runtime, no sidecar: the function talks to the Lambda runtime API directly.

Two packages, so that a function which is not serving HTTP does not have to build an HTTP stack.

| Package | Library | What it gives you |
| --- | --- | --- |
| `awsLambda` | `AwsLambda` | The runtime API: JSON in, JSON out. Any trigger. |
| `awsLambda-http` | `AwsLambdaHttp` | API Gateway payload format 2.0 mapped onto `Std.Http`. |

## An API-style function

`awsLambda` alone. No `Std.Http`, no middleware.

```lean
import AwsLambda

open Lean (Json)

def main : IO Unit := AwsLambda.serve do
  pure fun event => do
    let name := (event.getObjVal? "name" >>= Json.getStr?).toOption.getD "world"
    pure (.ok (Json.mkObj [("greeting", Json.str s!"hello {name}")]))
```

`serve` finds the runtime API, runs the block once per execution environment, then serves
invocations with the handler it returns. Anything the block throws is reported to the runtime API's
init endpoint, so Lambda replaces the environment rather than leaving it to accept an invocation it
cannot serve.

## A web application

Add `awsLambda-http`. `AwsLambda.Http.handler` presents any `Std.Http` handler as something
`serve` can run, and is the only place the two layers meet.

```lean
import AwsLambdaHttp

def main : IO Unit := AwsLambda.serve do
  let pool ← Postgres.Pool.create conninfo 1
  pure (AwsLambda.Http.handler (myApp pool))
```

Work that belongs in the block rather than in the handler is anything that should happen once per
execution environment instead of once per invocation: opening a connection pool, reading a secret,
applying migrations.

## What the HTTP layer supports

Payload format **2.0** only, which is what a Lambda function URL and an API Gateway HTTP API emit.
A REST API's format 1.0 and an ALB's target payload are different shapes, and are rejected by
version with a message saying so rather than half-read into a request missing its method and path.

Three request headers are set by the adapter rather than taken from the event, and each is a
correctness requirement:

- **`Cookie`** is rebuilt from the event's `cookies` array. Format 2.0 delivers request cookies
  there and omits the header, so without this a handler sees no cookies at all and every session
  lookup and anti-forgery check fails.
- **`X-Forwarded-For`** is set from `requestContext.http.sourceIp`, discarding what the client sent.
  A function URL truncates `x-forwarded-for` to its leftmost entry, which is the entry the *client*
  controls, so passing it through would hand `Middleware.forwardedRemoteAddr` an address the caller
  chose for itself.
- **`X-Forwarded-Proto`** is always `https`. Neither supported trigger has a plaintext listener, and
  `Middleware.requestOrigin` assumes `http` when nothing says otherwise.

The last two are unconditional, which is the reason for the trigger restriction above: a deployment
reachable over plain HTTP would need them to be conditional.

On the way out, `Set-Cookie` headers are moved into the payload's `cookies` array. Lambda turns each
entry into its own header and rejects a response that sets the header directly, so several cookies
would otherwise collapse into one comma-joined value no browser reads back. A body that is not valid
UTF-8 goes back base64-encoded; text is sent as text, which keeps CloudWatch's record readable.

## Observability

Failures are reported through `AwsLambda.Options.onFailure`, which takes a structured `Failure`
rather than a formatted string so it can feed a span or a metric instead of being parsed back out of
a log line. The default writes to stderr.

```lean
AwsLambda.serve init { onFailure := fun f => myTelemetry.record f }
```

`Failure.next` is fatal: nothing can be reported against an invocation that never arrived, so the
process exits and Lambda replaces the environment rather than spinning.

## Response size

`AwsLambda.Http.Options.maxResponseBytes` defaults to 6MB, Lambda's buffered-response limit. It is
configurable because the ceiling belongs to the invocation path rather than to Lambda: an
asynchronous invocation differs, and a streamed response differs again. Raising it past what the
path allows only moves where the response is rejected.

## Not supported

- **Response streaming.** Responses are buffered. Streaming uses a different content type on the
  `/response` endpoint and would change the runtime API surface, so it is a deliberate exclusion
  rather than an oversight.
- **Payload formats other than 2.0**, as above.
- **Extensions and the telemetry API.** The runtime API only.

## Prerequisites

`awsLambda-http` requires [lean-middleware](https://github.com/paulbutcher/lean-middleware) for
base64 and the `set-cookie` header name. `awsLambda` requires nothing beyond Lean and `Std`.

Both currently pull in `Lean.Data.Json`, which statically links the whole Lean frontend and costs
roughly 76MB of binary. On Lambda that is paid as cold-start latency: the pages have to be faulted
in from the container image before `main` is reached. Measured against a real deployment, that is
around 9.6 seconds of a cold start, against 69ms for everything the application itself does. There
is no JSON implementation in `Std` to move to yet.

## Testing

`lake test` at the root runs the suite in `test/`, which is its own package so that neither shipping
library carries a dependency that exists only to test it.

The suite includes a fake runtime API on a real socket, which is worth knowing about if you are
writing something similar: rejecting `Transfer-Encoding: chunked` reached production as a 502 on
every browser mutation, because the emulator always used `Content-Length` and the deployed runtime
API switches to chunked once a payload is large enough. Reproducing that needs a response that
cannot arrive in a single read, and making one by writing it in pieces does not work reliably,
because loopback coalesces the writes. Exceeding the reader's own buffer does.
