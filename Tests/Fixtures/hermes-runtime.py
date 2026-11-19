"""Offline stand-in for Hermes' --run-module entry point and provider transport."""
import contextlib
import json
from pathlib import Path
import runpy
import sys
from types import ModuleType, SimpleNamespace

scenario, script = sys.argv[1:3]
sys.argv = [script, *sys.argv[3:]]


def register(name, **members):
    module = ModuleType(name)
    module.__dict__.update(members)
    sys.modules[name] = module


class Timeout(Exception):
    pass


class NoNetworkClient:
    def send(self, request, **kwargs):
        assert not kwargs["follow_redirects"]
        Path("calls").open("a").write("one\n")
        if scenario == "timeout":
            raise Timeout()
        status = int(scenario) if scenario.isdigit() else 200
        return SimpleNamespace(is_success=status == 200, status_code=status, read=lambda: json.dumps({
            "model": "foreign" if scenario == "changed-model" else "deepseek-flash",
            "choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "fixture"}}],
            "usage": {"prompt_tokens": 11, "completion_tokens": 4},
        }))


class FakeAgent:
    def __init__(self, enabled_toolsets, skip_context_files, skip_memory, skip_background_review, **options):
        assert enabled_toolsets == [] and skip_context_files and skip_memory and skip_background_review
        assert options["max_iterations"] == 1 and options["fallback_model"] is None
        self.tools = ["unexpected"] if scenario == "local-tools" else []
        self.valid_tool_names = set(self.tools)
        self.provider = options["provider"]
        self.base_url = "https://api.deepseek.com/v1"

    def run_conversation(self, prompt, system_message=None):
        body = {"model": "deepseek-flash", "messages": [
            {"role": "system", "content": self._build_system_prompt()},
            {"role": "user", "content": prompt}]}
        if scenario == "wire-tools":
            body["tools"] = ["unexpected"]
        if scenario == "extra-message":
            body["messages"].append({"role": "user", "content": "unexpected"})
        url = self.base_url + "/chat/completions" if scenario != "foreign-host" else "https://other.example.com"
        request = SimpleNamespace(url=url, method="POST", content=json.dumps(body))
        NoNetworkClient().send(request)
        if scenario == "repeated":
            NoNetworkClient().send(request)
        return dict(completed=True, model=body["model"], provider=self.provider, api_calls=1, final_response="fixture")


register("hermes_cli.version_info", get_version_info=lambda: SimpleNamespace(display_version="0.23.2"))
register("run_agent", AIAgent=FakeAgent)
register("gateway.session_local", profile_env_scope=lambda profile: contextlib.nullcontext())
register("httpx", Client=NoNetworkClient, TimeoutException=Timeout, TransportError=ConnectionError)
runpy.run_path(script, run_name="__main__")
