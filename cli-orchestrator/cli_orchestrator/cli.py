from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .config import load_config
from .orchestrator import Orchestrator
from .planner import StaticPlanner, Step
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


def _print_step_result(result, *, as_json: bool) -> None:
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


def _print_run_result(run_result, *, as_json: bool) -> None:
    if as_json:
        data = {
            "status": run_result.status,
            "summary": run_result.summary,
            "escalation_reason": run_result.escalation_reason,
            "history": [
                {
                    "model": r.model,
                    "footer": {
                        "status": r.footer.status,
                        "files_changed": r.footer.files_changed,
                        "next": r.footer.next,
                    },
                    "error": r.error,
                }
                for r in run_result.history
            ],
        }
        print(json.dumps(data, indent=2))
    else:
        for i, r in enumerate(run_result.history, 1):
            _print_step_result(r, as_json=False)
        print()
        if run_result.status == "done":
            print(f"Done: {run_result.summary}")
        else:
            print(f"Escalated: {run_result.escalation_reason}", file=sys.stderr)


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

    # clio run  (StaticPlanner from JSON plan file)
    p_run = sub.add_parser("run", help="Run a plan via StaticPlanner (plan.json)")
    _add_common_args(p_run)
    p_run.add_argument("--workspace", default=".", help="Workspace directory")
    p_run.add_argument("--plan", required=True, help="JSON file: list of {model, prompt}")

    # clio step  (single step, no loop)
    p_step = sub.add_parser("step", help="Execute exactly one step against one model")
    _add_common_args(p_step)
    p_step.add_argument("--model", required=True, help="Provider model name")
    p_step.add_argument("--workspace", default=".", help="Workspace directory")
    p_step.add_argument("--prompt", required=True, help="Task prompt")

    # clio review  (same prompt to multiple models)
    p_rev = sub.add_parser("review", help="Cross-check: same prompt to multiple models")
    _add_common_args(p_rev)
    p_rev.add_argument("--models", required=True, help="Comma-separated model names")
    p_rev.add_argument("--workspace", default=".", help="Workspace directory")
    p_rev.add_argument("--prompt", required=True, help="Review prompt")

    args = parser.parse_args(argv)

    config = load_config(base_url=args.base_url, token=args.token)
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

    elif args.command == "run":
        plan_path = Path(args.plan)
        if not plan_path.exists():
            print(f"Error: plan file not found: {args.plan}", file=sys.stderr)
            sys.exit(1)
        raw_steps = json.loads(plan_path.read_text())
        steps = [Step(model=s["model"], prompt=s["prompt"]) for s in raw_steps]
        planner = StaticPlanner(steps)
        orch = Orchestrator(args.workspace, config)
        result = orch.run(planner)
        _print_run_result(result, as_json=as_json)
        if result.status == "escalated":
            exit_code = 1

    elif args.command == "step":
        orch = Orchestrator(args.workspace, config)
        result = orch.run_step(args.model, args.prompt)
        _print_step_result(result, as_json=as_json)
        if result.error or result.footer.status == "blocked":
            exit_code = 1

    elif args.command == "review":
        models = [m.strip() for m in args.models.split(",") if m.strip()]
        orch = Orchestrator(args.workspace, config)
        results = orch.run_step_multi(models, args.prompt)
        for r in results:
            _print_step_result(r, as_json=as_json)
            if r.error:
                exit_code = 1

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
