# lean-aws-lambda

Wrapper to run a Lean app on AWS Lambda.

Two packages, so that a function which is not serving HTTP does not have to build an HTTP stack.

| Package | Library | What it gives you |
| --- | --- | --- |
| `awsLambda` | `AwsLambda` | The runtime API: JSON in, JSON out. Any trigger. |
| `awsLambda-http` | `AwsLambdaHttp` | API Gateway payload format 2.0 mapped onto `Std.Http`. |

## An API-style function

`awsLambda` alone. No `Std.Http`, no middleware.

```lean
import AwsLambda

def main : IO Unit := AwsLambda.serve do
  pure fun event => do
    let name := (event.getObjVal? "name" >>= Json.getStr?).toOption.getD "world"
    pure (.ok (Json.mkObj [("greeting", Json.str s!"hello {name}")]))
```

## A web application

```lean
import AwsLambdaHttp

def main : IO Unit := AwsLambda.serve do
  pure (AwsLambda.Http.handler myApp)
```

## What the HTTP layer supports

Payload format **2.0** only, which is what a Lambda function URL and an API Gateway HTTP API emit.

Three request headers are set by the adapter rather than taken from the event:

- **`Cookie`** is rebuilt from the event's `cookies` array. Format 2.0 delivers request cookies
  there and omits the header, so without this a handler sees no cookies at all and every session
  lookup and anti-forgery check fails.
- **`X-Forwarded-For`** is set from `requestContext.http.sourceIp`, discarding what the client sent.
  A function URL truncates `x-forwarded-for` to its leftmost entry, which is the entry the *client*
  controls, so passing it through would hand `Middleware.forwardedRemoteAddr` an address the caller
  chose for itself.
- **`X-Forwarded-Proto`** is always `https`. Neither supported trigger has a plaintext listener, and
  `Middleware.requestOrigin` assumes `http` when nothing says otherwise.

`Set-Cookie` headers are moved into the payload's `cookies` array.

## Observability

Failures are reported through `AwsLambda.Options.onFailure`. The default writes to stderr.

```lean
AwsLambda.serve init { onFailure := fun f => myTelemetry.record f }
```

`Failure.next` is fatal: nothing can be reported against an invocation that never arrived, so the
process exits and Lambda replaces the environment rather than spinning.

## Response size

`AwsLambda.Http.Options.maxResponseBytes` defaults to 6MB, Lambda's buffered-response limit.

## Not supported

- **Response streaming.** Responses are buffered.
- **Payload formats other than 2.0**, as above.
- **Extensions and the telemetry API.** The runtime API only.

## Prerequisites

`awsLambda` requires [lean-json](https://github.com/paulbutcher/lean-json). `awsLambda-http`
additionally requires [lean-middleware](https://github.com/paulbutcher/lean-middleware).
