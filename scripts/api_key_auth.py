"""Require the configured bearer key on every vLLM HTTP route."""

from __future__ import annotations

import hashlib
import hmac
import os

from starlette.datastructures import Headers
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send


class RequireApiKey:
    """ASGI middleware that protects routes beyond vLLM's built-in prefixes."""

    def __init__(self, app: ASGIApp) -> None:
        api_key = os.environ.get("VLLM_API_KEY", "")
        if len(api_key) < 32:
            raise RuntimeError("VLLM_API_KEY must contain at least 32 characters")
        self.app = app
        self.key_digest = hashlib.sha256(api_key.encode("utf-8")).digest()

    def is_authenticated(self, scope: Scope) -> bool:
        authorization = Headers(scope=scope).get("authorization", "")
        scheme, separator, token = authorization.partition(" ")
        if not separator or scheme.lower() != "bearer":
            return False
        token_digest = hashlib.sha256(token.encode("utf-8")).digest()
        return hmac.compare_digest(token_digest, self.key_digest)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return

        if scope.get("method") == "OPTIONS":
            await self.app(scope, receive, send)
            return

        if self.is_authenticated(scope):
            await self.app(scope, receive, send)
            return

        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 4401})
            return

        response = JSONResponse({"error": "Unauthorized"}, status_code=401)
        await response(scope, receive, send)
