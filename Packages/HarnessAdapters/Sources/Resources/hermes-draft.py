"""One ordinary Mailpipe draft inside the selected Hermes installation."""
import sys
sys.dont_write_bytecode = True

from contextlib import redirect_stdout, redirect_stderr
import inspect
import json
import os
from pathlib import Path

MODEL = "deepseek-flash"
ENDPOINT = "https://api.deepseek.com"
VERSION = "0.23.2"


def stop(code):
    # Hermes executes HTTP requests on worker threads. Raising there lets the
    # native retry loop continue. The host owns this one-shot process and its
    # disposable workspace, so report the first outcome directly.
    os._exit(code)


def run():
    from hermes_cli.version_info import get_version_info
    __version__ = get_version_info().display_version
    if __version__ != VERSION:
        raise ValueError("Unsupported Hermes version")
    if sys.argv[1:] == ["--version"]:
        return "Hermes Agent " + __version__

    from run_agent import AIAgent
    from gateway.session_local import profile_env_scope
    required = ("enabled_toolsets", "skip_context_files", "skip_memory", "skip_background_review")
    if not set(required).issubset(inspect.signature(AIAgent).parameters):
        raise ValueError("Unsupported Hermes runtime")
    if sys.argv[1:] == ["--help"]:
        return " ".join(required)

    profile = Path(os.environ["MAILPIPE_HERMES_AUTH_PROFILE"])
    policy = Path(__file__).with_name("reply-policy.md").read_text(encoding="utf-8").strip()
    prompt = sys.stdin.read().strip()
    # Pin the provider request before it leaves Hermes. The transport receipt
    # also identifies the model returned by DeepSeek when its public alias moves.
    import httpx
    native_send = httpx.Client.send
    receipts = []
    sent = False
    def restricted_send(client, request, **kwargs):
        nonlocal sent
        if (sent or request.method != "POST" or str(request.url) not in
                (ENDPOINT + "/chat/completions", ENDPOINT + "/v1/chat/completions")):
            stop(2)
        body = json.loads(request.content)
        if (body.get("model") != MODEL or body.get("tools") or body.get("functions") or body.get("stream")
                or [message["role"] for message in body["messages"]] != ["system", "user"]
                or body["messages"][1]["content"] != prompt or policy != body["messages"][0]["content"]):
            stop(2)
        sent = True
        kwargs["follow_redirects"] = False
        try:
            response = native_send(client, request, **kwargs)
            if not response.is_success:
                stop({401: 3, 403: 3, 402: 4, 429: 5, 408: 6, 504: 6}.get(response.status_code, 1))
            answer = json.loads(response.read())
        except httpx.TimeoutException:
            stop(6)
        except httpx.TransportError:
            stop(1)
        choice, = answer["choices"]
        message = choice["message"]
        if (answer["model"] != MODEL or choice["finish_reason"] != "stop" or message["role"] != "assistant"
                or message.get("tool_calls") or message.get("function_call")):
            stop(7)
        receipts.append((answer["model"], message["content"], answer["usage"]))
        return response
    httpx.Client.send = restricted_send

    class DraftAgent(AIAgent):
        def _build_system_prompt(self, system_message=None):
            self._cached_system_prompt_static = policy
            return policy

        def _execute_tool_calls(self, *args, **kwargs):
            stop(2)

    # Hermes alone resolves the default profile's credentials. This scope uses
    # its native secret lookup without loading user config, hooks or plugins.
    with profile_env_scope(profile):
        agent = DraftAgent(provider="deepseek", requested_provider="deepseek", model=MODEL,
                           enabled_toolsets=[], max_iterations=1, skip_context_files=True,
                           skip_memory=True, skip_background_review=True, quiet_mode=True,
                           reasoning_config={"enabled": False}, fallback_model=None)
        if agent.tools or agent.valid_tool_names or agent.provider != "deepseek" or str(agent.base_url).rstrip("/") not in (ENDPOINT, ENDPOINT + "/v1"):
            stop(2)
        agent._disable_streaming = True
        result = agent.run_conversation(prompt, system_message=policy)
    if (result.get("completed") is not True or result.get("failed") or result.get("partial")
            or result.get("interrupted") or result.get("api_calls") != 1 or result.get("model") != MODEL
            or result.get("provider") != "deepseek"):
        raise ValueError("Incomplete Hermes turn")
    model, content, usage = receipts[0]
    if content.strip() != result["final_response"].strip():
        raise ValueError("Hermes result mismatch")
    return json.dumps(dict(model=model, content=content, inputTokens=usage["prompt_tokens"],
                           outputTokens=usage["completion_tokens"], calls=result["api_calls"]))


try:
    with open(os.devnull, "w") as sink, redirect_stdout(sink), redirect_stderr(sink):
        output = run()
    print(output)
except Exception as error:
    reason = str(error).lower()
    if any(term in reason for term in ("api key", "api_key", "credentials", "authentication", "no llm provider")):
        os._exit(3)
    os._exit(1)
