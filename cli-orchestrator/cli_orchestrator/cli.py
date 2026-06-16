from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .config import load_config
from .orchestrator import Orchestrator, PlanStep
from .providers import check_providers


def _print_providers(statuses, *, as_json: bool) -> None:
    if as_json:
        data = [
            {
                "name": p.name,
                "available": p.available,
                "supports_vision": p.supports_vision,
                "error": p.error,
            }
            for p in statuses
        ]
        print(json.dumps(data, indent=2))
    else:
        for p in statuses:
            mark = "✓" if p.available else "✗"
            vision = " [vision]" if p.supports_vision else ""
            err = f" — {p.error}" if p.error else ""
            print(f"  {mark} {p.name}{vision}{err}")


def _print_result(result, *, as_json: bool) -> None:
    if as_json:
        data = {
            "model": result.model,
            "text": result.text,
            "footer": {
                "status": result.footer.status,
                "files_changed": result.footer.files_changed,
                "next": result.footer.next,
            },
            "error": result.error,
        }
        print(json.dumps(data, indent=2))
    else:
        if result.error:
            print(f"[{result.model}] ERROR: {result.error}", file=sys.stderr)
        else:
            print(f"[{result.model}] status={result.footer.status}")
            if result.footer.files_changed:
                print(f"  files: {', '.join(result.footer.files_changed)}")
            if result.footer.next:
                print(f"  next:  {result.footer.next}")
            if result.text:
                print()
                print(result.text)


def _add_common_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--token", default=None, help="Bearer token (env: CLI_CONTROLLER_TOKEN)")
    p.add_argument("--base-url", default=None, dest="base_url", help="Gateway URL (env: CLI_CONTROLLER_URL)")
    p.add_argument("--json", action="store_true", help="Output raw JSON")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="clio", description="cli-orchestrator")
    sub = parser.add_subparsers(dest="command", required=True)

    # clio providers
    p_prov = sub.add_parser("providers", help="List gateway provider statuses")
    _add_common_args(p_prov)

    # clio step
    p_step = sub.add_parser("step", help="Run a single step against one model")
    _add_common_args(p_step)
    p_step.add_argument("--model", required=True, help="Provider model name")
    p_step.add_argument("--workspace", default=".", help="Workspace directory")
    p_step.add_argument("--prompt", required=True, help="Task prompt")
    p_step.add_argument("--timeout", type=int, default=None, help="Override CLI timeout (s)")

    # clio plan
    p_plan = sub.add_parser("plan", help="Run a plan from JSON file")
    _add_common_args(p_plan)
    p_plan.add_argument("--workspace", default=".", help="Workspace directory")
    p_plan.add_argument("--file", required=True, help="JSON file: list of {model, prompt}")

    # clio review
    p_rev = sub.add_parser("review", help="Cross-check: same prompt to multiple models")
    _add_common_args(p_rev)
    p_rev.add_argument("--models", required=True, help="Comma-separated model names")
    p_rev.add_argument("--workspace", default=".", help="Workspace directory")
    p_rev.add_argument("--prompt", required=True, help="Review prompt")

    args = parser.parse_args(argv)

    config = load_config(
        base_url=args.base_url,
        token=args.token,
    )
    as_json = args.json

    exit_code = 0

    if args.command == "providers":
        try:
            statuses = check_providers(config)
            _print_providers(statuses, as_json=as_json)
            if not any(p.available for p in statuses):
                exit_code = 1
        except Exception as exc:
            print(f"Error: {exc}", file=sys.stderr)
            exit_code = 1

    elif args.command == "step":
        orch = Orchestrator(args.workspace, config)
        result = orch.run_step(args.model, args.prompt)
        _print_result(result, as_json=as_json)
        if result.error or result.footer.status in ("blocked",):
            exit_code = 1

    elif args.command == "plan":
        plan_path = Path(args.file)
        if not plan_path.exists():
            print(f"Error: plan file not found: {args.file}", file=sys.stderr)
            sys.exit(1)
        raw_steps = json.loads(plan_path.read_text())
        steps = [PlanStep(model=s["model"], prompt=s["prompt"]) for s in raw_steps]
        orch = Orchestrator(args.workspace, config)
        results = orch.run_plan(steps)
        for r in results:
            _print_result(r, as_json=as_json)
            if r.error or r.footer.status in ("blocked",):
                exit_code = 1

    elif args.command == "review":
        models = [m.strip() for m in args.models.split(",") if m.strip()]
        orch = Orchestrator(args.workspace, config)
        results = orch.run_step_multi(models, args.prompt)
        for r in results:
            _print_result(r, as_json=as_json)
            if r.error:
                exit_code = 1

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
